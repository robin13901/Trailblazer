import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('prefsKey constant is tracking_capability', () {
    expect(TrackingCapabilityRepository.prefsKey, 'tracking_capability');
  });

  test('load() on empty prefs returns fullAuto', () async {
    final repo = TrackingCapabilityRepository(SharedPreferencesAsync());
    expect(await repo.load(), TrackingCapability.fullAuto);
  });

  test('save(manualOnly) then load() returns manualOnly', () async {
    final repo = TrackingCapabilityRepository(SharedPreferencesAsync());
    await repo.save(TrackingCapability.manualOnly);
    expect(await repo.load(), TrackingCapability.manualOnly);
  });

  test('save(fullAuto) then load() returns fullAuto', () async {
    final repo = TrackingCapabilityRepository(SharedPreferencesAsync());
    await repo.save(TrackingCapability.fullAuto);
    expect(await repo.load(), TrackingCapability.fullAuto);
  });

  group('resolveCapability (Plan 03-1-02 H5)', () {
    test(
        'Android + always.granted + notification.granted + '
        'ignoreBatteryOptimizations.granted → fullAuto', () {
      final cap = TrackingCapabilityRepository.resolveCapability(
        always: PermissionStatus.granted,
        notification: PermissionStatus.granted,
        ignoreBatteryOptimizations: PermissionStatus.granted,
        isAndroidOverride: true,
      );
      expect(cap, TrackingCapability.fullAuto);
    });

    test(
        'Android + always.granted + notification.granted + '
        'ignoreBatteryOptimizations.denied → manualOnly (H5 gap closed)', () {
      final cap = TrackingCapabilityRepository.resolveCapability(
        always: PermissionStatus.granted,
        notification: PermissionStatus.granted,
        ignoreBatteryOptimizations: PermissionStatus.denied,
        isAndroidOverride: true,
      );
      expect(cap, TrackingCapability.manualOnly,
          reason: 'Samsung dismiss of Adaptive-Battery must degrade capability');
    });

    test(
        'Android + always.granted + notification.granted + '
        'ignoreBatteryOptimizations.permanentlyDenied → manualOnly', () {
      final cap = TrackingCapabilityRepository.resolveCapability(
        always: PermissionStatus.granted,
        notification: PermissionStatus.granted,
        ignoreBatteryOptimizations: PermissionStatus.permanentlyDenied,
        isAndroidOverride: true,
      );
      expect(cap, TrackingCapability.manualOnly);
    });

    test(
        'iOS + always.granted + notification.granted (via granted stub) '
        '→ fullAuto (battery-opt argument ignored on iOS)', () {
      final cap = TrackingCapabilityRepository.resolveCapability(
        always: PermissionStatus.granted,
        notification: PermissionStatus.granted,
        // On iOS, PermissionService.statusIgnoreBatteryOptimizations returns
        // granted unconditionally. Even if a rogue caller passed .denied we
        // would still get fullAuto because the iOS branch skips the check.
        ignoreBatteryOptimizations: PermissionStatus.denied,
        isAndroidOverride: false,
      );
      expect(cap, TrackingCapability.fullAuto);
    });

    test(
        'Android + always.denied + all others granted → manualOnly '
        '(classic Plan 03-05 path still works)', () {
      final cap = TrackingCapabilityRepository.resolveCapability(
        always: PermissionStatus.denied,
        notification: PermissionStatus.granted,
        ignoreBatteryOptimizations: PermissionStatus.granted,
        isAndroidOverride: true,
      );
      expect(cap, TrackingCapability.manualOnly);
    });

    test(
        'Android + always.granted + notification.denied + '
        'ignoreBatteryOptimizations.granted → manualOnly', () {
      final cap = TrackingCapabilityRepository.resolveCapability(
        always: PermissionStatus.granted,
        notification: PermissionStatus.denied,
        ignoreBatteryOptimizations: PermissionStatus.granted,
        isAndroidOverride: true,
      );
      expect(cap, TrackingCapability.manualOnly);
    });
  });
}
