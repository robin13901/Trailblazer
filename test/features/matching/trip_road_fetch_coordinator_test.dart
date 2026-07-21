// Phase 4 rescope Wave 2 (Plan 04-15):
// Unit tests for [TripRoadFetchCoordinator].
//
// Uses a real in-memory `AppDatabase` (for `PendingRoadFetchesDao` +
// `TripsDao` behaviour) + a `FakeWayCandidateSource` (no network) + a
// `FakeConnectivitySeam` (deterministic online/offline).

import 'dart:async';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/pending_road_fetches_dao.dart';
import 'package:auto_explore/features/matching/data/connectivity_seam.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/trip_road_fetch_coordinator.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [WayCandidateSource] that records every call.
class FakeWayCandidateSource implements WayCandidateSource {
  int calls = 0;
  bool shouldThrow = false;

  /// The `restrictTiles` argument seen on the last fetch call (corridor check).
  Set<TileId>? lastRestrictTiles;

  /// Progress steps the fake emits via `onTileProgress` on each fetch, e.g.
  /// `[(1, 4), (2, 4), (3, 4), (4, 4)]`. Empty = emit nothing.
  List<(int, int)> progressSteps = const [];

  /// Invoked (awaited) INSIDE the fetch, before it returns/throws — lets a test
  /// assert state that must hold *during* the fetch (e.g. the enqueue-first
  /// row already exists by the time the network call runs).
  Future<void> Function()? duringFetch;

  Future<void> _run({
    Set<TileId>? restrictTiles,
    void Function(int, int)? onTileProgress,
  }) async {
    calls++;
    lastRestrictTiles = restrictTiles;
    for (final (done, total) in progressSteps) {
      onTileProgress?.call(done, total);
    }
    if (duringFetch != null) await duringFetch!();
    if (shouldThrow) {
      throw Exception('fake network failure');
    }
  }

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    void Function(int done, int total)? onTileProgress,
  }) async {
    await _run(restrictTiles: restrictTiles, onTileProgress: onTileProgress);
    return const [];
  }

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    void Function(int done, int total)? onTileProgress,
  }) async {
    await _run(restrictTiles: restrictTiles, onTileProgress: onTileProgress);
    return const [];
  }
}

class FakeConnectivitySeam implements ConnectivitySeam {
  bool online = true;

  @override
  Future<bool> isOnline() async => online;
}

Future<int> _insertRecordingTrip(AppDatabase db) async {
  return db.into(db.trips).insert(
        TripsCompanion.insert(
          startedAt: DateTime(2026),
          status: const Value(TripStatus.recording),
        ),
      );
}

Future<TripStatus> _statusOf(AppDatabase db, int tripId) async {
  final row = await (db.select(db.trips)..where((t) => t.id.equals(tripId)))
      .getSingle();
  return row.status;
}

void main() {
  late AppDatabase db;
  late TripsDao tripsDao;
  late TripsRepository repository;
  late PendingRoadFetchesDao pendingDao;
  late FakeWayCandidateSource source;
  late FakeConnectivitySeam connectivity;

  /// Progress fractions captured from the coordinator's progressSink, keyed by
  /// tripId. Each fetch appends; a `null` marker records a clear() call.
  late Map<int, List<double?>> progressLog;

  const bbox = (
    minLat: 52.49,
    minLon: 13.39,
    maxLat: 52.51,
    maxLon: 13.42,
  );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tripsDao = TripsDao(db);
    repository = TripsRepository(tripsDao);
    pendingDao = db.pendingRoadFetchesDao;
    source = FakeWayCandidateSource();
    connectivity = FakeConnectivitySeam();
    progressLog = {};
  });

  tearDown(() async {
    await db.close();
  });

  TripRoadFetchCoordinator buildCoord({DateTime Function()? now}) {
    return TripRoadFetchCoordinator(
      source: source,
      pendingDao: pendingDao,
      repository: repository,
      connectivity: connectivity,
      tripsDao: tripsDao,
      now: now,
      progressSink: (tripId, frac) =>
          (progressLog[tripId] ??= []).add(frac),
      progressClearSink: (tripId) => (progressLog[tripId] ??= []).add(null),
    );
  }

  group('TripRoadFetchCoordinator.onTripStopped', () {
    test('online: source is called and trip transitions to pending',
        () async {
      final tripId = await _insertRecordingTrip(db);
      connectivity.online = true;
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      expect(source.calls, 1);
      expect(await _statusOf(db, tripId), TripStatus.pending);
      final pending = await pendingDao.listPending();
      expect(pending, isEmpty);
    });

    test('offline: source is NOT called and pending row is enqueued',
        () async {
      final tripId = await _insertRecordingTrip(db);
      connectivity.online = false;
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      expect(source.calls, 0);
      expect(await _statusOf(db, tripId), TripStatus.pendingRoadData);
      final pending = await pendingDao.listPending();
      expect(pending, hasLength(1));
      expect(pending.first.tripId, tripId);
      expect(pending.first.bboxMinLat, bbox.minLat);
    });

    test('online + fetch throws → enqueued, stays in pendingRoadData',
        () async {
      final tripId = await _insertRecordingTrip(db);
      connectivity.online = true;
      source.shouldThrow = true;
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      expect(source.calls, 1);
      expect(await _statusOf(db, tripId), TripStatus.pendingRoadData);
      final pending = await pendingDao.listPending();
      expect(pending, hasLength(1));
    });
  });

  group('TripRoadFetchCoordinator.drainQueue', () {
    test('successful fetch removes pending row and flips to pending',
        () async {
      final tripId = await _insertRecordingTrip(db);
      await tripsDao.transitionToPendingRoadData(tripId);
      await pendingDao.enqueue(
        tripId: tripId,
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );
      final coord = buildCoord();

      await coord.drainQueue();

      expect(source.calls, 1);
      expect(await _statusOf(db, tripId), TripStatus.pending);
      expect(await pendingDao.listPending(), isEmpty);
    });

    test('failed fetch increments attempts and stamps lastAttemptAt',
        () async {
      final tripId = await _insertRecordingTrip(db);
      await tripsDao.transitionToPendingRoadData(tripId);
      await pendingDao.enqueue(
        tripId: tripId,
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );
      source.shouldThrow = true;
      final t0 = DateTime(2026, 7, 8, 12);
      final coord = buildCoord(now: () => t0);

      await coord.drainQueue();

      final pending = await pendingDao.listPending();
      expect(pending, hasLength(1));
      expect(pending.first.attempts, 1);
      expect(
        pending.first.lastAttemptAt?.millisecondsSinceEpoch,
        t0.millisecondsSinceEpoch,
      );
      expect(await _statusOf(db, tripId), TripStatus.pendingRoadData);
    });

    test('backoff: 4-min-old row with attempts=0 is NOT retried (5m delay)',
        () async {
      final tripId = await _insertRecordingTrip(db);
      await tripsDao.transitionToPendingRoadData(tripId);
      // Enqueue then bump attempts to 1 with lastAttemptAt = t0 - 4m so the
      // 5-minute backoff for attempts=1 still gates the retry.
      final id = await pendingDao.enqueue(
        tripId: tripId,
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );
      final t0 = DateTime(2026, 7, 8, 12);
      // First attempt happened 4 minutes ago — attempts is now 1, so the
      // relevant backoff is delays[1] = 30 min. We use 4 min elapsed to
      // stay under both delays[0]=5m and delays[1]=30m.
      await pendingDao.incrementAttempts(
        id,
        now: t0.subtract(const Duration(minutes: 4)),
      );
      final coord = buildCoord(now: () => t0);

      await coord.drainQueue();

      expect(source.calls, 0, reason: 'backoff has not elapsed');
      // Row still there; attempts unchanged.
      final pending = await pendingDao.listPending();
      expect(pending, hasLength(1));
      expect(pending.first.attempts, 1);
    });

    test('drain abandons row after 5 attempts', () async {
      final tripId = await _insertRecordingTrip(db);
      await tripsDao.transitionToPendingRoadData(tripId);
      final id = await pendingDao.enqueue(
        tripId: tripId,
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );
      // Bump attempts to 5 (== kMaxPendingFetchAttempts).
      for (var i = 0; i < 5; i++) {
        await pendingDao.incrementAttempts(
          id,
          now: DateTime(2026).add(Duration(days: i)),
        );
      }
      source.shouldThrow = true;
      final coord = buildCoord(now: () => DateTime(2027));

      await coord.drainQueue();

      expect(source.calls, 0, reason: 'abandoned rows should not retry');
      final pending = await pendingDao.listPending();
      expect(pending, hasLength(1));
      // No further increment on an abandoned row.
      expect(pending.first.attempts, 5);
    });

    test('drain no-op when queue is empty', () async {
      final coord = buildCoord();
      await coord.drainQueue();
      expect(source.calls, 0);
    });
  });

  group('enqueue-first (orphan-proofing)', () {
    test('online: a queue row exists DURING the fetch, removed after success',
        () async {
      final tripId = await _insertRecordingTrip(db);
      connectivity.online = true;
      var rowSeenDuringFetch = false;
      source.duringFetch = () async {
        rowSeenDuringFetch = await pendingDao.getByTrip(tripId) != null;
      };
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      expect(
        rowSeenDuringFetch,
        isTrue,
        reason: 'row must be enqueued BEFORE the network attempt',
      );
      // Success → row cleaned up, trip advanced.
      expect(await pendingDao.listPending(), isEmpty);
      expect(await _statusOf(db, tripId), TripStatus.pending);
    });

    test('mid-fetch death leaves a drainable row (no throw, never resolves)',
        () async {
      // Simulate a process death: the fetch "hangs" (row already enqueued),
      // and onTripStopped never completes. The queue row must survive so the
      // next drainQueue recovers it.
      final tripId = await _insertRecordingTrip(db);
      connectivity.online = true;
      final hang = Completer<void>();
      source.duringFetch = () => hang.future; // never resolves
      final coord = buildCoord();

      // Fire and DON'T await — mimics the app dying mid-fetch.
      unawaited(coord.onTripStopped(tripId, bbox: bbox));
      await Future<void>.delayed(Duration.zero); // let it reach the fetch

      final pending = await pendingDao.listPending();
      expect(pending, hasLength(1), reason: 'orphan-proof: row persists');
      expect(await _statusOf(db, tripId), TripStatus.pendingRoadData);
    });

    test('does not double-enqueue when a row already exists', () async {
      final tripId = await _insertRecordingTrip(db);
      await tripsDao.transitionToPendingRoadData(tripId);
      await pendingDao.enqueue(
        tripId: tripId,
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );
      connectivity.online = false;
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      expect(await pendingDao.listPending(), hasLength(1));
    });
  });

  group('corridor tile restriction', () {
    test('passes restrictTiles built from the trip points', () async {
      final tripId = await _insertRecordingTrip(db);
      // Two points inside the bbox → their z12 tiles form the corridor set.
      await db.batch((b) {
        b.insertAll(db.tripPoints, [
          TripPointsCompanion.insert(
            tripId: tripId,
            seq: 0,
            lat: 52.495,
            lon: 13.40,
            ts: DateTime(2026),
          ),
          TripPointsCompanion.insert(
            tripId: tripId,
            seq: 1,
            lat: 52.505,
            lon: 13.41,
            ts: DateTime(2026, 1, 1, 0, 0, 1),
          ),
        ]);
      });
      connectivity.online = true;
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      final expected = const TileBboxMath().tilesForPath(
        const [(lat: 52.495, lon: 13.40), (lat: 52.505, lon: 13.41)],
      );
      expect(source.lastRestrictTiles, isNotNull);
      expect(source.lastRestrictTiles, expected);
    });

    test('null restrictTiles when the trip has no points', () async {
      final tripId = await _insertRecordingTrip(db);
      connectivity.online = true;
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      expect(source.lastRestrictTiles, isNull);
    });
  });

  group('progress feedback', () {
    test('forwards tile progress as a rising fraction, cleared on handoff',
        () async {
      final tripId = await _insertRecordingTrip(db);
      connectivity.online = true;
      source.progressSteps = const [(1, 4), (2, 4), (3, 4), (4, 4)];
      final coord = buildCoord();

      await coord.onTripStopped(tripId, bbox: bbox);

      final log = progressLog[tripId]!;
      // Fractions then a trailing null (clear at fetch→match handoff).
      expect(log, [0.25, 0.5, 0.75, 1.0, null]);
    });
  });

  group('reconcileOrphanedPendingRoadData', () {
    test('re-enqueues a pendingRoadData trip that has no queue row', () async {
      final tripId = await _insertRecordingTrip(db);
      // Park it in pendingRoadData with a stored bbox but NO queue row.
      await (db.update(db.trips)..where((t) => t.id.equals(tripId))).write(
        TripsCompanion(
          status: const Value(TripStatus.pendingRoadData),
          bboxMinLat: Value(bbox.minLat),
          bboxMinLon: Value(bbox.minLon),
          bboxMaxLat: Value(bbox.maxLat),
          bboxMaxLon: Value(bbox.maxLon),
        ),
      );
      final coord = buildCoord();

      final n = await coord.reconcileOrphanedPendingRoadData();

      expect(n, 1);
      final pending = await pendingDao.listPending();
      expect(pending, hasLength(1));
      expect(pending.first.tripId, tripId);
      // A following drain now completes it.
      await coord.drainQueue();
      expect(await _statusOf(db, tripId), TripStatus.pending);
    });

    test('skips a pendingRoadData trip that already has a queue row', () async {
      final tripId = await _insertRecordingTrip(db);
      await tripsDao.transitionToPendingRoadData(tripId);
      await pendingDao.enqueue(
        tripId: tripId,
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );
      final coord = buildCoord();

      final n = await coord.reconcileOrphanedPendingRoadData();

      expect(n, 0);
      expect(await pendingDao.listPending(), hasLength(1));
    });

    test('null-bbox orphan is advanced straight to pending', () async {
      final tripId = await _insertRecordingTrip(db);
      await tripsDao.transitionToPendingRoadData(tripId); // bbox stays null
      final coord = buildCoord();

      final n = await coord.reconcileOrphanedPendingRoadData();

      expect(n, 1);
      expect(await pendingDao.listPending(), isEmpty);
      expect(await _statusOf(db, tripId), TripStatus.pending);
    });
  });
}
