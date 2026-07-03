import 'package:auto_explore/app.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../helpers/fake_maplibre_platform.dart';

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

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationPermissionProvider.overrideWith(
          _FakeLocationPermissionNotifier.new,
        ),
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
        // Onboarding and Trips placeholder text are NOT present.
        expect(find.text('Welcome to Trailblazer'), findsNothing);
        expect(find.text('Trips inbox comes in Phase 6.'), findsNothing);
      },
    );

    testWidgets('tapping Trips tab shows TripsScreen and hides map chrome', (
      tester,
    ) async {
      await pumpAppAtMapShell(tester);

      // Tap the Trips tab inside the bottom pill.
      await tester.tap(find.text('Trips'));
      await tester.pumpAndSettle();

      // TripsScreen placeholder text is visible.
      expect(find.text('Trips inbox comes in Phase 6.'), findsOneWidget);
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
      // TripsScreen text is gone.
      expect(find.text('Trips inbox comes in Phase 6.'), findsNothing);
    });

    testWidgets('tapping Regions tab shows RegionsScreen placeholder', (
      tester,
    ) async {
      await pumpAppAtMapShell(tester);

      await tester.tap(find.text('Regions'));
      await tester.pumpAndSettle();

      expect(find.text('Regions browser comes in Phase 8.'), findsOneWidget);
      expect(find.byType(FocusAreaPill), findsNothing);
    });

    testWidgets('tapping settings button navigates to /settings', (
      tester,
    ) async {
      await pumpAppAtMapShell(tester);

      // Settings button is visible on Map tab.
      // The button's Semantics label is 'Settings'.
      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.pumpAndSettle();

      // SettingsScreen placeholder text is visible.
      expect(find.text('Settings comes in Phase 10.'), findsOneWidget);
    });
  });
}
