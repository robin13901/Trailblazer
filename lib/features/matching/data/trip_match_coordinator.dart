// Phase 5 (Plan 05-07): TripMatchCoordinator — orchestrates the
// pending-trip → matched-trip pipeline. Fetches ways via
// WayCandidateSource, submits to MatcherIsolate, writes intervals via
// DrivenWayIntervalsDao, transitions state via TripsRepository.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/matching/data/match_job.dart';
import 'package:auto_explore/features/matching/data/matcher_isolate.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/way_corridor_filter.dart';
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
  })  : _source = source,
        _isolate = matcherIsolate,
        _tripsDao = tripsDao,
        _tripsRepository = tripsRepository,
        _intervalsDao = intervalsDao,
        _progressSink = progressSink,
        _progressClearSink = progressClearSink;

  final WayCandidateSource _source;
  final MatcherIsolate _isolate;
  final TripsDao _tripsDao;
  final TripsRepository _tripsRepository;
  final DrivenWayIntervalsDao _intervalsDao;
  final MatchProgressSink? _progressSink;
  final MatchProgressClearSink? _progressClearSink;
  final _log = Logger('trip_match_coordinator');

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

    // Fetch ways via cache-first WayCandidateSource.
    final ways = await _source.fetchWaysInBbox(
      minLat: tripRow.bboxMinLat!,
      minLon: tripRow.bboxMinLon!,
      maxLat: tripRow.bboxMaxLat!,
      maxLon: tripRow.bboxMaxLon!,
      throwOnError: false,
    );
    if (ways.isEmpty) {
      _log.warning(
        'trip $tripId has no ways in bbox — marking matched with 0 intervals',
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

    // Corridor pre-filter (Plan 06-07): a long trip's bbox can contain tens of
    // thousands of ways (measured: 29,497 / 13.7 MB for a 96 km commute).
    // Shipping all of them across the isolate boundary + R-Tree-indexing them
    // on top of the resident ~529 MB MapLibre GL surface OOM-kills the app.
    // Keep only ways within ~one grid cell of the actual trip path — a ~20x
    // reduction with no matchable-road loss (the matcher's own candidate
    // radius is 25 m, far tighter than this corridor).
    final corridorWays = filterWaysToTripCorridor(fixes: fixes, ways: ways);
    _log.info(
      'trip $tripId corridor filter: ${ways.length} → ${corridorWays.length} ways',
    );

    try {
      final result = await _isolate.match(
        tripId: tripId,
        fixes: fixes,
        ways: corridorWays,
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
}
