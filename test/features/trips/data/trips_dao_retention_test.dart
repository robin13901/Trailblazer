import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late TripsDao tripsDao;
  late DrivenWayIntervalsDao intervalsDao;
  late TripsRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tripsDao = TripsDao(db);
    intervalsDao = DrivenWayIntervalsDao(db);
    repo = TripsRepository(tripsDao);
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON required for cascade).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  /// Seed a trip row and return its id.
  Future<int> seedTrip() =>
      tripsDao.openTrip(startedAt: DateTime.now(), manuallyStarted: true);

  /// Insert [count] trip_points for [tripId] starting at seq 1.
  Future<void> seedPoints(int tripId, {int count = 3}) async {
    final now = DateTime.now();
    await tripsDao.appendPointsBatch(
      tripId,
      List.generate(
        count,
        (i) => TripPointsCompanion.insert(
          tripId: tripId,
          seq: i + 1,
          ts: now.add(Duration(seconds: i)),
          lat: 49.0 + i * 0.001,
          lon: 9.0 + i * 0.001,
        ),
      ),
    );
  }

  /// Insert one driven_way_intervals row for [tripId] with given [matchedAt].
  Future<void> seedInterval(int tripId, DateTime matchedAt) async {
    await intervalsDao.insertBatch([
      DrivenWayIntervalsCompanion.insert(
        wayId: 100 + tripId,
        tripId: Value(tripId),
        startMeters: 0,
        endMeters: 100,
        matchedAt: Value(matchedAt),
      ),
    ]);
  }

  Future<int> tripPointCount(int tripId) async {
    final result = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM trip_points WHERE trip_id = ?',
          variables: [Variable.withInt(tripId)],
          readsFrom: {db.tripPoints},
        )
        .getSingle();
    return result.read<int>('c');
  }

  group('TripsDao retention sweep', () {
    test('sweep with no matched trips returns 0 and deletes nothing', () async {
      final tripId = await seedTrip();
      await seedPoints(tripId);
      // No intervals → trip is not matched → nothing eligible for sweep.

      final count = await tripsDao.deleteTripPointsForMatchedTripsOlderThan(
        DateTime.now(),
      );
      expect(count, 0);
      expect(await tripPointCount(tripId), 3);
    });

    test(
      'sweep deletes points for a trip whose only interval is older than cutoff',
      () async {
        final now = DateTime(2026, 7, 8, 12);
        final tripId = await seedTrip();
        await seedPoints(tripId);
        await seedInterval(tripId, now.subtract(const Duration(days: 40)));

        final deleted = await tripsDao
            .deleteTripPointsForMatchedTripsOlderThan(
          now.subtract(const Duration(days: 30)),
        );
        expect(deleted, 3);

        // Points gone; trip row itself still exists.
        expect(await tripPointCount(tripId), 0);
        final trip =
            await (db.select(db.trips)..where((t) => t.id.equals(tripId)))
                .getSingleOrNull();
        expect(trip, isNotNull);
      },
    );

    test(
      'sweep KEEPS points for a trip with a recent matched interval',
      () async {
        final now = DateTime(2026, 7, 8, 12);
        final tripId = await seedTrip();
        await seedPoints(tripId);
        // Interval is only 10 days old — within the 30-day window.
        await seedInterval(tripId, now.subtract(const Duration(days: 10)));

        final deleted = await tripsDao
            .deleteTripPointsForMatchedTripsOlderThan(
          now.subtract(const Duration(days: 30)),
        );
        expect(deleted, 0);
        expect(await tripPointCount(tripId), 3);
      },
    );

    test(
      'sweep KEEPS points for a trip with mixed-age intervals when MAX is recent',
      () async {
        final now = DateTime(2026, 7, 8, 12);
        final tripId = await seedTrip();
        await seedPoints(tripId);
        // Two intervals: one old (40d), one recent (5d).
        // MAX(matched_at) = now - 5d > cutoff = now - 30d → trip retained.
        await seedInterval(tripId, now.subtract(const Duration(days: 40)));
        await intervalsDao.insertBatch([
          DrivenWayIntervalsCompanion.insert(
            wayId: 200,
            tripId: Value(tripId),
            startMeters: 100,
            endMeters: 200,
            matchedAt: Value(now.subtract(const Duration(days: 5))),
          ),
        ]);

        final deleted = await tripsDao
            .deleteTripPointsForMatchedTripsOlderThan(
          now.subtract(const Duration(days: 30)),
        );
        expect(deleted, 0);
        expect(await tripPointCount(tripId), 3);
      },
    );

    test('sweep is idempotent', () async {
      final now = DateTime(2026, 7, 8, 12);
      final tripId = await seedTrip();
      await seedPoints(tripId);
      await seedInterval(tripId, now.subtract(const Duration(days: 40)));

      final cutoff = now.subtract(const Duration(days: 30));

      final first =
          await tripsDao.deleteTripPointsForMatchedTripsOlderThan(cutoff);
      expect(first, 3);

      // Second call: points already gone → 0 rows deleted.
      final second =
          await tripsDao.deleteTripPointsForMatchedTripsOlderThan(cutoff);
      expect(second, 0);
    });
  });

  group('TripsRepository sweepRawGpsRetention', () {
    test('returns Ok(n) with correct count on successful sweep', () async {
      final now = DateTime(2026, 7, 8, 12);
      final tripId = await seedTrip();
      await seedPoints(tripId);
      await seedInterval(tripId, now.subtract(const Duration(days: 40)));

      final result = await repo.sweepRawGpsRetention(
        now: now,
      );
      expect(result.isOk, true);
      result.when(
        ok: (n) => expect(n, 3),
        err: (_) => fail('Expected Ok'),
      );
    });

    test('uses 30-day default when no retention supplied', () async {
      final now = DateTime(2026, 7, 8, 12);
      final tripId = await seedTrip();
      await seedPoints(tripId, count: 2);
      await seedInterval(tripId, now.subtract(const Duration(days: 40)));

      // Inject 'now' so the cutoff is deterministic.
      final result = await repo.sweepRawGpsRetention(now: now);
      result.when(
        ok: (n) => expect(n, 2),
        err: (_) => fail('Expected Ok'),
      );
    });
  });
}
