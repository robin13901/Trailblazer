import 'package:osm_pipeline/filter/directionality.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:test/test.dart';

OsmWay _way(Map<String, String> tags, {List<int> refs = const [1, 2, 3]}) =>
    OsmWay(id: 1, tags: tags, nodeRefs: refs);

void main() {
  group('normalizeDirectionality — explicit oneway values', () {
    test('oneway=yes: is_directional=1, order preserved', () {
      final r = normalizeDirectionality(
        _way({'highway': 'primary', 'oneway': 'yes'}),
      );
      expect(r.isDirectional, isTrue);
      expect(r.nodeIds, orderedEquals([1, 2, 3]));
    });

    test('oneway=-1: is_directional=1, order PHYSICALLY REVERSED', () {
      final r = normalizeDirectionality(
        _way({'highway': 'primary', 'oneway': '-1'}),
      );
      expect(r.isDirectional, isTrue);
      expect(r.nodeIds, orderedEquals([3, 2, 1]));
    });

    test('oneway=-1 reversal is stable for a two-node way', () {
      final r = normalizeDirectionality(
        _way({'highway': 'primary', 'oneway': '-1'}, refs: const [7, 8]),
      );
      expect(r.nodeIds, orderedEquals([8, 7]));
    });

    test('oneway=no: is_directional=0, order preserved', () {
      final r = normalizeDirectionality(
        _way({'highway': 'primary', 'oneway': 'no'}),
      );
      expect(r.isDirectional, isFalse);
      expect(r.nodeIds, orderedEquals([1, 2, 3]));
    });
  });

  group('normalizeDirectionality — implicit rule when oneway is absent', () {
    test('missing + highway=motorway → implicit directional', () {
      expect(
        normalizeDirectionality(_way({'highway': 'motorway'})).isDirectional,
        isTrue,
      );
    });

    test('missing + highway=motorway_link → implicit directional', () {
      expect(
        normalizeDirectionality(_way({'highway': 'motorway_link'}))
            .isDirectional,
        isTrue,
      );
    });

    test('missing + highway=trunk_link → implicit directional', () {
      expect(
        normalizeDirectionality(_way({'highway': 'trunk_link'})).isDirectional,
        isTrue,
      );
    });

    test('missing + highway=trunk → NOT implicit (bidirectional)', () {
      // Per OSM wiki: only motorway / motorway_link / trunk_link.
      expect(
        normalizeDirectionality(_way({'highway': 'trunk'})).isDirectional,
        isFalse,
      );
    });

    test('missing + highway=primary → bidirectional', () {
      expect(
        normalizeDirectionality(_way({'highway': 'primary'})).isDirectional,
        isFalse,
      );
    });

    test('missing + highway=residential → bidirectional', () {
      expect(
        normalizeDirectionality(_way({'highway': 'residential'})).isDirectional,
        isFalse,
      );
    });
  });

  group('normalizeDirectionality — node order preserved for non-reversal', () {
    test('order unchanged for oneway=yes on longer way', () {
      final r = normalizeDirectionality(
        _way(
          {'highway': 'motorway', 'oneway': 'yes'},
          refs: const [10, 11, 12, 13, 14, 15],
        ),
      );
      expect(r.nodeIds, orderedEquals([10, 11, 12, 13, 14, 15]));
    });
  });
}
