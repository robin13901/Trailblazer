import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_repository.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
