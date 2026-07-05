import 'package:osm_pipeline/filter/feldweg_filter.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:test/test.dart';

OsmWay _way(Map<String, String> tags) =>
    OsmWay(id: 1, tags: tags, nodeRefs: const [1, 2]);

void main() {
  group('feldwegTagsOrNull — track', () {
    test('highway=track alone is accepted', () {
      final result = feldwegTagsOrNull(_way({'highway': 'track'}));
      expect(result, isNotNull);
      expect(result!['highway'], 'track');
    });

    test('highway=track retains name + surface when present', () {
      final result = feldwegTagsOrNull(
        _way({
          'highway': 'track',
          'name': 'Alter Wirtschaftsweg',
          'surface': 'gravel',
          // motor_vehicle is NOT retained on the track branch.
          'motor_vehicle': 'yes',
        }),
      );
      expect(result, isNotNull);
      expect(result!.keys, unorderedEquals(['highway', 'name', 'surface']));
      expect(result['motor_vehicle'], isNull);
    });
  });

  group('feldwegTagsOrNull — path', () {
    test('highway=path alone is rejected', () {
      expect(feldwegTagsOrNull(_way({'highway': 'path'})), isNull);
    });

    test('highway=path + motor_vehicle=yes is accepted', () {
      final result =
          feldwegTagsOrNull(_way({'highway': 'path', 'motor_vehicle': 'yes'}));
      expect(result, isNotNull);
      expect(result!['motor_vehicle'], 'yes');
    });

    test('highway=path + motor_vehicle=permissive is accepted', () {
      final result = feldwegTagsOrNull(
        _way({'highway': 'path', 'motor_vehicle': 'permissive'}),
      );
      expect(result, isNotNull);
      expect(result!['motor_vehicle'], 'permissive');
    });

    test('highway=path + motor_vehicle=no is rejected', () {
      expect(
        feldwegTagsOrNull(_way({'highway': 'path', 'motor_vehicle': 'no'})),
        isNull,
      );
    });

    test('highway=path + motor_vehicle=private is rejected', () {
      expect(
        feldwegTagsOrNull(
          _way({'highway': 'path', 'motor_vehicle': 'private'}),
        ),
        isNull,
      );
    });
  });

  group('feldwegTagsOrNull — service (side-door)', () {
    test('highway=service + service=driveway is accepted', () {
      final result = feldwegTagsOrNull(
        _way({'highway': 'service', 'service': 'driveway'}),
      );
      expect(result, isNotNull);
      expect(result!['service'], 'driveway');
    });

    test('highway=service + service=alley is accepted', () {
      final result = feldwegTagsOrNull(
        _way({'highway': 'service', 'service': 'alley'}),
      );
      expect(result, isNotNull);
      expect(result!['service'], 'alley');
    });

    test('highway=service + service=parking_aisle is rejected', () {
      expect(
        feldwegTagsOrNull(
          _way({'highway': 'service', 'service': 'parking_aisle'}),
        ),
        isNull,
      );
    });

    test('highway=service alone (no service subtag) is rejected', () {
      expect(feldwegTagsOrNull(_way({'highway': 'service'})), isNull);
    });
  });

  group('feldwegTagsOrNull — non-drivable rejections', () {
    for (final hw in const ['footway', 'cycleway', 'pedestrian', 'bridleway']) {
      test('highway=$hw is rejected outright', () {
        expect(feldwegTagsOrNull(_way({'highway': hw})), isNull);
      });
    }

    test('missing highway tag is rejected', () {
      expect(feldwegTagsOrNull(_way(const <String, String>{})), isNull);
    });

    test('unrecognised highway value is rejected', () {
      expect(
        feldwegTagsOrNull(_way({'highway': 'some_weird_value'})),
        isNull,
      );
    });
  });
}
