import 'package:auto_explore/features/map/data/tile_provider_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MapTilerStyleId.id', () {
    test('maps every enum variant to the exact spike-verified string', () {
      // Values verified against a free-tier MapTiler account in
      // .planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md.
      expect(MapTilerStyle.dataviz.id, 'dataviz');
      expect(MapTilerStyle.datavizDark.id, 'dataviz-dark');
      expect(MapTilerStyle.streetsV2.id, 'streets-v2');
      expect(MapTilerStyle.streetsV2Dark.id, 'streets-v2-dark');
    });
  });

  group('TileProviderConfig.styleUrl', () {
    const key = 'test-key-abc123';

    test('formats correctly for dataviz (light default)', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.dataviz,
        darkStyle: MapTilerStyle.datavizDark,
        apiKey: key,
      );

      expect(
        config.styleUrl(MapTilerStyle.dataviz).toString(),
        'https://api.maptiler.com/maps/dataviz/style.json?key=$key',
      );
    });

    test('formats correctly for streetsV2Dark (fallback dark)', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.streetsV2,
        darkStyle: MapTilerStyle.streetsV2Dark,
        apiKey: key,
      );

      final url = config.styleUrl(MapTilerStyle.streetsV2Dark);

      expect(url.host, 'api.maptiler.com');
      expect(url.path, '/maps/streets-v2-dark/style.json');
      expect(url.queryParameters['key'], key);
    });
  });

  group('TileProviderConfig.hasKey', () {
    test('is false when apiKey is empty', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.dataviz,
        darkStyle: MapTilerStyle.datavizDark,
        apiKey: '',
      );

      expect(config.hasKey, isFalse);
    });

    test('is true when apiKey is non-empty', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.dataviz,
        darkStyle: MapTilerStyle.datavizDark,
        apiKey: 'anything',
      );

      expect(config.hasKey, isTrue);
    });
  });

  group('TileProviderConfig.styleUrl assertion guard', () {
    test('asserts on empty apiKey in debug builds', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.dataviz,
        darkStyle: MapTilerStyle.datavizDark,
        apiKey: '',
      );

      // `flutter test` runs in debug mode by default — `assert` is live.
      // If this test regresses in release mode, remove the guard; the
      // assertion is intentionally debug-only.
      expect(
        () => config.styleUrl(MapTilerStyle.dataviz),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
