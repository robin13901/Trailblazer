import 'package:auto_explore/app.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../helpers/fake_maplibre_platform.dart';

/// Stub notifier that returns [PermissionStatus.granted] without calling
/// the permission_handler platform channel.
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
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    // Fake the MapLibre platform channel so MapWidget doesn't throw
    // MissingPluginException when MapScreen is loaded after onboarding.
    final prev = MapLibrePlatform.createInstance;
    addTearDown(() => MapLibrePlatform.createInstance = prev);
    MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;
  });

  testWidgets('first launch: splash -> onboarding -> map shell', (
    tester,
  ) async {
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

    // Splash resolved into onboarding because prefs are empty.
    expect(find.text('Welcome to Trailblazer'), findsOneWidget);

    // Tap Continue -> permission requested (fake) -> flag set -> navigate
    // to map screen (StatefulShellRoute index 0).
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // MapScreen is active — BottomNavShell is the Dart-only landmark.
    expect(find.byType(BottomNavShell), findsOneWidget);
    expect(find.text('Welcome to Trailblazer'), findsNothing);
  });

  testWidgets('second launch: skips onboarding, lands on map shell', (
    tester,
  ) async {
    // Pre-set the onboarding_done flag to simulate a repeat launch.
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

    expect(find.byType(BottomNavShell), findsOneWidget);
    expect(find.text('Welcome to Trailblazer'), findsNothing);
  });
}
