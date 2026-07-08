import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late DrivenWayIntervalsDao dao;
  late TripsDao tripsDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = DrivenWayIntervalsDao(db);
    tripsDao = TripsDao(db);
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON required for FK SET NULL).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTrip() =>
      tripsDao.openTrip(startedAt: DateTime.now(), manuallyStarted: true);

  group('DrivenWayIntervalsDao', () {
    test(
      'insertBatch writes N rows and getByTrip returns them ordered by matchedAt',
      () async {
        final trip1 = await seedTrip();
        final trip2 = await seedTrip();
        final base = DateTime(2026, 7, 8, 12);

        await dao.insertBatch([
          // trip1 — two rows with different matchedAt (later inserted first
          // to confirm ORDER BY matchedAt, not insertion order).
          DrivenWayIntervalsCompanion.insert(
            wayId: 10,
            tripId: Value(trip1),
            startMeters: 0,
            endMeters: 100,
            matchedAt: Value(base.add(const Duration(hours: 2))),
          ),
          DrivenWayIntervalsCompanion.insert(
            wayId: 11,
            tripId: Value(trip1),
            startMeters: 100,
            endMeters: 200,
            matchedAt: Value(base.add(const Duration(hours: 1))),
          ),
          // trip2 — one row.
          DrivenWayIntervalsCompanion.insert(
            wayId: 20,
            tripId: Value(trip2),
            startMeters: 0,
            endMeters: 50,
            matchedAt: Value(base.add(const Duration(hours: 3))),
          ),
        ]);

        final rows = await dao.getByTrip(trip1);
        expect(rows, hasLength(2));
        // Ascending matchedAt: +1h before +2h.
        expect(rows[0].wayId, 11);
        expect(rows[1].wayId, 10);
      },
    );

    test('insertBatch on empty list is a no-op', () async {
      await dao.insertBatch([]);
      final count = await db
          .customSelect('SELECT COUNT(*) AS c FROM driven_way_intervals')
          .getSingle();
      expect(count.read<int>('c'), 0);
    });

    test('deleteByTrip removes only the target trip rows', () async {
      final trip1 = await seedTrip();
      final trip2 = await seedTrip();
      final ts = DateTime(2026, 7, 8);

      await dao.insertBatch([
        DrivenWayIntervalsCompanion.insert(
          wayId: 1,
          tripId: Value(trip1),
          startMeters: 0,
          endMeters: 10,
          matchedAt: Value(ts),
        ),
        DrivenWayIntervalsCompanion.insert(
          wayId: 2,
          tripId: Value(trip2),
          startMeters: 0,
          endMeters: 20,
          matchedAt: Value(ts),
        ),
      ]);

      final deleted = await dao.deleteByTrip(trip1);
      expect(deleted, 1);

      expect(await dao.getByTrip(trip1), isEmpty);
      expect(await dao.getByTrip(trip2), hasLength(1));
    });

    test('intervals survive parent trip deletion (FK SET NULL)', () async {
      final tripId = await seedTrip();
      final ts = DateTime(2026, 7, 8, 10);

      await dao.insertBatch([
        DrivenWayIntervalsCompanion.insert(
          wayId: 42,
          tripId: Value(tripId),
          startMeters: 0,
          endMeters: 500,
          matchedAt: Value(ts),
        ),
      ]);

      // Verify the interval exists with a non-null trip_id before deletion.
      final before = await dao.getByTrip(tripId);
      expect(before, hasLength(1));

      // Delete the parent trip — FK ON DELETE SET NULL.
      await tripsDao.deleteTrip(tripId);

      // After trip deletion, getByTrip returns empty (trip_id no longer
      // matches), but the interval row itself still exists with trip_id NULL.
      expect(await dao.getByTrip(tripId), isEmpty);

      final nullRows = await (db.select(db.drivenWayIntervals)
            ..where((t) => t.tripId.isNull()))
          .get();
      expect(nullRows, hasLength(1));
      expect(nullRows.first.wayId, 42);
      expect(nullRows.first.tripId, isNull);
    });

    test("direction default is 'forward'", () async {
      final tripId = await seedTrip();
      // Insert without specifying direction — relies on DB default 'forward'.
      await dao.insertBatch([
        DrivenWayIntervalsCompanion.insert(
          wayId: 7,
          tripId: Value(tripId),
          startMeters: 0,
          endMeters: 100,
          matchedAt: Value(DateTime(2026, 7, 8)),
          // direction intentionally omitted
        ),
      ]);

      final rows = await dao.getByTrip(tripId);
      expect(rows, hasLength(1));
      expect(rows.first.direction, 'forward');
    });
  });
}
