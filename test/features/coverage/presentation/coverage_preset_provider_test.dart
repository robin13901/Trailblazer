// Trailblazer Phase 7, Plan 07-05:
// Unit tests for CoveragePresetNotifier / coveragePresetProvider.

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        // Use real AppPrefs backed by in-memory SharedPreferences.
        appPrefsProvider.overrideWith(
          (ref) => AppPrefs(SharedPreferencesAsync()),
        ),
      ],
    );
  }

  test('defaults to amber when nothing is stored', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    final value = await container.read(coveragePresetProvider.future);
    expect(value, CoverageColorPreset.amber);
  });

  test('select(green) persists and updates provider state', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    // Wait for initial load.
    await container.read(coveragePresetProvider.future);

    // Select green.
    await container
        .read(coveragePresetProvider.notifier)
        .select(CoverageColorPreset.green);

    final current = container.read(coveragePresetProvider).value;
    expect(current, CoverageColorPreset.green);
  });

  test('re-read from AppPrefs after select reflects persisted value', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(coveragePresetProvider.future);
    await container
        .read(coveragePresetProvider.notifier)
        .select(CoverageColorPreset.green);

    // Read directly from AppPrefs — simulates app restart.
    final prefs = container.read(appPrefsProvider);
    final stored = await prefs.getCoveragePreset();
    expect(stored, CoverageColorPreset.green);
  });

  test('coveragePresetValueProvider returns amber while loading', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    // Before the async build completes, valueProvider should return amber.
    final value = container.read(coveragePresetValueProvider);
    expect(value, CoverageColorPreset.amber);
  });

  test('coveragePresetValueProvider reflects selected preset after load',
      () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(coveragePresetProvider.future);
    await container
        .read(coveragePresetProvider.notifier)
        .select(CoverageColorPreset.blue);

    final value = container.read(coveragePresetValueProvider);
    expect(value, CoverageColorPreset.blue);
  });
}
