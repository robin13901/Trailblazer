// Trailblazer Phase 8, Plan 08-04 (Wave 2):
// FocusPillNotifier unit tests — ProviderContainer with in-memory DB.
//
// Tests:
//   1. Successful resolve: camera over seeded region+cache row → state has
//      name and percentLabel after debounce.
//   2. Fallback chain: regionAt(level 9) null, regionAt(level 8) returns
//      region → state.name is the level-8 name.
//   3. Hold-last-value: after a first resolve, push camera over an all-null
//      area; state STILL holds the previous name (never blanks).
//   4. No-cache row → percentLabel is null (widget shows "—%").

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/regions/presentation/providers/focus_pill_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show CameraPosition, LatLng;

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Callable that maps (lat, lon, level) -> AdminRegion?
typedef _RegionResolver = AdminRegion? Function(double, double, int);

/// Fake AdminRegionLookup driven by a [_RegionResolver] callback.
class _FakeAdminRegionLookup implements AdminRegionLookup {
  _FakeAdminRegionLookup(this._resolver);
  final _RegionResolver _resolver;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async =>
      _resolver(lat, lon, adminLevel);

  @override
  void invalidate() {}

  @override
  AdminRegion? regionByOsmId(int osmId) => null;

  @override
  int get regionCount => 0;

  @override
  int get bundleLoadCount => 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A tiny closed-ring polygon covering Grebenhain in Hessen (level 8).
AdminRegion _grebenhainRegion() => const AdminRegion(
      osmId: 62492,
      adminLevel: 8,
      name: 'Grebenhain',
      bboxMinLat: 50.46,
      bboxMinLon: 9.33,
      bboxMaxLat: 50.56,
      bboxMaxLon: 9.44,
      polygons: [
        [
          [
            [50.46, 9.33],
            [50.56, 9.33],
            [50.56, 9.44],
            [50.46, 9.44],
            [50.46, 9.33],
          ],
        ],
      ],
    );

/// Builds an in-memory AppDatabase and seeds a coverage_cache row for
/// [osmId] with 264 m driven / 1000 m total → 26.4%.
Future<AppDatabase> _dbWithCacheRow({required int osmId}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final dao = CoverageCacheDao(db);
  await dao.upsert(
    regionId: osmId.toString(),
    drivenLengthM: 264,
    totalLengthM: 1000,
    updatedAt: DateTime(2026, 7, 11),
  );
  return db;
}

/// Builds a ProviderContainer that overrides the lookup + cache providers.
///
/// [resolver] controls what regionAt returns.
/// [db] is the in-memory AppDatabase (its CoverageCacheDao is used).
ProviderContainer _makeContainer({
  required _RegionResolver resolver,
  required AppDatabase db,
}) {
  return ProviderContainer(
    overrides: [
      adminRegionLookupProvider.overrideWithValue(
        _FakeAdminRegionLookup(resolver),
      ),
      coverageCacheDaoProvider.overrideWithValue(
        CoverageCacheDao(db),
      ),
    ],
  );
}

/// Pushes a camera over Grebenhain centre (50.51, 9.385) at zoom 14 and waits
/// for the debounce + async resolve to settle.
///
/// Reads [focusPillProvider] first to ensure [FocusPillNotifier.build] has run
/// (i.e. the `ref.listen` on liveCameraProvider is registered) before the
/// camera update fires. Without this, the update would be missed by a lazily-
/// initialized notifier.
Future<void> _pushCamera(ProviderContainer c) async {
  // Trigger lazy initialization of FocusPillNotifier.
  c.read(focusPillProvider);
  c.read(liveCameraProvider.notifier).update(
        const CameraPosition(
          target: LatLng(50.51, 9.385),
          zoom: 14,
        ),
      );
  // Wait longer than the 150 ms debounce + async I/O slack.
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

/// Pushes a camera over a coordinate with no region (0°, 0°).
///
/// Call [_pushCamera] first in any test that uses this, so the notifier is
/// already initialized.
Future<void> _pushNoRegionCamera(ProviderContainer c) async {
  c.read(liveCameraProvider.notifier).update(
        const CameraPosition(
          target: LatLng(0, 0),
          zoom: 14,
        ),
      );
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('FocusPillNotifier', () {
    late AppDatabase db;

    setUp(() async {
      db = await _dbWithCacheRow(osmId: _grebenhainRegion().osmId);
    });

    tearDown(() async {
      await db.close();
    });

    test('1. initial state is blank (no name, no percent)', () {
      // Dart 3+ wildcard: all three params unused → all named _
      final c = _makeContainer(resolver: (_, _, _) => null, db: db);
      addTearDown(c.dispose);

      expect(c.read(focusPillProvider).hasValue, isFalse);
    });

    test(
      '2. resolve: camera over seeded region → name=Grebenhain, '
      'percentLabel=26.4%',
      () async {
        final region = _grebenhainRegion();
        // zoom=14 → fallbackLevelsFrom(14)=[9,8,6,4,2]; level 9 null → 8 wins
        final c = _makeContainer(
          resolver: (_, _, level) => level == 8 ? region : null,
          db: db,
        );
        addTearDown(c.dispose);

        await _pushCamera(c);

        final s = c.read(focusPillProvider);
        expect(s.name, 'Grebenhain');
        expect(s.percentLabel, '26.4%');
      },
    );

    test(
      '3. fallback chain: level 9 null, level 8 returns region',
      () async {
        final region = _grebenhainRegion();
        final c = _makeContainer(
          // zoom=14 → fallbackLevelsFrom(14)=[9,8,6,4,2]
          // level 9 → null, level 8 → region
          resolver: (_, _, level) => level == 8 ? region : null,
          db: db,
        );
        addTearDown(c.dispose);

        await _pushCamera(c);

        expect(c.read(focusPillProvider).name, 'Grebenhain');
      },
    );

    test(
      '4. hold-last-value: after first resolve, all-null camera does not '
      'blank the state',
      () async {
        final region = _grebenhainRegion();
        final c = _makeContainer(
          resolver: (lat, _, level) {
            // Return region for Grebenhain area (lat > 50), null for 0,0
            if (lat > 50) return level == 8 ? region : null;
            return null; // all null → outside Germany
          },
          db: db,
        );
        addTearDown(c.dispose);

        // First: push a camera over Grebenhain → resolves to the region
        await _pushCamera(c);
        expect(c.read(focusPillProvider).name, 'Grebenhain');

        // Second: push camera to 0,0 (all levels null) → HOLD last value
        await _pushNoRegionCamera(c);
        expect(
          c.read(focusPillProvider).name,
          'Grebenhain',
          reason: 'Pill must hold last value when area is outside Germany',
        );
      },
    );

    test(
      '5. no cache row → percentLabel is null (region exists, no coverage)',
      () async {
        final region = _grebenhainRegion();
        // DB does NOT have a row for this region (use a fresh empty db)
        final emptyDb = AppDatabase(NativeDatabase.memory());
        addTearDown(emptyDb.close);

        final c = _makeContainer(
          resolver: (_, _, level) => level == 8 ? region : null,
          db: emptyDb,
        );
        addTearDown(c.dispose);

        await _pushCamera(c);

        final s = c.read(focusPillProvider);
        expect(s.name, 'Grebenhain');
        expect(
          s.percentLabel,
          isNull,
          reason: 'No cache row → percentLabel null → widget shows —%',
        );
      },
    );
  });
}
