import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('assetForBrightness', () {
    test('returns light asset for Brightness.light', () {
      expect(
        assetForBrightness(Brightness.light),
        'assets/map_style_light.json',
      );
    });

    test('returns dark asset for Brightness.dark', () {
      expect(
        assetForBrightness(Brightness.dark),
        'assets/map_style_dark.json',
      );
    });
  });

  group('mapStyleAssetProvider', () {
    test('initial state reflects host-test platform brightness (light)', () {
      // In the test host, PlatformDispatcher.instance.platformBrightness is
      // typically Brightness.light. We verify the provider initialises from
      // that value rather than hard-coding the expected string — this makes
      // the test robust to test-runner brightness differences.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final initial = container.read(mapStyleAssetProvider);
      final expected = assetForBrightness(
        // Use the same source the notifier uses.
        WidgetsFlutterBinding.ensureInitialized()
            .platformDispatcher
            .platformBrightness,
      );
      expect(initial, expected);
    });

    test('updateFromBrightness(dark) sets dark asset', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container
          .read(mapStyleAssetProvider.notifier)
          .updateFromBrightness(Brightness.dark);

      expect(container.read(mapStyleAssetProvider), 'assets/map_style_dark.json');
    });

    test('updateFromBrightness(light) sets light asset', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Force dark first, then switch back to light.
      container
          .read(mapStyleAssetProvider.notifier)
          .updateFromBrightness(Brightness.dark);
      container
          .read(mapStyleAssetProvider.notifier)
          .updateFromBrightness(Brightness.light);

      expect(container.read(mapStyleAssetProvider), 'assets/map_style_light.json');
    });
  });
}
