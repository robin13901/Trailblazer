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

    test(
      'getAllIntervals returns all rows across multiple trips, ordered by wayId',
      () async {
        final trip1 = await seedTrip();
        final trip2 = await seedTrip();
        final ts = DateTime(2026, 7, 8);

        await dao.insertBatch([
          DrivenWayIntervalsCompanion.insert(
            wayId: 30,
            tripId: Value(trip2),
            startMeters: 0,
            endMeters: 200,
            matchedAt: Value(ts),
          ),
          DrivenWayIntervalsCompanion.insert(
            wayId: 10,
            tripId: Value(trip1),
            startMeters: 0,
            endMeters: 100,
            matchedAt: Value(ts),
          ),
          DrivenWayIntervalsCompanion.insert(
            wayId: 10,
            tripId: Value(trip2),
            startMeters: 100,
            endMeters: 150,
            matchedAt: Value(ts),
          ),
          DrivenWayIntervalsCompanion.insert(
            wayId: 20,
            tripId: Value(trip1),
            startMeters: 50,
            endMeters: 300,
            matchedAt: Value(ts),
          ),
        ]);

        final all = await dao.getAllIntervals();
        expect(all, hasLength(4));
        // Ordered by wayId ascending.
        expect(all.map((r) => r.wayId).toList(), [10, 10, 20, 30]);
      },
    );

    test(
      'getAllIntervals includes rows with null tripId (SET NULL after trip deletion)',
      () async {
        final tripId = await seedTrip();
        final ts = DateTime(2026, 7, 10);

        await dao.insertBatch([
          DrivenWayIntervalsCompanion.insert(
            wayId: 99,
            tripId: Value(tripId),
            startMeters: 0,
            endMeters: 500,
            matchedAt: Value(ts),
          ),
        ]);

        // Delete the trip — FK SET NULL on driven_way_intervals.
        await tripsDao.deleteTrip(tripId);

        // Row still exists with null tripId.
        final all = await dao.getAllIntervals();
        expect(all, hasLength(1));
        expect(all.first.wayId, 99);
        expect(all.first.tripId, isNull);
      },
    );

    test(
      'getDistinctWayIds returns sorted unique way IDs',
      () async {
        final trip1 = await seedTrip();
        final trip2 = await seedTrip();
        final ts = DateTime(2026, 7, 10);

        await dao.insertBatch([
          DrivenWayIntervalsCompanion.insert(
            wayId: 50,
            tripId: Value(trip1),
            startMeters: 0,
            endMeters: 100,
            matchedAt: Value(ts),
          ),
          DrivenWayIntervalsCompanion.insert(
            wayId: 10,
            tripId: Value(trip2),
            startMeters: 0,
            endMeters: 100,
            matchedAt: Value(ts),
          ),
          DrivenWayIntervalsCompanion.insert(
            wayId: 50,
            tripId: Value(trip2),
            startMeters: 100,
            endMeters: 200,
            matchedAt: Value(ts),
          ),
        ]);

        final ids = await dao.getDistinctWayIds();
        // Two distinct ids, sorted ascending.
        expect(ids, [10, 50]);
      },
    );

    group('watchRevision', () {
      test('advances on insert, delete, and re-match (delete+reinsert)',
          () async {
        final tripId = await seedTrip();
        final ts = DateTime(2026, 7, 30);

        // Collect emissions from the revision stream. Broadcast so the
        // subscription is live before any write.
        final revisions = <int>[];
        final sub = dao.watchRevision().listen(revisions.add);
        // Let the initial (empty-table) emission land: MAX(id) COALESCE 0 +
        // COUNT 0 == 0.
        await pumpEventQueue();
        expect(revisions.last, 0, reason: 'empty table → revision 0');

        // Insert one interval — revision must strictly increase.
        await dao.insertBatch([
          DrivenWayIntervalsCompanion.insert(
            wayId: 1,
            tripId: Value(tripId),
            startMeters: 0,
            endMeters: 100,
            matchedAt: Value(ts),
          ),
        ]);
        await pumpEventQueue();
        final afterInsert = revisions.last;
        expect(afterInsert, greaterThan(0),
            reason: 'insert must advance the revision');

        // Re-match path: delete the trip's rows then reinsert. Even though the
        // row COUNT returns to 1, MAX(id) climbs (autoincrement never reuses
        // ids) so the revision is strictly higher than before — this is the
        // exact case the 2026-07-30 overlay dedup fix depends on (a same-bbox
        // re-drive that would otherwise emit an equal LatLngBounds).
        await dao.deleteByTrip(tripId);
        await pumpEventQueue();
        final afterDelete = revisions.last;
        expect(afterDelete, isNot(afterInsert),
            reason: 'delete must change the revision');

        await dao.insertBatch([
          DrivenWayIntervalsCompanion.insert(
            wayId: 1,
            tripId: Value(tripId),
            startMeters: 0,
            endMeters: 100,
            matchedAt: Value(ts),
          ),
        ]);
        await pumpEventQueue();
        final afterReinsert = revisions.last;
        expect(afterReinsert, greaterThan(afterInsert),
            reason:
                're-match (delete+reinsert) must advance PAST the prior value '
                'via monotonic MAX(id)');

        await sub.cancel();
      });
    });
  });
}
