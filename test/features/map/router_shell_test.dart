import 'package:auto_explore/app.dart';
import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/features/admin/data/admin_bundle_refresher.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/map/data/tile_provider_config.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:auto_explore/features/settings/data/backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/file_platform_provider.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../helpers/fake_maplibre_platform.dart';
import '../onboarding/fakes/fake_permission_service.dart';
import '../settings/fakes/fake_backup_service.dart';
import '../settings/fakes/fake_file_platform.dart';

/// Stub notifier that returns [PermissionStatus.granted] without hitting the
/// permission_handler platform channel.
class _FakeLocationPermissionNotifier extends AsyncNotifier<PermissionStatus>
    implements LocationPermissionNotifier {
  @override
  Future<PermissionStatus> build() async => PermissionStatus.granted;

  @override
  Future<PermissionStatus> requestOnce() async => PermissionStatus.granted;

  @override
  Future<void> refresh() async {}
}

/// Minimal [AdminBundleRefresher] fake — never hits Overpass.
class _FakeAdminBundleRefresher implements AdminBundleRefresher {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;

  @override
  Future<void> refreshFromOverpass() async {}
}

/// Pumps the full [App] with onboarding already complete and all platform
/// channels faked, then settles past the splash screen.
///
/// Returns after the router has settled on the map shell (`/`).
Future<void> pumpAppAtMapShell(WidgetTester tester) async {
  // Pre-set the onboarding_done flag so splash navigates directly to `/`.
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final repo = OnboardingFlagRepository(SharedPreferencesAsync());
  await repo.markDone();

  // In-memory DB so SettingsScreen (and its child sections) can render
  // without hitting the drift_flutter path_provider channel.
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationPermissionProvider.overrideWith(
          _FakeLocationPermissionNotifier.new,
        ),
        // Fixture MapTiler config with a non-empty key so mapStyleUrlProvider
        // returns a well-formed URL (no debug assertion trip).
        tileProviderConfigProvider.overrideWithValue(
          const TileProviderConfig(
            lightStyle: MapTilerStyle.dataviz,
            darkStyle: MapTilerStyle.datavizDark,
            apiKey: 'test-key',
          ),
        ),
        // Trips tab (06-05) mounts the real TripsScreen, whose Inbox/History
        // tabs watch Drift-backed streams + compute()-backed reverse-geocoding.
        // Override the three inbox streams with empty/zero so the tab settles
        // instantly to its empty state instead of hanging pumpAndSettle on a
        // never-completing DB/isolate future.
        inboxTripsProvider.overrideWith(
          (ref) => Stream.value(const <TripListItem>[]),
        ),
        historyTripsProvider.overrideWith(
          (ref) => Stream.value(const <TripListItem>[]),
        ),
        inFlightCountProvider.overrideWith((ref) => Stream.value(0)),
        // RegionsScreen (08-05) mounts regionBrowserProvider which loads
        // AdminRegionLookup (asset bundle) — override so the tab settles
        // instantly to the empty state instead of hanging pumpAndSettle on the
        // asset-bundle load (12 MB, not available in headless tests).
        regionBrowserProvider.overrideWith(
          (ref) async => const <RegionCoverage>[],
        ),
        // SettingsScreen (09-07) reads appDatabaseProvider (via
        // tripsRepositoryProvider in RawGpsRetentionSection) — override with
        // an in-memory DB so the screen can render without a real Drift file.
        appDatabaseProvider.overrideWithValue(db),
        // tripsUnionBoundsProvider is a StreamProvider wrapping a Drift watch
        // query. With an in-memory DB now wired, the stream successfully opens
        // and Drift schedules a cleanup timer on dispose, which the test
        // harness treats as a pending-timer failure. Override with an empty
        // stream so no Drift stream subscription is ever created here.
        tripsUnionBoundsProvider.overrideWith(
          (ref) => const Stream.empty(),
        ),
        // SettingsScreen sections that hit platform channels:
        backupServiceProvider.overrideWithValue(FakeBackupService()),
        filePlatformProvider.overrideWithValue(FakeFilePlatform()),
        permissionServiceProvider.overrideWithValue(FakePermissionService()),
        // DataManagementSection calls adminBundleRefresherProvider — avoid
        // the real Overpass HTTP client + path_provider channels.
        adminBundleRefresherProvider
            .overrideWithValue(_FakeAdminBundleRefresher()),
      ],
      child: const App(),
    ),
  );
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final prev = MapLibrePlatform.createInstance;
    addTearDown(() => MapLibrePlatform.createInstance = prev);
    MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;
  });

  group('Router shell — StatefulShellRoute tab navigation (02-06)', () {
    testWidgets(
      'map shell lands on Map tab: FocusAreaPill + BottomNavShell visible',
      (tester) async {
        await pumpAppAtMapShell(tester);

        // Map tab active: chrome is visible.
        expect(find.byType(FocusAreaPill), findsOneWidget);
        expect(find.byType(BottomNavShell), findsOneWidget);
        // Onboarding text + the Inbox empty-state are NOT present on the map.
        expect(find.text('Welcome to Trailblazer'), findsNothing);
        expect(find.text('No trips waiting'), findsNothing);
      },
    );

    testWidgets('tapping Trips tab shows TripsScreen and hides map chrome', (
      tester,
    ) async {
      await pumpAppAtMapShell(tester);

      // Tap the Trips tab inside the bottom pill.
      await tester.tap(find.text('Trips'));
      await tester.pumpAndSettle();

      // Real TripsScreen (06-05) is visible: both Inbox/History sub-tab
      // labels render regardless of which tab lands active (streams are
      // overridden to empty above, so this settles instantly).
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      // Bottom nav pill is still visible (always rendered).
      expect(find.byType(BottomNavShell), findsOneWidget);
      // Chrome is hidden on non-map tabs.
      expect(find.byType(FocusAreaPill), findsNothing);
    });

    testWidgets('tapping Map tab returns chrome + hides TripsScreen', (
      tester,
    ) async {
      await pumpAppAtMapShell(tester);

      // Navigate to Trips, then back to Map.
      await tester.tap(find.text('Trips'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Map'));
      await tester.pumpAndSettle();

      // Map chrome is visible again.
      expect(find.byType(FocusAreaPill), findsOneWidget);
      // TripsScreen empty-state is gone.
      expect(find.text('No trips waiting'), findsNothing);
    });

    testWidgets('tapping Regions tab shows RegionsScreen placeholder', (
      tester,
    ) async {
      await pumpAppAtMapShell(tester);

      await tester.tap(find.text('Regions'));
      await tester.pumpAndSettle();

      // RegionsScreen (08-05) replaced the stub — shows the empty-state
      // message when no regions have been driven yet.
      expect(
        find.text('Noch keine befahrenen Regionen.\nFahre eine Strecke, um Regionen zu sehen.'),
        findsOneWidget,
      );
      expect(find.byType(FocusAreaPill), findsNothing);
    });

    testWidgets('tapping settings button navigates to /settings', (
      tester,
    ) async {
      // Expand the surface so the SettingsScreen ListView mounts all sections
      // eagerly — the Phase 9 screen has 5 sections; 'ABOUT' is the 5th and
      // is lazy-off-viewport in the default 800×600 test surface.
      await tester.binding.setSurfaceSize(const Size(800, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(const Size(800, 600)));

      await pumpAppAtMapShell(tester);

      // Settings button is visible on Map tab.
      // The button's Semantics label is 'Settings'.
      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.pumpAndSettle();

      // Assert we landed on the Settings screen — the About section header
      // ('ABOUT') is a stable landmark surfaced in Phase 2 for map-attribution
      // credits (Protomaps / OSM). Content beneath will grow in Phase 10.
      expect(find.text('ABOUT'), findsOneWidget);
    });
  });
}
