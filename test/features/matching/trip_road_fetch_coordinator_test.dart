// Phase 4 rescope Wave 2 (Plan 04-15):
// Unit tests for [TripRoadFetchCoordinator].
//
// Uses a real in-memory `AppDatabase` (for `PendingRoadFetchesDao` +
// `TripsDao` behaviour) + a `FakeWayCandidateSource` (no network) + a
// `FakeConnectivitySeam` (deterministic online/offline).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/pending_road_fetches_dao.dart';
import 'package:auto_explore/features/matching/data/connectivity_seam.dart';
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

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async {
    calls++;
    if (shouldThrow) {
      throw Exception('fake network failure');
    }
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
      now: now,
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
}
