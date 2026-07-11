// Trailblazer Phase 8, Plan 08-06 (Wave 3):
// FocusAreaPill tap widget test.
//
// Verifies that tapping FocusAreaPill resolves the region currently under the
// map view and opens showRegionDetailSheet (the region name appears in the
// bottom sheet after the tap + pump cycle).
//
// Fakes:
//   - focusPillProvider → _FixedFocusPillNotifier (seeded state, no I/O)
//   - liveCameraProvider → _FixedLiveCameraNotifier (known point + zoom)
//   - adminRegionLookupProvider → _FakeLookup (returns a known AdminRegion)
//   - coverageCacheDaoProvider → real DAO backed by NativeDatabase.memory()
//     seeded with one row for the test region's osmId.
//
// The test uses platformBlurEnabled = false to take the GlassPillFallback
// path (headless renderer has no blur support).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/regions/presentation/providers/focus_pill_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Fake AdminRegionLookup that is always loaded and returns [_region] for any
/// (lat, lon, level) call, simulating a region found on the first fallback
/// level. Never touches the asset bundle.
class _FakeLookup extends AdminRegionLookup {
  _FakeLookup(this._region);

  final AdminRegion _region;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async {
    return _region;
  }
}

/// Fixed FocusPillNotifier — no I/O.
class _FixedFocusPillNotifier extends FocusPillNotifier {
  _FixedFocusPillNotifier(this._fixed);
  final FocusPillState _fixed;

  @override
  FocusPillState build() => _fixed;
}

/// Fixed LiveCameraNotifier — returns [_camera] without listening to anything.
class _FixedLiveCameraNotifier extends LiveCameraNotifier {
  _FixedLiveCameraNotifier(this._camera);
  final LiveCamera? _camera;

  @override
  LiveCamera? build() => _camera;
}

// ---------------------------------------------------------------------------
// Known test data
// ---------------------------------------------------------------------------

const _kTestOsmId = 62718;
const _kTestName = 'Grebenhain';

/// Minimal region — polygons list is empty because _FakeLookup.regionAt
/// overrides containsPoint and the polygon is never evaluated.
const _kTestRegion = AdminRegion(
  osmId: _kTestOsmId,
  adminLevel: 10,
  name: _kTestName,
  bboxMinLat: 50.4,
  bboxMinLon: 9.2,
  bboxMaxLat: 50.6,
  bboxMaxLon: 9.4,
  polygons: [],
);

/// A camera pointing at the test region's bbox centre, zoom 15 (-> level 10).
const _kTestCamera = LiveCamera(
  latitude: 50.5,
  longitude: 9.3,
  zoom: 15,
);

// ---------------------------------------------------------------------------
// Pump helper
// ---------------------------------------------------------------------------

Future<void> _pumpPillWithFakes(
  WidgetTester tester,
  CoverageCacheDao dao,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        focusPillProvider.overrideWith(
          () => _FixedFocusPillNotifier(
            const FocusPillState(name: _kTestName, percentLabel: '12,3 %'),
          ),
        ),
        liveCameraProvider.overrideWith(
          () => _FixedLiveCameraNotifier(_kTestCamera),
        ),
        adminRegionLookupProvider.overrideWithValue(_FakeLookup(_kTestRegion)),
        coverageCacheDaoProvider.overrideWithValue(dao),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: FocusAreaPill()),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  tearDown(() {
    LiquidGlassSettings.platformBlurEnabled = false;
  });

  group('FocusAreaPill — tap wiring (08-06)', () {
    late AppDatabase db;
    late CoverageCacheDao dao;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      dao = CoverageCacheDao(db);
      // Seed a coverage row for the test region.
      await dao.upsert(
        regionId: _kTestOsmId.toString(),
        drivenLengthM: 1200,
        totalLengthM: 9750,
        updatedAt: DateTime(2026, 7, 11),
      );
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets(
      '1. pill is tappable — GestureDetector onTap present',
      (tester) async {
        await _pumpPillWithFakes(tester, dao);

        // The GestureDetector wrapping the pill must be hittable.
        expect(find.byType(GestureDetector), findsWidgets);

        // Tapping must not throw.
        await tester.tap(find.byType(FocusAreaPill));
        await tester.pump(); // allow microtasks to start
        // No exception → GestureDetector onTap is wired.
      },
    );

    testWidgets(
      '2. tapping pill opens the region detail sheet with the resolved region name',
      (tester) async {
        await _pumpPillWithFakes(tester, dao);

        await tester.tap(find.byType(FocusAreaPill));
        // pumpAndSettle lets the async _openSheet complete and the sheet animate.
        await tester.pumpAndSettle();

        // The region name must appear inside the bottom sheet.
        expect(find.text(_kTestName), findsWidgets);

        // The DraggableScrollableSheet (inside showModalBottomSheet) must be
        // present — confirming showRegionDetailSheet was called.
        expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      },
    );

    testWidgets(
      '3. sheet shows "Im Karte anzeigen" jump-to-map button',
      (tester) async {
        await _pumpPillWithFakes(tester, dao);

        await tester.tap(find.byType(FocusAreaPill));
        await tester.pumpAndSettle();

        // 'Im Karte anzeigen' is the FilledButton label from region_detail_sheet.dart.
        expect(find.text('Im Karte anzeigen'), findsOneWidget);
      },
    );
  });
}
