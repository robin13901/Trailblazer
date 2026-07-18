// Phase 5 (Plan 05-07): TripMatchCoordinator — orchestrates the
// pending-trip → matched-trip pipeline. Fetches ways via
// WayCandidateSource, submits to MatcherIsolate, writes intervals via
// DrivenWayIntervalsDao, transitions state via TripsRepository.
// Phase 10 (Plan 10-05): onIntervalsLanded callback seam — fires after
// intervals are written for a trip so callers can trigger an incremental
// recompute without coupling the coordinator to Riverpod or
// CoverageComputeService directly.

import 'dart:async';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/matching/data/match_job.dart';
import 'package:auto_explore/features/matching/data/matcher_isolate.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';

/// Sink for streamed matching progress. `fraction` is `0.0..1.0`.
///
/// Kept as a plain function typedef so the coordinator stays decoupled from
/// Riverpod — the actual provider write is wired in `matching_providers.dart`
/// where a `Ref` is available.
typedef MatchProgressSink = void Function(int tripId, double fraction);

/// Sink invoked to clear a trip's progress entry (job done/errored/cancelled
/// or trip transitioned to `matched`). Wired to `MatchProgressNotifier.clear`
/// in `matching_providers.dart`.
typedef MatchProgressClearSink = void Function(int tripId);

/// Callback fired after intervals are written for a trip (both the normal
/// match path and the re-match path). Wired at provider-construction time to
/// a recompute-only trigger (Phase 10 plan 10-05 Decision 6 auto seam).
///
/// The callback receives the [tripId] that just had its intervals written.
/// It is invoked fire-and-forget (unawaited) — failures must be caught
/// internally and must NEVER propagate to the coordinator's call site.
typedef OnIntervalsLandedCallback = void Function(int tripId);

/// Phase 5 coordinator: picks up trips in `pending` status, fetches road
/// ways via [WayCandidateSource] (cache-first), submits a match job to the
/// [MatcherIsolate], writes the resulting DrivenWayIntervalDraft list to
/// [DrivenWayIntervalsDao], then flips the trip to `matched`.
///
/// Two entry points:
/// * [onTripReadyForMatching] — called immediately by TripRoadFetchCoordinator
///   after a trip transitions from `pendingRoadData` to `pending`.
/// * [processPending] — called on app resume to pick up any trips that
///   arrived at `pending` while the isolate was not running.
class TripMatchCoordinator {
  TripMatchCoordinator({
    required WayCandidateSource source,
    required MatcherIsolate matcherIsolate,
    required TripsDao tripsDao,
    required TripsRepository tripsRepository,
    required DrivenWayIntervalsDao intervalsDao,
    MatchProgressSink? progressSink,
    MatchProgressClearSink? progressClearSink,
    OnIntervalsLandedCallback? onIntervalsLanded,
  })  : _source = source,
        _isolate = matcherIsolate,
        _tripsDao = tripsDao,
        _tripsRepository = tripsRepository,
        _intervalsDao = intervalsDao,
        _progressSink = progressSink,
        _progressClearSink = progressClearSink,
        _onIntervalsLanded = onIntervalsLanded;

  final WayCandidateSource _source;
  final MatcherIsolate _isolate;
  final TripsDao _tripsDao;
  final TripsRepository _tripsRepository;
  final DrivenWayIntervalsDao _intervalsDao;
  final MatchProgressSink? _progressSink;
  final MatchProgressClearSink? _progressClearSink;
  final OnIntervalsLandedCallback? _onIntervalsLanded;
  final _log = Logger('trip_match_coordinator');

  /// Re-entrancy guard for the auto-recompute trigger.
  /// True while a recompute is already in flight — a subsequent intervals-
  /// landed event is debounced (skipped) rather than queuing a second pass.
  bool _recomputeInFlight = false;

  /// Invoked by 04-15's TripRoadFetchCoordinator immediately after a trip
  /// transitions from `pendingRoadData` to `pending`.
  ///
  /// Fetches ways for the trip's stored bbox (cache-first), converts
  /// trip_points to [GpsFix] list, submits to [MatcherIsolate], writes
  /// intervals, and transitions the trip to `matched`.
  ///
  /// On error (network, isolate, DB) the trip is left in `pending` so that
  /// [processPending] can retry on next resume.
  Future<void> onTripReadyForMatching(int tripId) async {
    _log.info('trip $tripId ready for matching');

    // Ensure the isolate is warm before submitting the first job.
    await _isolate.start(); // idempotent

    // Load the trip row to obtain its bbox.
    final tripRow = await (
          _tripsDao.select(_tripsDao.trips)
            ..where((t) => t.id.equals(tripId))
        ).getSingleOrNull();

    if (tripRow == null) {
      _log.warning('trip $tripId not found — skipping match');
      return;
    }

    // Null bbox: trip was closed with no geometry (degenerate).
    if (tripRow.bboxMinLat == null ||
        tripRow.bboxMinLon == null ||
        tripRow.bboxMaxLat == null ||
        tripRow.bboxMaxLon == null) {
      _log.info(
        'trip $tripId has null bbox — marking matched with 0 intervals',
      );
      await _tripsRepository.transitionToMatched(tripId);
      return;
    }

    // Fetch RAW gzipped tiles (cache-first). No decode/parse here — the
    // matcher isolate does that tile-by-tile (Plan 06-07 re-drive #3), so the
    // heavy CPU work stays off the main isolate and the full way-set never
    // lands on the main heap next to the resident MapLibre GL surface.
    final rawTiles = await _source.fetchRawTilesInBbox(
      minLat: tripRow.bboxMinLat!,
      minLon: tripRow.bboxMinLon!,
      maxLat: tripRow.bboxMaxLat!,
      maxLon: tripRow.bboxMaxLon!,
      throwOnError: false,
    );
    if (rawTiles.isEmpty) {
      _log.warning(
        'trip $tripId has no road tiles in bbox — marking matched with 0 '
        'intervals',
      );
      await _tripsRepository.transitionToMatched(tripId);
      return;
    }

    // Load GPS points for this trip.
    final points = await _tripsDao.listPointsForTrip(tripId);
    if (points.isEmpty) {
      _log.warning('trip $tripId has no points — marking matched');
      await _tripsRepository.transitionToMatched(tripId);
      return;
    }

    // Convert TripPoint rows → GpsFix values.
    final fixes = points
        .map(
          (p) => GpsFix(
            lat: p.lat,
            lon: p.lon,
            accuracyMeters: p.accuracyMeters ?? double.nan,
            speedKmh: p.speedKmh ?? 0.0,
            ts: p.ts,
          ),
        )
        .toList(growable: false);

    try {
      final result = await _isolate.match(
        tripId: tripId,
        fixes: fixes,
        gzippedTiles: [for (final t in rawTiles) t.payloadGzip],
        tileBboxes: [for (final t in rawTiles) t.bbox],
        onProgress: (processed, total) {
          if (total > 0) {
            _progressSink?.call(tripId, processed / total);
          }
        },
      );
      await _writeIntervals(tripId, result.intervals);
      await _tripsRepository.transitionToMatched(tripId);
      _progressSink?.call(tripId, 1);
      _clearProgress(tripId);
      _log.info(
        'trip $tripId matched: ${result.intervals.length} intervals, '
        '${result.matchedFixCount} matched fixes, '
        '${result.droppedFixCount} dropped',
      );
    } on MatcherCancelledException {
      _clearProgress(tripId);
      _log.info('trip $tripId matching cancelled — leaving in pending');
      // Leave trip in `pending` — processPending will retry.
    } on Object catch (e, st) {
      _clearProgress(tripId);
      _log.warning('trip $tripId matching failed: $e', e, st);
      // Leave trip in `pending` — resume hook will retry.
    }
  }

  /// Clear the UI-facing progress entry for [tripId] via the clear sink
  /// (no-op when no sink is wired). Called on completion, error, and cancel.
  void _clearProgress(int tripId) {
    _progressClearSink?.call(tripId);
  }

  Future<void> _writeIntervals(
    int tripId,
    List<DrivenWayIntervalDraft> drafts,
  ) async {
    if (drafts.isEmpty) return;
    final companions = drafts
        .map(
          (d) => DrivenWayIntervalsCompanion.insert(
            wayId: d.wayId,
            tripId: Value(tripId),
            startMeters: d.startMeters,
            endMeters: d.endMeters,
            direction: Value(d.direction),
          ),
        )
        .toList(growable: false);
    await _intervalsDao.insertBatch(companions);

    // Auto recompute-only seam (Phase 10 Decision 6): fire-and-forget after
    // intervals land. Guarded against re-entrancy so a rapid sequence of
    // interval writes does not queue multiple concurrent recompute passes.
    _triggerAutoRecompute(tripId);
  }

  /// Fire-and-forget auto recompute trigger.
  ///
  /// Re-entrancy: if a recompute is already in flight, the call is skipped.
  /// The in-flight pass will use the freshest intervals when it runs (they
  /// are already committed to the DB at this point), so no data is lost.
  void _triggerAutoRecompute(int tripId) {
    final callback = _onIntervalsLanded;
    if (callback == null) return;
    if (_recomputeInFlight) {
      _log.fine(
        'auto-recompute: recompute already in flight for trip $tripId — skipping',
      );
      return;
    }
    _recomputeInFlight = true;
    unawaited(
      Future(() {
        try {
          callback(tripId);
        } on Object catch (e, st) {
          _log.warning('auto-recompute: onIntervalsLanded threw: $e', e, st);
        } finally {
          _recomputeInFlight = false;
        }
      }),
    );
  }

  /// Invoked when the user deletes an in-flight trip. Cancels the isolate
  /// job (best-effort) and deletes any intervals already written. The trip
  /// row itself is deleted by the caller (CASCADE on trip_points).
  Future<void> cancel(int tripId) async {
    _log.info('cancel matching for trip $tripId');
    _isolate.cancel(tripId);
    _clearProgress(tripId);
    await _intervalsDao.deleteByTrip(tripId);
  }

  /// Called on app resume to pick up any trips that arrived at `pending`
  /// while the isolate was not running (e.g. app killed mid-match). Trips
  /// are processed FIFO (oldest endedAt first) per [TripsDao.listPendingTrips].
  Future<void> processPending() async {
    final pending = await _tripsDao.listPendingTrips();
    _log.fine('processPending: ${pending.length} trips');
    for (final trip in pending) {
      await onTripReadyForMatching(trip.id);
    }
  }

  /// One-shot migration: re-run the matcher over EVERY trip that already has
  /// stored intervals, replacing them in place. Used when the matching
  /// algorithm changes (e.g. the 2026-07-10 pass-through topology guard) so
  /// already-matched trips repaint correctly without needing a fresh drive —
  /// the raw GPS points are retained for matched/confirmed trips.
  ///
  /// For each affected trip: fetch ways (cache-first), re-match its points,
  /// delete the old intervals, and write the new ones. Status is NOT changed
  /// (a confirmed trip stays confirmed). Best-effort per trip: a failure is
  /// logged and skipped, leaving that trip's existing intervals untouched.
  ///
  /// Returns the number of trips successfully re-matched.
  Future<int> rematchAllStoredTrips() async {
    // Check for work BEFORE starting the isolate — on an empty DB (fresh
    // install, or a widget test) there is nothing to rematch, and spawning the
    // matcher isolate would leave a pending timer that outlives a headless
    // test's widget tree.
    final tripIds = await _intervalsDao.getDistinctTripIds();
    if (tripIds.isEmpty) {
      _log.info('rematchAllStoredTrips: no stored trips — nothing to do');
      return 0;
    }

    await _isolate.start(); // idempotent

    _log.info('rematchAllStoredTrips: ${tripIds.length} trips to reprocess');

    var reprocessed = 0;
    for (final tripId in tripIds) {
      try {
        final didRematch = await _rematchOne(tripId);
        if (didRematch) reprocessed++;
      } on Object catch (e, st) {
        _log.warning(
          'rematchAllStoredTrips: trip $tripId failed — keeping old '
          'intervals: $e',
          e,
          st,
        );
      }
    }
    _log.info('rematchAllStoredTrips: $reprocessed/${tripIds.length} reprocessed');
    return reprocessed;
  }

  /// Re-match a single already-stored trip in place. Returns true when new
  /// intervals were written (old ones replaced), false when the trip could
  /// not be re-matched (missing bbox/points/tiles) — in which case the
  /// existing intervals are left untouched rather than wiped.
  Future<bool> _rematchOne(int tripId) async {
    final tripRow = await (_tripsDao.select(_tripsDao.trips)
          ..where((t) => t.id.equals(tripId)))
        .getSingleOrNull();
    if (tripRow == null) return false;
    if (tripRow.bboxMinLat == null ||
        tripRow.bboxMinLon == null ||
        tripRow.bboxMaxLat == null ||
        tripRow.bboxMaxLon == null) {
      return false;
    }

    final rawTiles = await _source.fetchRawTilesInBbox(
      minLat: tripRow.bboxMinLat!,
      minLon: tripRow.bboxMinLon!,
      maxLat: tripRow.bboxMaxLat!,
      maxLon: tripRow.bboxMaxLon!,
      throwOnError: false,
    );
    if (rawTiles.isEmpty) return false;

    final points = await _tripsDao.listPointsForTrip(tripId);
    if (points.isEmpty) return false;

    final fixes = points
        .map(
          (p) => GpsFix(
            lat: p.lat,
            lon: p.lon,
            accuracyMeters: p.accuracyMeters ?? double.nan,
            speedKmh: p.speedKmh ?? 0.0,
            ts: p.ts,
          ),
        )
        .toList(growable: false);

    final result = await _isolate.match(
      tripId: tripId,
      fixes: fixes,
      gzippedTiles: [for (final t in rawTiles) t.payloadGzip],
      tileBboxes: [for (final t in rawTiles) t.bbox],
    );

    // Replace old intervals atomically-ish: delete then insert. A crash
    // between the two would leave the trip with zero intervals, which the
    // next migration run (or a manual recompute) repairs — acceptable for a
    // one-shot cosmetic reprocess.
    await _intervalsDao.deleteByTrip(tripId);
    await _writeIntervals(tripId, result.intervals);
    _log.info(
      'rematchOne: trip $tripId → ${result.intervals.length} intervals '
      '(was reprocessed)',
    );
    return true;
  }
}
