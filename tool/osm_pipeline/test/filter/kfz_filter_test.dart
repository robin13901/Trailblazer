import 'package:osm_pipeline/filter/kfz_filter.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:test/test.dart';

OsmWay _way({required int id, required Map<String, String> tags}) =>
    OsmWay(id: id, tags: tags, nodeRefs: const [1, 2, 3]);

void main() {
  group('isKfzWay — 14 allowlist tags', () {
    const allowlist = <String>[
      'motorway',
      'motorway_link',
      'trunk',
      'trunk_link',
      'primary',
      'primary_link',
      'secondary',
      'secondary_link',
      'tertiary',
      'tertiary_link',
      'unclassified',
      'residential',
      'living_street',
      'road',
    ];
    for (final tag in allowlist) {
      test('accepts highway=$tag', () {
        expect(isKfzWay(_way(id: 1, tags: {'highway': tag})), isTrue);
      });
    }
  });

  group('isKfzWay — rejects', () {
    const rejected = <String>[
      'service', // explicit exclusion per OSM-02 reconciliation
      'footway',
      'cycleway',
      'pedestrian',
      'bridleway',
      'track', // Feldweg territory, not Kfz
      'path',
      'construction',
      'proposed',
      'highway_that_doesnt_exist',
    ];
    for (final tag in rejected) {
      test('rejects highway=$tag', () {
        expect(isKfzWay(_way(id: 1, tags: {'highway': tag})), isFalse);
      });
    }

    test('rejects way with no highway tag', () {
      expect(isKfzWay(_way(id: 1, tags: {})), isFalse);
    });
  });

  group('retainKfzTags', () {
    test('keeps only highway, name, ref, oneway, maxspeed', () {
      final way = _way(
        id: 1,
        tags: {
          'highway': 'primary',
          'name': 'Musterstraße',
          'ref': 'M1',
          'oneway': 'yes',
          'maxspeed': '50',
          'surface': 'asphalt', // NOT retained for Kfz
          'lit': 'yes',
          'name:en': 'Sample Street',
        },
      );
      final kept = retainKfzTags(way);
      expect(
        kept.keys,
        unorderedEquals(['highway', 'name', 'ref', 'oneway', 'maxspeed']),
      );
      expect(kept['highway'], 'primary');
      expect(kept['surface'], isNull);
      expect(kept['name:en'], isNull);
    });

    test('drops missing keys silently', () {
      final way = _way(id: 1, tags: {'highway': 'residential'});
      final kept = retainKfzTags(way);
      expect(kept, {'highway': 'residential'});
    });
  });
}
