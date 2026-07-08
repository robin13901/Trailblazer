import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/pending_road_fetches_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PendingRoadFetchesDao dao;
  late TripsDao tripsDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = PendingRoadFetchesDao(db);
    tripsDao = TripsDao(db);
    // Force `beforeOpen` PRAGMAs to run so foreign_keys=ON is applied.
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTrip() =>
      tripsDao.openTrip(startedAt: DateTime.now(), manuallyStarted: true);

  group('PendingRoadFetchesDao', () {
    test('enqueue + getByTrip round-trip', () async {
      final tripId = await seedTrip();
      final rowId = await dao.enqueue(
        tripId: tripId,
        minLat: 52.5,
        minLon: 13.3,
        maxLat: 52.6,
        maxLon: 13.5,
      );
      expect(rowId, greaterThan(0));

      final row = await dao.getByTrip(tripId);
      expect(row, isNotNull);
      expect(row!.tripId, tripId);
      expect(row.bboxMinLat, 52.5);
      expect(row.bboxMinLon, 13.3);
      expect(row.bboxMaxLat, 52.6);
      expect(row.bboxMaxLon, 13.5);
      expect(row.attempts, 0);
      expect(row.lastAttemptAt, isNull);
    });

    test('listPending returns oldest-first', () async {
      final t1 = await seedTrip();
      final t2 = await seedTrip();
      final t3 = await seedTrip();

      await dao.enqueue(
        tripId: t1,
        minLat: 1,
        minLon: 1,
        maxLat: 2,
        maxLon: 2,
      );
      // Sleep briefly to ensure distinct createdAt timestamps at second
      // granularity (Drift persists DateTime as int-epoch seconds).
      await Future<void>.delayed(const Duration(seconds: 1));
      await dao.enqueue(
        tripId: t2,
        minLat: 3,
        minLon: 3,
        maxLat: 4,
        maxLon: 4,
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await dao.enqueue(
        tripId: t3,
        minLat: 5,
        minLon: 5,
        maxLat: 6,
        maxLon: 6,
      );

      final pending = await dao.listPending();
      expect(pending.map((p) => p.tripId).toList(), [t1, t2, t3]);
    });

    test('incrementAttempts bumps count and stamps lastAttemptAt', () async {
      final tripId = await seedTrip();
      await dao.enqueue(
        tripId: tripId,
        minLat: 1,
        minLon: 1,
        maxLat: 2,
        maxLon: 2,
      );
      final initial = await dao.getByTrip(tripId);
      expect(initial!.attempts, 0);
      expect(initial.lastAttemptAt, isNull);

      final now1 = DateTime(2026, 7, 8, 12);
      final rows1 = await dao.incrementAttempts(initial.id, now: now1);
      expect(rows1, 1);
      final after1 = await dao.getByTrip(tripId);
      expect(after1!.attempts, 1);
      expect(
        after1.lastAttemptAt!.millisecondsSinceEpoch,
        now1.millisecondsSinceEpoch,
      );

      final now2 = DateTime(2026, 7, 8, 13);
      await dao.incrementAttempts(initial.id, now: now2);
      final after2 = await dao.getByTrip(tripId);
      expect(after2!.attempts, 2);
      expect(
        after2.lastAttemptAt!.millisecondsSinceEpoch,
        now2.millisecondsSinceEpoch,
      );
    });

    test('removeByTrip deletes matching rows and leaves others', () async {
      final t1 = await seedTrip();
      final t2 = await seedTrip();
      await dao.enqueue(
        tripId: t1,
        minLat: 1,
        minLon: 1,
        maxLat: 2,
        maxLon: 2,
      );
      await dao.enqueue(
        tripId: t2,
        minLat: 3,
        minLon: 3,
        maxLat: 4,
        maxLon: 4,
      );

      final removed = await dao.removeByTrip(t1);
      expect(removed, 1);

      final remaining = await dao.listPending();
      expect(remaining, hasLength(1));
      expect(remaining.first.tripId, t2);
    });

    test('cascade delete when trip is deleted removes pending row', () async {
      final tripId = await seedTrip();
      await dao.enqueue(
        tripId: tripId,
        minLat: 1,
        minLon: 1,
        maxLat: 2,
        maxLon: 2,
      );
      expect(await dao.getByTrip(tripId), isNotNull);

      await tripsDao.deleteTrip(tripId);
      expect(await dao.getByTrip(tripId), isNull);
      expect(await dao.listPending(), isEmpty);
    });
  });
}
