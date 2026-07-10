// Trailblazer Phase 8, Plan 08-05 (Wave 2):
// region_browser_provider_test.dart — ProviderContainer unit tests.
//
// Covers:
//   1. regionBrowserProvider: resolves to %-desc sorted list, level-2 excluded.
//   2. regionBrowserFilteredProvider: prefix query returns starts-with matches
//      ranked above contains-anywhere; empty query returns full list.
//
// Uses an in-memory Drift AppDatabase + overridden adminRegionLookupProvider
// with a fake AdminRegionLookup. Package imports only.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake AdminRegionLookup
// ---------------------------------------------------------------------------

/// In-memory fake with a fixed osmId → AdminRegion map.
class _FakeLookup implements AdminRegionLookup {
  _FakeLookup(this._byOsmId);

  final Map<int, AdminRegion> _byOsmId;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<AdminRegion?> regionAt(
    double lat,
    double lon,
    int adminLevel,
  ) async =>
      null; // not called by regionBrowserProvider

  @override
  AdminRegion? regionByOsmId(int osmId) => _byOsmId[osmId];

  @override
  void invalidate() {}

  @override
  int get regionCount => _byOsmId.length;

  @override
  int get bundleLoadCount => 0;
}

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

AdminRegion _region(int osmId, int adminLevel, String name) => AdminRegion(
      osmId: osmId,
      adminLevel: adminLevel,
      name: name,
      bboxMinLat: 49,
      bboxMinLon: 9,
      bboxMaxLat: 50,
      bboxMaxLon: 10,
      polygons: const [
        [
          [
            [49, 9],
            [50, 9],
            [50, 10],
            [49, 10],
            [49, 9],
          ],
        ],
      ],
    );

Future<void> _upsertRow(
  AppDatabase db, {
  required String regionId,
  required double drivenLengthM,
  required double totalLengthM,
}) {
  return db.into(db.coverageCache).insertOnConflictUpdate(
        CoverageCacheCompanion.insert(
          regionId: regionId,
          drivenLengthM: Value(drivenLengthM),
          totalLengthM: Value(totalLengthM),
          updatedAt: Value(DateTime(2026, 7, 11)),
        ),
      );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('regionBrowserProvider', () {
    test(
      'resolves to %-desc sorted list, level-2 excluded',
      () async {
        // Seed 4 rows: level-8 (60%), level-10 (20%), level-4 (5%), level-2 (90%).
        await _upsertRow(db, regionId: '1001', drivenLengthM: 600, totalLengthM: 1000);
        await _upsertRow(db, regionId: '1002', drivenLengthM: 200, totalLengthM: 1000);
        await _upsertRow(db, regionId: '1003', drivenLengthM: 50, totalLengthM: 1000);
        await _upsertRow(db, regionId: '1004', drivenLengthM: 900, totalLengthM: 1000);

        final fakeLookup = _FakeLookup({
          1001: _region(1001, 8, 'Kleinheubach'),
          1002: _region(1002, 10, 'Ortsteil A'),
          1003: _region(1003, 4, 'Bayern'),
          1004: _region(1004, 2, 'Deutschland'), // MUST be excluded
        });

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            adminRegionLookupProvider.overrideWithValue(fakeLookup),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(regionBrowserProvider.future);

        // Level 2 must be absent.
        expect(result.any((r) => r.adminLevel == 2), isFalse);
        // 3 remaining entries.
        expect(result.length, 3);
        // %-desc order: 60 > 20 > 5.
        expect(result[0].osmId, 1001); // 60%
        expect(result[1].osmId, 1002); // 20%
        expect(result[2].osmId, 1003); // 5%
      },
    );
  });

  group('regionBrowserFilteredProvider', () {
    test(
      'starts-with match ranks above contains-anywhere; empty query = full list',
      () async {
        // Seed: 'Kleinheubach' (60%), 'Heubach' (30%), 'Stuttgart' (10%).
        await _upsertRow(db, regionId: '2001', drivenLengthM: 600, totalLengthM: 1000);
        await _upsertRow(db, regionId: '2002', drivenLengthM: 300, totalLengthM: 1000);
        await _upsertRow(db, regionId: '2003', drivenLengthM: 100, totalLengthM: 1000);

        final fakeLookup = _FakeLookup({
          2001: _region(2001, 8, 'Kleinheubach'),
          2002: _region(2002, 8, 'Heubach'),
          2003: _region(2003, 4, 'Stuttgart'),
        });

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            adminRegionLookupProvider.overrideWithValue(fakeLookup),
          ],
        );
        addTearDown(container.dispose);

        // Wait for the browser list to load.
        await container.read(regionBrowserProvider.future);

        // Empty query → full list (3 items, %-desc).
        final full = container.read(regionBrowserFilteredProvider);
        expect(full.length, 3);
        expect(full[0].osmId, 2001); // 60%
        expect(full[1].osmId, 2002); // 30%
        expect(full[2].osmId, 2003); // 10%

        // Query 'heu': starts-with → Heubach; contains → Kleinheubach.
        container.read(regionSearchQueryProvider.notifier).query = 'heu';
        final filtered = container.read(regionBrowserFilteredProvider);
        expect(filtered.length, 2);
        expect(filtered[0].name, 'Heubach'); // starts-with 'heu'
        expect(filtered[1].name, 'Kleinheubach'); // contains 'heu'

        // Query 'stuttgart': exact starts-with.
        container.read(regionSearchQueryProvider.notifier).query = 'stuttgart';
        final stuttgart = container.read(regionBrowserFilteredProvider);
        expect(stuttgart.length, 1);
        expect(stuttgart[0].name, 'Stuttgart');

        // Query with no match.
        container.read(regionSearchQueryProvider.notifier).query = 'xyz';
        final empty = container.read(regionBrowserFilteredProvider);
        expect(empty.isEmpty, isTrue);
      },
    );
  });
}
