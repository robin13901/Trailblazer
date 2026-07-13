import 'dart:io';

import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_providers.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_repository.dart';
import 'package:auto_explore/features/onboarding/presentation/onboarding_screen.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../helpers/fake_background_geolocation_facade.dart';
import 'fakes/fake_permission_service.dart';

/// Simple GoRouter for tests — OnboardingScreen at `/onboarding`, a plain
/// home at `/` that the last page navigates to.
GoRouter _makeRouter() => GoRouter(
      initialLocation: '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          builder: (_, _) => const OnboardingScreen(),
        ),
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
      ],
    );

/// Pumps the onboarding flow inside a ProviderScope with injected fakes.
///
/// Returns the `FakePermissionService` so callers can inspect the call log.
/// Pass a `capabilityRepo` to read persisted capability after the flow.
Future<FakePermissionService> pumpOnboarding(
  WidgetTester tester, {
  required FakePermissionService fakeService,
  required TrackingCapabilityRepository capabilityRepo,
  required OnboardingFlagRepository flagRepo,
  FakeBackgroundGeolocationFacade? fakeGeolocation,
}) async {
  final geolocation = fakeGeolocation ?? FakeBackgroundGeolocationFacade();
  final router = _makeRouter();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        permissionServiceProvider.overrideWithValue(fakeService),
        trackingCapabilityRepositoryProvider
            .overrideWithValue(capabilityRepo),
        onboardingFlagRepositoryProvider.overrideWithValue(flagRepo),
        backgroundGeolocationFacadeProvider.overrideWithValue(geolocation),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  return fakeService;
}

void main() {
  late InMemorySharedPreferencesAsync inMemoryPrefs;
  late TrackingCapabilityRepository capabilityRepo;
  late OnboardingFlagRepository flagRepo;

  setUp(() {
    inMemoryPrefs = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = inMemoryPrefs;
    capabilityRepo = TrackingCapabilityRepository(SharedPreferencesAsync());
    flagRepo = OnboardingFlagRepository(SharedPreferencesAsync());
  });

  /// Tap through all 3 onboarding pages.
  Future<void> tapAll(WidgetTester tester) async {
    // Page 1 — whenInUse
    expect(find.text('Weiter'), findsWidgets);
    await tester.tap(find.text('Weiter').first);
    await tester.pumpAndSettle();

    // Page 2 — always
    expect(find.text('Standort im Hintergrund aktivieren'), findsOneWidget);
    await tester.tap(find.text('Standort im Hintergrund aktivieren'));
    await tester.pumpAndSettle();

    // Page 3 — motion/notification
    final primaryLabel = Platform.isIOS ? 'Weiter' : 'Aktivieren';
    expect(find.text(primaryLabel), findsOneWidget);
    await tester.tap(find.text(primaryLabel));
    await tester.pumpAndSettle();
  }

  group('OnboardingScreen ladder', () {
    testWidgets('all-granted path — fullAuto capability + done flag',
        (tester) async {
      final fake = FakePermissionService();
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      await tapAll(tester);

      // Request log should contain the 3 requests in order.
      expect(fake.requestLog[0], 'whenInUse');
      expect(fake.requestLog[1], 'always');
      expect(fake.requestLog[2], Platform.isIOS ? 'sensors' : 'notification');

      expect(await capabilityRepo.load(), TrackingCapability.fullAuto);
      expect(await flagRepo.isDone(), isTrue);
      // Navigated to home.
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('always-denied path — manualOnly + done flag', (tester) async {
      final fake = FakePermissionService(
        alwaysResult: PermissionStatus.denied,
      );
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      await tapAll(tester);

      expect(await capabilityRepo.load(), TrackingCapability.manualOnly);
      expect(await flagRepo.isDone(), isTrue);
    });

    testWidgets('always-permanentlyDenied — manualOnly (covers !isGranted)',
        (tester) async {
      final fake = FakePermissionService(
        alwaysResult: PermissionStatus.permanentlyDenied,
      );
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      await tapAll(tester);

      expect(await capabilityRepo.load(), TrackingCapability.manualOnly);
    });

    testWidgets('always-restricted — manualOnly (covers !isGranted)',
        (tester) async {
      final fake = FakePermissionService(
        alwaysResult: PermissionStatus.restricted,
      );
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      await tapAll(tester);

      expect(await capabilityRepo.load(), TrackingCapability.manualOnly);
    });

    testWidgets(
        'Android: notification denied — manualOnly regardless of always',
        (tester) async {
      // This test only applies on Android — on other host platforms
      // Platform.isAndroid is false and the notification status is
      // never checked (treated as granted). Skip gracefully.
      if (!Platform.isAndroid) return;

      final fake = FakePermissionService(
        notificationResult: PermissionStatus.denied,
      );
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      await tapAll(tester);

      expect(await capabilityRepo.load(), TrackingCapability.manualOnly);
    });

    testWidgets('page 1 copy renders', (tester) async {
      final fake = FakePermissionService();
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      expect(find.textContaining('Standort während der Nutzung'), findsOneWidget);
    });

    testWidgets('page 2 copy renders after page 1', (tester) async {
      final fake = FakePermissionService();
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      await tester.tap(find.text('Weiter').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('Fahrten im Hintergrund aufzeichnen'), findsOneWidget);
    });

    testWidgets('page 3 copy renders after page 2', (tester) async {
      final fake = FakePermissionService();
      await pumpOnboarding(
        tester,
        fakeService: fake,
        capabilityRepo: capabilityRepo,
        flagRepo: flagRepo,
      );

      await tester.tap(find.text('Weiter').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Standort im Hintergrund aktivieren'));
      await tester.pumpAndSettle();

      final expectedTitle =
          Platform.isIOS ? 'Bewegung & Fitness' : 'Benachrichtigungen und Batterie';
      expect(find.textContaining(expectedTitle), findsOneWidget);
    });
  });
}
