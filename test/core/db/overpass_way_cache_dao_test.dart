import 'dart:typed_data';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/overpass_way_cache_dao.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake gzip payload of exactly [bytes] bytes. Not real gzip — the DAO only
/// stores the blob and its length, so any Uint8List works for size-budget
/// exercises.
Uint8List _fakePayload(int bytes) => Uint8List(bytes);

void main() {
  late AppDatabase db;
  late OverpassWayCacheDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = OverpassWayCacheDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('OverpassWayCacheDao', () {
    test('put + getByTile round-trip', () async {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final now = DateTime(2026, 7, 8, 12);
      await dao.put(
        z: 12,
        x: 2200,
        y: 1345,
        payloadGzip: payload,
        wayCount: 42,
        now: now,
      );

      final row = await dao.getByTile(12, 2200, 1345);
      expect(row, isNotNull);
      expect(row!.tileZ, 12);
      expect(row.tileX, 2200);
      expect(row.tileY, 1345);
      expect(row.wayCount, 42);
      expect(row.payloadGzip, payload);
      expect(row.payloadBytes, 5);
      expect(
        row.fetchedAt.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
    });

    test('put upsert overwrites on same tile ID', () async {
      final first = Uint8List.fromList([1, 1, 1]);
      final second = Uint8List.fromList([9, 9, 9, 9, 9]);
      await dao.put(
        z: 12,
        x: 2200,
        y: 1345,
        payloadGzip: first,
        wayCount: 10,
      );
      await dao.put(
        z: 12,
        x: 2200,
        y: 1345,
        payloadGzip: second,
        wayCount: 99,
      );

      final rows = await db
          .customSelect('SELECT COUNT(*) AS c FROM overpass_way_cache')
          .getSingle();
      expect(rows.read<int>('c'), 1);

      final row = await dao.getByTile(12, 2200, 1345);
      expect(row!.payloadGzip, second);
      expect(row.wayCount, 99);
    });

    test('sweepTtl removes rows older than 30 days', () async {
      final now = DateTime(2026, 7, 8, 12);
      final old = now.subtract(const Duration(days: 31));
      final fresh = now.subtract(const Duration(days: 29));

      await dao.put(
        z: 12,
        x: 1,
        y: 1,
        payloadGzip: Uint8List(4),
        wayCount: 1,
        now: old,
      );
      await dao.put(
        z: 12,
        x: 2,
        y: 2,
        payloadGzip: Uint8List(4),
        wayCount: 2,
        now: fresh,
      );

      final deleted = await dao.sweepTtl(now: now);
      expect(deleted, 1);

      expect(await dao.getByTile(12, 1, 1), isNull);
      expect(await dao.getByTile(12, 2, 2), isNotNull);
    });

    test(
      'enforceLruBudget evicts oldest rows when total exceeds 50 MB',
      () async {
        // Seed 30 rows of 2 MB each = 60 MB total, each with a distinct
        // fetchedAt so LRU ordering is deterministic (i=0 oldest, i=29 newest).
        //
        // The invariant under test: after any write that pushes total bytes
        // above the 50 MB high water mark, LRU eviction runs and drains
        // toward the 40 MB low water. Subsequent writes below 50 MB do NOT
        // re-trigger eviction — so the final steady-state can be anywhere
        // in [low_water, high_water] depending on write ordering.
        const rowBytes = 2 * 1024 * 1024; // 2 MB
        final now = DateTime(2026, 7, 8, 12);
        for (var i = 0; i < 30; i++) {
          await dao.put(
            z: 12,
            x: 1000 + i,
            y: 500,
            payloadGzip: _fakePayload(rowBytes),
            wayCount: 100,
            now: now.subtract(Duration(hours: 30 - i)),
          );
        }

        final total = await dao.totalBytes();
        // Must be strictly under the 50 MB high water — eviction fired at
        // least once during the 30-row seed run.
        expect(total, lessThanOrEqualTo(50 * 1024 * 1024));
        // With 2 MB rows and a 30-row seed, eviction fires exactly once at
        // insert #26 (26×2 MB = 52 MB > 50 MB), drains the cache from 52 MB
        // down to 40 MB (removing 6 oldest rows), then inserts #27..#30 add
        // 4 more rows for a steady state of 24 rows × 2 MB = 48 MB.
        // Bound the assertion to [40 MB, 48 MB] to catch a regression where
        // eviction under-drains or over-drains.
        expect(total, greaterThanOrEqualTo(40 * 1024 * 1024));
        expect(total, lessThanOrEqualTo(48 * 1024 * 1024));

        // Oldest tiles (smallest i) must be gone; newest (largest i) survive.
        expect(await dao.getByTile(12, 1000, 500), isNull);
        expect(await dao.getByTile(12, 1029, 500), isNotNull);
      },
    );

    test('totalBytes returns 0 on empty table', () async {
      expect(await dao.totalBytes(), 0);
    });
  });
}
