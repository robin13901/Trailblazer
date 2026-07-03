import 'package:auto_explore/features/onboarding/data/onboarding_flag_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('isDone() returns false by default', () async {
    final repo = OnboardingFlagRepository(SharedPreferencesAsync());
    expect(await repo.isDone(), isFalse);
  });

  test('markDone() then isDone() returns true', () async {
    final repo = OnboardingFlagRepository(SharedPreferencesAsync());
    await repo.markDone();
    expect(await repo.isDone(), isTrue);
  });

  test('reset() clears the flag', () async {
    final repo = OnboardingFlagRepository(SharedPreferencesAsync());
    await repo.markDone();
    await repo.reset();
    expect(await repo.isDone(), isFalse);
  });
}
