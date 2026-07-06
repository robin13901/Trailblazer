import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Smoke tests that guard against style-JSON drift.
///
/// Both `map_style_light.json` and `map_style_dark.json` must:
///  - parse as valid JSON with `version: 8`
///  - declare a `trailblazer` vector source
///  - share the same set of layer ids (dark ↔ light differ only in paint)
///  - reference our 4-layer schema — every non-background layer's
///    `source-layer` must be one of the four names 04-07 wrote into
///    `germany-base.pmtiles` (roads / admin_boundaries / water / labels).
///
/// This test files under `test/assets/` rather than `test/features/map/`
/// because it doesn't require a running Flutter binding — it's a pure
/// JSON contract check between the pipeline's tippecanoe output and the
/// app's style JSONs. Keeping it lightweight lets it run without any
/// widget infrastructure.
void main() {
  const kAllowedSourceLayers = <String>{
    'roads',
    'admin_boundaries',
    'water',
    'labels',
  };

  group('map style JSONs', () {
    test('map_style_light.json is a valid MapLibre style JSON', () async {
      final txt = await File('assets/map_style_light.json').readAsString();
      final json = jsonDecode(txt) as Map<String, dynamic>;

      expect(json['version'], 8);
      expect(json['sources'], isA<Map<String, dynamic>>());
      expect(
        (json['sources'] as Map<String, dynamic>).containsKey('trailblazer'),
        isTrue,
        reason: 'Style must declare the `trailblazer` source',
      );

      final layers = json['layers'] as List<dynamic>;
      final layerIds = layers.map((l) => (l as Map)['id'] as String).toSet();
      expect(
        layerIds,
        contains('road-motorway'),
        reason: 'Motorway styling required for 04-07 roads schema',
      );
      expect(layerIds, contains('admin-line-l4'));
      expect(layerIds, contains('water-fill'));
      expect(layerIds, contains('label-place-city'));
    });

    test('map_style_dark.json is a valid MapLibre style JSON', () async {
      final txt = await File('assets/map_style_dark.json').readAsString();
      final json = jsonDecode(txt) as Map<String, dynamic>;

      expect(json['version'], 8);
      expect(json['sources'], isA<Map<String, dynamic>>());
      expect(
        (json['sources'] as Map<String, dynamic>).containsKey('trailblazer'),
        isTrue,
      );
    });

    test('dark shares every layer id with light — only paint differs',
        () async {
      final lightTxt =
          await File('assets/map_style_light.json').readAsString();
      final darkTxt =
          await File('assets/map_style_dark.json').readAsString();
      final lightLayers = (jsonDecode(lightTxt) as Map)['layers'] as List;
      final darkLayers = (jsonDecode(darkTxt) as Map)['layers'] as List;

      final lightIds =
          lightLayers.map((l) => (l as Map)['id'] as String).toList();
      final darkIds =
          darkLayers.map((l) => (l as Map)['id'] as String).toList();

      expect(
        darkIds,
        equals(lightIds),
        reason:
            'Dark and light styles MUST share identical layer id lists '
            '(same order) so the brightness swap does not re-layout '
            'the map. Only paint blocks may differ.',
      );
    });

    test(
      'every non-background layer targets a 4-layer schema source-layer',
      () async {
        for (final path in const <String>[
          'assets/map_style_light.json',
          'assets/map_style_dark.json',
        ]) {
          final json =
              jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
          final layers = json['layers'] as List<dynamic>;
          for (final raw in layers) {
            final l = raw as Map<String, dynamic>;
            final id = l['id'] as String;
            if (l['type'] == 'background') continue;
            final srcLayer = l['source-layer'] as String?;
            expect(
              srcLayer,
              isNotNull,
              reason: '$path layer "$id" is missing source-layer',
            );
            expect(
              kAllowedSourceLayers,
              contains(srcLayer),
              reason:
                  '$path layer "$id" references source-layer "$srcLayer" '
                  'which is NOT in the 4-layer schema '
                  '(roads/admin_boundaries/water/labels)',
            );
            expect(
              l['source'],
              'trailblazer',
              reason: '$path layer "$id" must source from `trailblazer`',
            );
          }
        }
      },
    );
  });
}
