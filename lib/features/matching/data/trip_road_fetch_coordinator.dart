// Phase 4 rescope Wave 2 (Plan 04-15):
// Orchestrates the road-fetch side of the trip lifecycle.
//
// Called by:
//   * `TrackingService.stopActive` (or equivalent) at trip close — flips the
//     trip to `pendingRoadData`, attempts an Overpass fetch, and either
//     flips to `pending` on success or enqueues a `pending_road_fetches`
//     row on failure.
//   * `app.dart` at `AppLifecycleState.resumed` — walks the queue and
//     retries drainable rows with exponential backoff
//     (5 min / 30 min / 2 h / 12 h / 24 h → abandon at 5 attempts).
//
// Phase 5 (Plan 05-07): accepts an optional [TripMatchCoordinator] param.
// After each successful `transitionToPending` call (both online path and
// drain path), fires `matchCoordinator?.onTripReadyForMatching(tripId)`
// as an unawaited fire-and-forget — the match pipeline runs in the
// background; the fetch coordinator's SLA is "return quickly".

import 'dart:async';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/pending_road_fetches_dao.dart';
import 'package:auto_explore/features/matching/data/connectivity_seam.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/trip_match_coordinator.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Backoff schedule for offline-retry attempts on the pending fetch queue.
///
/// Attempts are clamped to `[0, delays.length - 1]`; attempt 5+ is abandoned
/// entirely (rowAbandoned).
const List<Duration> kPendingFetchBackoff = [
  Duration(minutes: 5),
  Duration(minutes: 30),
  Duration(hours: 2),
  Duration(hours: 12),
  Duration(hours: 24),
];

/// Max retry attempts before the coordinator abandons a queued fetch. Rows
/// with `attempts >= [kMaxPendingFetchAttempts]` are left in place (they can
/// be manually retried later — Phase 5 will decide the UX).
const int kMaxPendingFetchAttempts = 5;

class TripRoadFetchCoordinator {
  TripRoadFetchCoordinator({
    required WayCandidateSource source,
    required PendingRoadFetchesDao pendingDao,
    required TripsRepository repository,
    required ConnectivitySeam connectivity,
    required TripsDao tripsDao,
    TileBboxMath tileMath = const TileBboxMath(),
    DateTime Function()? now,
    TripMatchCoordinator? matchCoordinator,
    MatchProgressSink? progressSink,
    MatchProgressClearSink? progressClearSink,
  })  : _source = source,
        _pendingDao = pendingDao,
        _repository = repository,
        _connectivity = connectivity,
        _tripsDao = tripsDao,
        _tileMath = tileMath,
        _now = now ?? DateTime.now,
        _matchCoordinator = matchCoordinator,
        _progressSink = progressSink,
        _progressClearSink = progressClearSink;

  final WayCandidateSource _source;
  final PendingRoadFetchesDao _pendingDao;
  final TripsRepository _repository;
  final ConnectivitySeam _connectivity;
  final TripsDao _tripsDao;
  final TileBboxMath _tileMath;
  final DateTime Function() _now;

  /// Optional Phase 5 match coordinator. When set, fires
  /// [TripMatchCoordinator.onTripReadyForMatching] (unawaited) immediately
  /// after each trip transitions to `pending`. When null, matching is
  /// triggered only via [TripMatchCoordinator.processPending] on app resume.
  final TripMatchCoordinator? _matchCoordinator;

  /// Optional UI progress sink (2026-07-21). Fed `(tripId, done/totalTiles)` as
  /// road tiles are fetched so the history pill shows N/M tile progress during
  /// the `pendingRoadData` phase instead of an indeterminate spinner. Writes
  /// the same `tripId → 0.0..1.0` slot the matcher later reuses.
  final MatchProgressSink? _progressSink;

  /// Clears the progress entry (see [_progressSink]) at the fetch→match
  /// handoff, so the matcher's own fix-based progress starts clean rather than
  /// resuming from the fetch's terminal 100 %.
  final MatchProgressClearSink? _progressClearSink;

  final _log = Logger('trip_road_fetch_coordinator');

  /// Called by `TrackingService` immediately after a trip has been closed
  /// but before its status has advanced past `recording`. The coordinator
  /// owns the transition to `pendingRoadData` / `pending` from here.
  ///
  /// [bbox] is the trip's bounding box (min/max lat/lon), typically taken
  /// straight from `TripSummary`. An "empty" bbox (all zeros) is treated as
  /// "nothing to fetch" — the trip advances straight to `pending`.
  ///
  /// A [polyline]-driven overload is provided for tests and future extension
  /// points; if given, its bbox is used instead of [bbox].
  Future<void> onTripStopped(
    int tripId, {
    ({double minLat, double minLon, double maxLat, double maxLon})? bbox,
    List<LatLng>? polyline,
  }) async {
    assert(
      bbox != null || polyline != null,
      'onTripStopped requires bbox or polyline',
    );

    // 1. Transition to pendingRoadData first so the UI reflects the queued
    //    state immediately, even if the network attempt takes seconds.
    await _repository.transitionToPendingRoadData(tripId);

    final effectiveBbox = polyline != null && polyline.isNotEmpty
        ? _bboxOf(polyline)
        : bbox!;

    if (_isEmptyBbox(effectiveBbox)) {
      _log.info(
        'trip $tripId has empty bbox — skipping fetch, going to pending',
      );
      await _repository.transitionToPending(tripId);
      // Phase 5 hook: fire matching in the background (unawaited).
      unawaited(
        _matchCoordinator?.onTripReadyForMatching(tripId),
      );
      return;
    }

    // 2. Enqueue-FIRST (2026-07-21 orphan fix). Persist a drainable queue row
    //    BEFORE any network attempt (idempotent — skip if one already exists).
    //    Previously the row was written only in the error catch, so a process
    //    death mid-fetch (common right after a long drive) threw nothing, left
    //    no row, and stranded the trip in `pendingRoadData` forever — invisible
    //    to both drainQueue (walks the queue) and processPending (pending only).
    //    With the row always present, drainQueue on the next resume recovers it.
    await _enqueueIfAbsent(tripId, effectiveBbox);

    // 3. Offline path — the row is enqueued; drainQueue picks it up later.
    if (!await _connectivity.isOnline()) {
      _log.info('offline — trip $tripId enqueued for later fetch');
      return;
    }

    // 4. Online path — attempt fetch. On success, remove the queue row and
    //    advance to pending. On error, leave the row in place (do NOT bump
    //    attempts here — that is drainQueue's job) so the next drain retries.
    try {
      await _fetchTiles(tripId, effectiveBbox);
      await _pendingDao.removeByTrip(tripId);
      await _repository.transitionToPending(tripId);
      _progressClearSink?.call(tripId);
      // Phase 5 hook: fire matching in the background (unawaited).
      unawaited(
        _matchCoordinator?.onTripReadyForMatching(tripId),
      );
    } on Object catch (e, st) {
      _log.warning(
        'trip $tripId fetch failed — leaving queued for drain: $e',
        e,
        st,
      );
      _progressClearSink?.call(tripId);
    }
  }

  /// Enqueue a pending-fetch row for [tripId] unless one already exists
  /// (idempotent — safe to call on every stop and on reconcile).
  Future<void> _enqueueIfAbsent(
    int tripId,
    ({double minLat, double minLon, double maxLat, double maxLon}) bbox,
  ) async {
    if (await _pendingDao.getByTrip(tripId) != null) return;
    await _pendingDao.enqueue(
      tripId: tripId,
      minLat: bbox.minLat,
      minLon: bbox.minLon,
      maxLat: bbox.maxLat,
      maxLon: bbox.maxLon,
    );
  }

  /// Fetch this trip's road tiles, corridor-restricted to the tiles the GPS
  /// path actually crosses (not the whole bbox rectangle) and reporting per-
  /// tile progress to [_progressSink]. Falls back to full-bbox behaviour when
  /// the trip has no stored points.
  Future<void> _fetchTiles(
    int tripId,
    ({double minLat, double minLon, double maxLat, double maxLon}) bbox,
  ) async {
    final points = await _tripsDao.listPointsForTrip(tripId);
    final restrict = points.isEmpty
        ? null
        : _tileMath.tilesForPath(
            [for (final p in points) (lat: p.lat, lon: p.lon)],
          );
    final sink = _progressSink;
    await _source.fetchWaysInBbox(
      minLat: bbox.minLat,
      minLon: bbox.minLon,
      maxLat: bbox.maxLat,
      maxLon: bbox.maxLon,
      restrictTiles: restrict,
      onTileProgress: sink == null
          ? null
          : (done, total) {
              if (total > 0) sink(tripId, done / total);
            },
    );
  }

  /// Walk the pending queue, respecting exponential backoff, and retry
  /// drainable rows. Invoked on app resume (`AppLifecycleState.resumed` —
  /// wired in `lib/app.dart`) and — if a connectivity stream is present in
  /// the future — on connectivity restore.
  ///
  /// Rows with attempts >= [kMaxPendingFetchAttempts] are silently skipped.
  Future<void> drainQueue({DateTime? now}) async {
    final n = now ?? _now();
    final pending = await _pendingDao.listPending();
    for (final row in pending) {
      if (row.attempts >= kMaxPendingFetchAttempts) {
        _log.fine('trip ${row.tripId} exceeds max attempts — skipping');
        continue;
      }
      if (!_backoffElapsed(row, n)) continue;
      final bbox = (
        minLat: row.bboxMinLat,
        minLon: row.bboxMinLon,
        maxLat: row.bboxMaxLat,
        maxLon: row.bboxMaxLon,
      );
      try {
        await _fetchTiles(row.tripId, bbox);
        await _pendingDao.removeByTrip(row.tripId);
        await _repository.transitionToPending(row.tripId);
        _progressClearSink?.call(row.tripId);
        // Phase 5 hook: fire matching in the background (unawaited).
        unawaited(
          _matchCoordinator?.onTripReadyForMatching(row.tripId),
        );
        _log.info('drained trip ${row.tripId} → pending');
      } on Object catch (e) {
        _log.warning('drain retry failed for trip ${row.tripId}: $e');
        _progressClearSink?.call(row.tripId);
        await _pendingDao.incrementAttempts(row.id, now: n);
      }
    }
  }

  /// Startup self-heal (2026-07-21): re-enqueue trips stranded at
  /// `pendingRoadData` that have NO `pending_road_fetches` row. Such orphans
  /// predate the enqueue-first fix (or arose from a mid-fetch crash before the
  /// row was written) and are invisible to [drainQueue] and
  /// `TripMatchCoordinator.processPending`, so they spin forever. After this
  /// runs, the caller's [drainQueue] completes them normally.
  ///
  /// Trips with a null/degenerate bbox are advanced straight to `pending`
  /// (nothing to fetch). Returns the number of trips reconciled (enqueued or
  /// advanced). Best-effort per trip — a failure is logged and skipped.
  Future<int> reconcileOrphanedPendingRoadData() async {
    final orphans = await _tripsDao.listPendingRoadDataTrips();
    var reconciled = 0;
    for (final trip in orphans) {
      try {
        if (await _pendingDao.getByTrip(trip.id) != null) continue; // has a row
        final bbox = _bboxOfTrip(trip);
        if (bbox == null || _isEmptyBbox(bbox)) {
          // No geometry to fetch — advance so it can be matched (0 intervals).
          await _repository.transitionToPending(trip.id);
          unawaited(_matchCoordinator?.onTripReadyForMatching(trip.id));
          reconciled++;
          continue;
        }
        await _enqueueIfAbsent(trip.id, bbox);
        reconciled++;
        _log.info('reconciled orphaned pendingRoadData trip ${trip.id}');
      } on Object catch (e, st) {
        _log.warning('reconcile failed for trip ${trip.id}: $e', e, st);
      }
    }
    if (reconciled > 0) {
      _log.info('reconcileOrphanedPendingRoadData: $reconciled trip(s)');
    }
    return reconciled;
  }

  /// Trip's stored bbox as a record, or null when any bbox column is null.
  ({double minLat, double minLon, double maxLat, double maxLon})? _bboxOfTrip(
    Trip trip,
  ) {
    if (trip.bboxMinLat == null ||
        trip.bboxMinLon == null ||
        trip.bboxMaxLat == null ||
        trip.bboxMaxLon == null) {
      return null;
    }
    return (
      minLat: trip.bboxMinLat!,
      minLon: trip.bboxMinLon!,
      maxLat: trip.bboxMaxLat!,
      maxLon: trip.bboxMaxLon!,
    );
  }

  bool _backoffElapsed(PendingRoadFetch row, DateTime now) {
    if (row.lastAttemptAt == null) return true;
    final idx = row.attempts.clamp(0, kPendingFetchBackoff.length - 1);
    final delay = kPendingFetchBackoff[idx];
    return now.difference(row.lastAttemptAt!) >= delay;
  }

  ({double minLat, double minLon, double maxLat, double maxLon}) _bboxOf(
    List<LatLng> polyline,
  ) {
    var minLat = 90.0;
    var minLon = 180.0;
    var maxLat = -90.0;
    var maxLon = -180.0;
    for (final p in polyline) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return (
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
    );
  }

  bool _isEmptyBbox(
    ({double minLat, double minLon, double maxLat, double maxLon}) b,
  ) =>
      b.minLat == 0 && b.maxLat == 0 && b.minLon == 0 && b.maxLon == 0;
}
