import 'package:auto_explore/app.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'features/onboarding/fakes/fake_permission_service.dart';
import 'helpers/fake_background_geolocation_facade.dart';
import 'helpers/fake_maplibre_platform.dart';

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

void main() {
  testWidgets('App boots and reaches a stable screen', (tester) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();

    // Fake MapLibre so MapWidget doesn't throw MissingPluginException
    // when the test navigates past onboarding onto the map shell.
    final prev = MapLibrePlatform.createInstance;
    addTearDown(() => MapLibrePlatform.createInstance = prev);
    MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          locationPermissionProvider.overrideWith(
            _FakeLocationPermissionNotifier.new,
          ),
          permissionServiceProvider.overrideWithValue(FakePermissionService()),
          backgroundGeolocationFacadeProvider.overrideWithValue(
            FakeBackgroundGeolocationFacade(),
          ),
        ],
        child: const App(),
      ),
    );
    // Allow splash microtask + async prefs read + navigation to settle.
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // First launch (empty prefs) -> onboarding page 1 (3-page permission ladder).
    expect(find.textContaining('Standort während der Nutzung von Trailblazer'), findsOneWidget);

    // Tap page 1 Continue -> page 2.
    await tester.tap(find.text('Weiter').first);
    await tester.pumpAndSettle();

    // Page 2: Enable background location.
    await tester.tap(find.text('Standort im Hintergrund aktivieren'));
    await tester.pumpAndSettle();

    // Page 3: Continue (iOS) or Enable (Android) — accept whichever is present.
    final continueBtn = find.text('Weiter');
    final enableBtn = find.text('Aktivieren');
    if (continueBtn.evaluate().isNotEmpty) {
      await tester.tap(continueBtn);
    } else {
      await tester.tap(enableBtn);
    }
    await tester.pumpAndSettle();

    // Map shell (StatefulShellRoute) is active — BottomNavShell is visible.
    expect(find.byType(BottomNavShell), findsOneWidget);
    expect(find.textContaining('Standort während der Nutzung von Trailblazer'), findsNothing);
  });
}
