// Trailblazer Phase 6, Plan 06-01 Task 2 tests: CoverageCacheDao CRUD +
// invalidation-shaped deletes.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late CoverageCacheDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = CoverageCacheDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('CoverageCacheDao', () {
    test('upsert + getByRegionId round-trips all fields', () async {
      final now = DateTime(2026, 7, 9, 12);
      await dao.upsert(
        regionId: '62422',
        drivenLengthM: 123.4,
        totalLengthM: 5678.9,
        updatedAt: now,
        extractVersion: 'admin-v1',
      );

      final row = await dao.getByRegionId('62422');
      expect(row, isNotNull);
      expect(row!.regionId, '62422');
      expect(row.drivenLengthM, 123.4);
      expect(row.totalLengthM, 5678.9);
      expect(row.extractVersion, 'admin-v1');
      expect(row.invalidationGen, 0);
      expect(
        row.updatedAt.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
    });

    test('upsert replaces existing row for same regionId', () async {
      final now = DateTime(2026, 7, 9, 12);
      await dao.upsert(
        regionId: 'DE-BY',
        drivenLengthM: 100,
        totalLengthM: 1000,
        updatedAt: now,
      );
      await dao.upsert(
        regionId: 'DE-BY',
        drivenLengthM: 250,
        totalLengthM: 1200,
        updatedAt: now,
        extractVersion: 'admin-v2',
      );

      final row = await dao.getByRegionId('DE-BY');
      expect(row!.drivenLengthM, 250);
      expect(row.totalLengthM, 1200);
      expect(row.extractVersion, 'admin-v2');

      final count = await db
          .customSelect('SELECT COUNT(*) AS c FROM coverage_cache')
          .getSingle();
      expect(count.read<int>('c'), 1);
    });

    test('getByRegionId returns null on miss', () async {
      expect(await dao.getByRegionId('nope'), isNull);
    });

    test('deleteByRegionIds([]) is a no-op returning 0', () async {
      final now = DateTime(2026, 7, 9);
      await dao.upsert(
        regionId: 'r1',
        drivenLengthM: 1,
        totalLengthM: 2,
        updatedAt: now,
      );

      expect(await dao.deleteByRegionIds(const []), 0);
      expect(await dao.getByRegionId('r1'), isNotNull);
    });

    test('deleteByRegionIds removes exactly the listed rows', () async {
      final now = DateTime(2026, 7, 9);
      for (final id in const ['a', 'b', 'c', 'd', 'e']) {
        await dao.upsert(
          regionId: id,
          drivenLengthM: 1,
          totalLengthM: 2,
          updatedAt: now,
        );
      }

      final deleted = await dao.deleteByRegionIds(const ['a', 'c', 'e']);
      expect(deleted, 3);
      expect(await dao.getByRegionId('a'), isNull);
      expect(await dao.getByRegionId('b'), isNotNull);
      expect(await dao.getByRegionId('c'), isNull);
      expect(await dao.getByRegionId('d'), isNotNull);
      expect(await dao.getByRegionId('e'), isNull);
    });

    test('deleteAll clears every row and reports the count', () async {
      final now = DateTime(2026, 7, 9);
      for (final id in const ['x', 'y', 'z']) {
        await dao.upsert(
          regionId: id,
          drivenLengthM: 1,
          totalLengthM: 2,
          updatedAt: now,
        );
      }

      expect(await dao.deleteAll(), 3);
      final count = await db
          .customSelect('SELECT COUNT(*) AS c FROM coverage_cache')
          .getSingle();
      expect(count.read<int>('c'), 0);
    });

    test('bumpInvalidationGen increments 0 -> 1 -> 2', () async {
      final now = DateTime(2026, 7, 9);
      await dao.upsert(
        regionId: 'DE-BY',
        drivenLengthM: 100,
        totalLengthM: 1000,
        updatedAt: now,
      );
      expect((await dao.getByRegionId('DE-BY'))!.invalidationGen, 0);

      await dao.bumpInvalidationGen('DE-BY');
      expect((await dao.getByRegionId('DE-BY'))!.invalidationGen, 1);

      await dao.bumpInvalidationGen('DE-BY');
      expect((await dao.getByRegionId('DE-BY'))!.invalidationGen, 2);
    });
  });
}
