import 'dart:ui';

import 'package:auto_explore/features/map/data/tile_provider_config.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mapStyleUrlProvider', () {
    test('returns key-less MapTiler URL when config has no key', () {
      // Default tileProviderConfigProvider (from map_style_provider.dart) has
      // an empty API key — the URL is intentionally unusable but well-formed
      // so MapLibre's style loader doesn't blow up on empty strings.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final url = container.read(mapStyleUrlProvider);
      expect(url, startsWith('https://api.maptiler.com/maps/'));
      // Plan 04-16-1: default language=de threaded into the empty-key path.
      expect(url, endsWith('/style.json?key=&language=de'));
    });

    test('respects overridden TileProviderConfig apiKey', () {
      final container = ProviderContainer(
        overrides: [
          tileProviderConfigProvider.overrideWithValue(
            const TileProviderConfig(
              lightStyle: MapTilerStyle.dataviz,
              darkStyle: MapTilerStyle.datavizDark,
              apiKey: 'test-key',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final url = container.read(mapStyleUrlProvider);
      expect(url, contains('key=test-key'));
      expect(url, contains('/style.json'));
    });

    test('updateFromBrightness(dark) switches to dark style URL', () {
      final container = ProviderContainer(
        overrides: [
          tileProviderConfigProvider.overrideWithValue(
            const TileProviderConfig(
              lightStyle: MapTilerStyle.dataviz,
              darkStyle: MapTilerStyle.datavizDark,
              apiKey: 'test-key',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(mapStyleUrlProvider.notifier)
          .updateFromBrightness(Brightness.dark);

      expect(
        container.read(mapStyleUrlProvider),
        contains('/maps/dataviz-dark/'),
      );
    });

    test('updateFromBrightness(light) switches back to light style URL', () {
      final container = ProviderContainer(
        overrides: [
          tileProviderConfigProvider.overrideWithValue(
            const TileProviderConfig(
              lightStyle: MapTilerStyle.dataviz,
              darkStyle: MapTilerStyle.datavizDark,
              apiKey: 'test-key',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Force dark first, then flip back to light.
      container
          .read(mapStyleUrlProvider.notifier)
          .updateFromBrightness(Brightness.dark);
      container
          .read(mapStyleUrlProvider.notifier)
          .updateFromBrightness(Brightness.light);

      expect(
        container.read(mapStyleUrlProvider),
        contains('/maps/dataviz/'),
      );
    });
  });
}
