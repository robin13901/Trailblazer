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
    TileBboxMath tileMath = const TileBboxMath(),
    DateTime Function()? now,
    TripMatchCoordinator? matchCoordinator,
  })  : _source = source,
        _pendingDao = pendingDao,
        _repository = repository,
        _connectivity = connectivity,
        _tileMath = tileMath,
        _now = now ?? DateTime.now,
        _matchCoordinator = matchCoordinator;

  final WayCandidateSource _source;
  final PendingRoadFetchesDao _pendingDao;
  final TripsRepository _repository;
  final ConnectivitySeam _connectivity;
  // Kept as a field for future dev-HUD instrumentation + parity with
  // `OverpassWayCandidateSource`. Currently unused — the source performs
  // tile partitioning internally.
  // ignore: unused_field
  final TileBboxMath _tileMath;
  final DateTime Function() _now;

  /// Optional Phase 5 match coordinator. When set, fires
  /// [TripMatchCoordinator.onTripReadyForMatching] (unawaited) immediately
  /// after each trip transitions to `pending`. When null, matching is
  /// triggered only via [TripMatchCoordinator.processPending] on app resume.
  final TripMatchCoordinator? _matchCoordinator;

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

    // 2. Offline path — enqueue and stop. The coordinator's drainQueue
    //    (invoked on lifecycle resume + connectivity change) will pick this
    //    up later.
    if (!await _connectivity.isOnline()) {
      _log.info('offline — enqueuing trip $tripId for later fetch');
      await _pendingDao.enqueue(
        tripId: tripId,
        minLat: effectiveBbox.minLat,
        minLon: effectiveBbox.minLon,
        maxLat: effectiveBbox.maxLat,
        maxLon: effectiveBbox.maxLon,
      );
      return;
    }

    // 3. Online path — attempt fetch. On any error, enqueue and stay in
    //    pendingRoadData.
    try {
      await _source.fetchWaysInBbox(
        minLat: effectiveBbox.minLat,
        minLon: effectiveBbox.minLon,
        maxLat: effectiveBbox.maxLat,
        maxLon: effectiveBbox.maxLon,
      );
      await _repository.transitionToPending(tripId);
      // Phase 5 hook: fire matching in the background (unawaited).
      unawaited(
        _matchCoordinator?.onTripReadyForMatching(tripId),
      );
    } on Object catch (e, st) {
      _log.warning('trip $tripId fetch failed — enqueuing: $e', e, st);
      await _pendingDao.enqueue(
        tripId: tripId,
        minLat: effectiveBbox.minLat,
        minLon: effectiveBbox.minLon,
        maxLat: effectiveBbox.maxLat,
        maxLon: effectiveBbox.maxLon,
      );
    }
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
      try {
        await _source.fetchWaysInBbox(
          minLat: row.bboxMinLat,
          minLon: row.bboxMinLon,
          maxLat: row.bboxMaxLat,
          maxLon: row.bboxMaxLon,
        );
        await _pendingDao.removeByTrip(row.tripId);
        await _repository.transitionToPending(row.tripId);
        // Phase 5 hook: fire matching in the background (unawaited).
        unawaited(
          _matchCoordinator?.onTripReadyForMatching(row.tripId),
        );
        _log.info('drained trip ${row.tripId} → pending');
      } on Object catch (e) {
        _log.warning('drain retry failed for trip ${row.tripId}: $e');
        await _pendingDao.incrementAttempts(row.id, now: n);
      }
    }
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
