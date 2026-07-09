// Trailblazer Phase 6, Plan 06-02 Task 2 tests:
// TripsInboxDao inbox / history / in-flight streams + Keep flip + single-row
// lookup, against an in-memory Drift database.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late TripsInboxDao inboxDao;
  late TripsDao tripsDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    inboxDao = TripsInboxDao(db);
    tripsDao = TripsDao(db);
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  /// Insert a trip with the given status + endedAt; returns its id.
  Future<int> seedTrip({
    required TripStatus status,
    DateTime? endedAt,
    double? distanceMeters,
    int? durationSeconds,
  }) {
    return db.into(db.trips).insert(
          TripsCompanion.insert(
            startedAt: DateTime(2026, 7, 9, 8),
            endedAt: Value(endedAt ?? DateTime(2026, 7, 9, 9)),
            distanceMeters: Value(distanceMeters),
            durationSeconds: Value(durationSeconds),
            status: Value(status),
            manuallyStarted: const Value(false),
          ),
        );
  }

  /// Insert [count] trip_points for [tripId] starting at seq 1.
  Future<void> seedPoints(
    int tripId, {
    int count = 3,
    double baseLat = 49.79,
    double baseLon = 9.18,
  }) async {
    final now = DateTime(2026, 7, 9, 8);
    await tripsDao.appendPointsBatch(
      tripId,
      List.generate(
        count,
        (i) => TripPointsCompanion.insert(
          tripId: tripId,
          seq: i + 1,
          ts: now.add(Duration(seconds: i)),
          lat: baseLat + i * 0.001,
          lon: baseLon + i * 0.001,
        ),
      ),
    );
  }

  Future<void> seedIntervals(int tripId, int count) async {
    for (var i = 0; i < count; i++) {
      await db.into(db.drivenWayIntervals).insert(
            DrivenWayIntervalsCompanion.insert(
              wayId: 1000 + i,
              tripId: Value(tripId),
              startMeters: 0,
              endMeters: 100,
              matchedAt: Value(DateTime(2026, 7, 9, 10)),
            ),
          );
    }
  }

  group('watchInboxTrips', () {
    test('yields only matched trips, newest ended_at first', () async {
      await seedTrip(
        status: TripStatus.matched,
        endedAt: DateTime(2026, 7, 9, 9),
      );
      await seedTrip(
        status: TripStatus.matched,
        endedAt: DateTime(2026, 7, 9, 11),
      );
      await seedTrip(status: TripStatus.confirmed);
      await seedTrip(status: TripStatus.pending);
      await seedTrip(status: TripStatus.rejected);

      final items = await inboxDao.watchInboxTrips().first;
      expect(items, hasLength(2));
      expect(
        items.every((i) => i.status == TripStatus.matched),
        isTrue,
      );
      // Newest ended_at first.
      expect(items.first.endedAt, DateTime(2026, 7, 9, 11));
      expect(items.last.endedAt, DateTime(2026, 7, 9, 9));
    });
  });

  group('watchHistoryTrips', () {
    test('yields matched + confirmed + pending + pendingRoadData', () async {
      await seedTrip(status: TripStatus.matched);
      await seedTrip(status: TripStatus.matched);
      await seedTrip(status: TripStatus.confirmed);
      await seedTrip(status: TripStatus.pending);
      await seedTrip(status: TripStatus.rejected);

      final items = await inboxDao.watchHistoryTrips().first;
      expect(items, hasLength(4));
      expect(
        items.any((i) => i.status == TripStatus.rejected),
        isFalse,
      );
    });
  });

  group('watchInFlightCount', () {
    test('counts pending + pendingRoadData and reacts to new rows', () async {
      await seedTrip(status: TripStatus.pending);
      await seedTrip(status: TripStatus.matched);

      expect(await inboxDao.watchInFlightCount().first, 1);

      await seedTrip(status: TripStatus.pendingRoadData);
      expect(await inboxDao.watchInFlightCount().first, 2);
    });
  });

  group('transitionToConfirmed', () {
    test('flips matched → confirmed: leaves inbox, enters history', () async {
      final id = await seedTrip(status: TripStatus.matched);

      expect(await inboxDao.watchInboxTrips().first, hasLength(1));

      await inboxDao.transitionToConfirmed(id);

      final inbox = await inboxDao.watchInboxTrips().first;
      expect(inbox.any((i) => i.id == id), isFalse);

      final history = await inboxDao.watchHistoryTrips().first;
      final row = history.firstWhere((i) => i.id == id);
      expect(row.status, TripStatus.confirmed);
    });
  });

  group('getTripWithIntervalCount', () {
    test('returns intervalCount == 3 for a matched trip with 3 intervals',
        () async {
      final id = await seedTrip(status: TripStatus.matched);
      await seedIntervals(id, 3);

      final item = await inboxDao.getTripWithIntervalCount(id);
      expect(item, isNotNull);
      expect(item!.intervalCount, 3);
      expect(item.isFailMatched, isFalse);
    });

    test('fail-matched trip (0 intervals) → isFailMatched true', () async {
      final id = await seedTrip(status: TripStatus.matched);

      final item = await inboxDao.getTripWithIntervalCount(id);
      expect(item!.intervalCount, 0);
      expect(item.isFailMatched, isTrue);
    });

    test('missing trip → null', () async {
      expect(await inboxDao.getTripWithIntervalCount(999999), isNull);
    });
  });

  group('derived start/end coordinates', () {
    test('populate from first/last trip_points row by seq', () async {
      final id = await seedTrip(status: TripStatus.matched);
      await seedPoints(id);

      final item = await inboxDao.getTripWithIntervalCount(id);
      expect(item!.startLat, closeTo(49.79, 1e-9));
      expect(item.startLon, closeTo(9.18, 1e-9));
      // Last of 3 points: base + 2 * 0.001.
      expect(item.endLat, closeTo(49.792, 1e-9));
      expect(item.endLon, closeTo(9.182, 1e-9));
    });

    test('zero-point trip → null coordinates', () async {
      final id = await seedTrip(status: TripStatus.matched);

      final item = await inboxDao.getTripWithIntervalCount(id);
      expect(item!.startLat, isNull);
      expect(item.endLat, isNull);
    });
  });

  group('ordering', () {
    test('history rows returned newest-first by ended_at', () async {
      await seedTrip(
        status: TripStatus.confirmed,
        endedAt: DateTime(2026, 7, 9, 8),
      );
      await seedTrip(
        status: TripStatus.confirmed,
        endedAt: DateTime(2026, 7, 9, 12),
      );
      await seedTrip(
        status: TripStatus.confirmed,
        endedAt: DateTime(2026, 7, 9, 10),
      );

      final items = await inboxDao.watchHistoryTrips().first;
      final endedAts = items.map((i) => i.endedAt).toList();
      expect(endedAts, [
        DateTime(2026, 7, 9, 12),
        DateTime(2026, 7, 9, 10),
        DateTime(2026, 7, 9, 8),
      ]);
    });
  });
}
