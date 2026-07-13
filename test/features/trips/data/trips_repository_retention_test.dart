// Tests for TripsRepository.sweepRawGpsRetention retention-window sentinels
// (Plan 09-03). Complements trips_dao_retention_test.dart (which covers the
// TripsDao layer); this file focuses on the repository-level Duration
// semantics introduced for SET-05.
//
// Key sentinels tested here:
//   Duration(days: 30) — prune only trips older than 30 days
//   Duration.zero      — prune all matched-trip points (day-0)
//
// Uses AppDatabase(NativeDatabase.memory()) — no migration stubs needed
// (raw DDL is created fresh per setUp).

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
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON required for CASCADE).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  // ── helpers ───────────────────────────────────────────────────────────────

  Future<int> seedTrip() =>
      tripsDao.openTrip(startedAt: DateTime.now(), manuallyStarted: false);

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

  Future<int> pointCount(int tripId) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM trip_points WHERE trip_id = ?',
          variables: [Variable.withInt(tripId)],
          readsFrom: {db.tripPoints},
        )
        .getSingle();
    return row.read<int>('c');
  }

  // ── retention sentinel: Duration(days: 30) ────────────────────────────────

  group('sweepRawGpsRetention — 30-day retention sentinel', () {
    test('deletes points for trips whose intervals are ALL > 30 days old',
        () async {
      final now = DateTime(2026, 7, 13, 12);
      final oldTripId = await seedTrip();
      await seedPoints(oldTripId, count: 4);
      // Only interval is 40 days old — eligible.
      await seedInterval(oldTripId, now.subtract(const Duration(days: 40)));

      final result = await repo.sweepRawGpsRetention(
        now: now,
      );
      expect(result.isOk, isTrue);
      result.when(ok: (n) => expect(n, 4), err: (_) => fail('Expected Ok'));
      expect(await pointCount(oldTripId), 0);
    });

    test('keeps points for trips with a recent interval', () async {
      final now = DateTime(2026, 7, 13, 12);
      final recentTripId = await seedTrip();
      await seedPoints(recentTripId);
      // Interval is only 5 days old — within the 30-day window.
      await seedInterval(recentTripId, now.subtract(const Duration(days: 5)));

      final result = await repo.sweepRawGpsRetention(
        now: now,
      );
      expect(result.isOk, isTrue);
      result.when(ok: (n) => expect(n, 0), err: (_) => fail('Expected Ok'));
      expect(await pointCount(recentTripId), 3);
    });

    test('deletes old trip points but keeps recent trip points', () async {
      final now = DateTime(2026, 7, 13, 12);
      final oldTripId = await seedTrip();
      await seedPoints(oldTripId);
      await seedInterval(oldTripId, now.subtract(const Duration(days: 40)));

      final recentTripId = await seedTrip();
      await seedPoints(recentTripId, count: 2);
      await seedInterval(
          recentTripId, now.subtract(const Duration(days: 10)));

      final result = await repo.sweepRawGpsRetention(
        now: now,
      );
      expect(result.isOk, isTrue);
      result.when(ok: (n) => expect(n, 3), err: (_) => fail('Expected Ok'));
      expect(await pointCount(oldTripId), 0);
      expect(await pointCount(recentTripId), 2);
    });

    test('returns Ok(count) matching rows deleted', () async {
      final now = DateTime(2026, 7, 13, 12);
      final tripId = await seedTrip();
      await seedPoints(tripId, count: 5);
      await seedInterval(tripId, now.subtract(const Duration(days: 60)));

      final result = await repo.sweepRawGpsRetention(
        now: now,
      );
      result.when(ok: (n) => expect(n, 5), err: (_) => fail('Expected Ok'));
    });
  });

  // ── retention sentinel: Duration.zero (day-0 semantics) ──────────────────

  group('sweepRawGpsRetention — Duration.zero (delete after matching)', () {
    test('deletes ALL matched-trip points regardless of age', () async {
      final now = DateTime(2026, 7, 13, 12);

      // Old trip.
      final oldTripId = await seedTrip();
      await seedPoints(oldTripId);
      await seedInterval(oldTripId, now.subtract(const Duration(days: 60)));

      // Recent trip (matched just 1 second ago — still eligible with zero).
      final recentTripId = await seedTrip();
      await seedPoints(recentTripId, count: 2);
      await seedInterval(recentTripId, now.subtract(const Duration(seconds: 1)));

      final result = await repo.sweepRawGpsRetention(
        retention: Duration.zero,
        now: now,
      );
      expect(result.isOk, isTrue);
      // Both trips purged: 3 + 2 = 5 points total.
      result.when(ok: (n) => expect(n, 5), err: (_) => fail('Expected Ok'));
      expect(await pointCount(oldTripId), 0);
      expect(await pointCount(recentTripId), 0);
    });

    test('leaves unmatched trips untouched', () async {
      final now = DateTime(2026, 7, 13, 12);
      // Unmatched trip (no interval row).
      final unmatchedTripId = await seedTrip();
      await seedPoints(unmatchedTripId, count: 4);

      final result = await repo.sweepRawGpsRetention(
        retention: Duration.zero,
        now: now,
      );
      expect(result.isOk, isTrue);
      result.when(ok: (n) => expect(n, 0), err: (_) => fail('Expected Ok'));
      expect(await pointCount(unmatchedTripId), 4);
    });

    test('returns Ok(count) matching rows deleted', () async {
      final now = DateTime(2026, 7, 13, 12);
      final tripId = await seedTrip();
      await seedPoints(tripId, count: 6);
      await seedInterval(tripId, now.subtract(const Duration(days: 1)));

      final result = await repo.sweepRawGpsRetention(
        retention: Duration.zero,
        now: now,
      );
      result.when(ok: (n) => expect(n, 6), err: (_) => fail('Expected Ok'));
    });
  });
}
