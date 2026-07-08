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

    test('formats correctly for dataviz (light default) with default de', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.dataviz,
        darkStyle: MapTilerStyle.datavizDark,
        apiKey: key,
      );

      // Plan 04-16-1: default language is 'de' → URL ends with &language=de.
      expect(
        config.styleUrl(MapTilerStyle.dataviz).toString(),
        'https://api.maptiler.com/maps/dataviz/style.json?key=$key&language=de',
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
      expect(url.queryParameters['language'], 'de');
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

  // Plan 04-16-1 (2026-07-08 UX polish): language plumbing.
  group('TileProviderConfig.language', () {
    const key = 'test-key';

    test('styleUrl includes language=de by default', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.dataviz,
        darkStyle: MapTilerStyle.datavizDark,
        apiKey: key,
      );

      final url = config.styleUrl(MapTilerStyle.dataviz);

      expect(url.queryParameters['language'], 'de');
    });

    test('styleUrl includes language=en when config passes "en"', () {
      const config = TileProviderConfig(
        lightStyle: MapTilerStyle.dataviz,
        darkStyle: MapTilerStyle.datavizDark,
        apiKey: key,
        language: 'en',
      );

      final url = config.styleUrl(MapTilerStyle.dataviz);

      expect(url.queryParameters['language'], 'en');
      expect(
        url.toString(),
        'https://api.maptiler.com/maps/dataviz/style.json?key=$key&language=en',
      );
    });

    test('resolveMapLanguage returns the leading 2-letter code when '
        'supported', () {
      expect(resolveMapLanguage('de_DE'), 'de');
      expect(resolveMapLanguage('en-US'), 'en');
      expect(resolveMapLanguage('fr'), 'fr');
      expect(resolveMapLanguage('ZH-Hans'), 'zh');
      // Unsupported → default de.
      expect(resolveMapLanguage('sv_SE'), 'de');
      expect(resolveMapLanguage('pl'), 'de');
      expect(resolveMapLanguage(''), 'de');
    });
  });
}
