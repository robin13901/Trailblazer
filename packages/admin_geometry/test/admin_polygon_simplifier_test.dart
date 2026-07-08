import 'dart:convert';
import 'dart:math' as math;

import 'package:admin_geometry/admin_geometry.dart';
import 'package:test/test.dart';

void main() {
  group('AdminPolygonSimplifier', () {
    const sut = AdminPolygonSimplifier();

    test('simplify preserves closed rings for a rectangular relation', () {
      final rawJson = jsonEncode({
        'elements': [
          _relation(
            id: 100,
            level: 2,
            name: 'BoxLand',
            members: [
              _way('outer', [
                [0.0, 0.0],
                [0.0, 10.0],
                [10.0, 10.0],
                [10.0, 0.0],
                [0.0, 0.0],
              ]),
            ],
          ),
        ],
      });

      final fc = sut.assembleAndSimplify(rawJson);
      final features = fc['features']! as List;
      expect(features, hasLength(1));
      final geom = (features.first as Map)['geometry'] as Map;
      final coords = geom['coordinates'] as List;
      expect(coords, hasLength(1)); // one polygon
      final rings = coords.first as List;
      expect(rings, hasLength(1)); // one outer, no holes
      final ring = rings.first as List;
      // Ring closed (last == first).
      expect(ring.first, ring.last);
      expect(ring.length, greaterThanOrEqualTo(4));
    });

    test('simplify preserves multipolygon structure with a hole', () {
      final rawJson = jsonEncode({
        'elements': [
          _relation(
            id: 101,
            level: 4,
            name: 'DonutLand',
            members: [
              _way('outer', [
                [0.0, 0.0],
                [0.0, 10.0],
                [10.0, 10.0],
                [10.0, 0.0],
                [0.0, 0.0],
              ]),
              _way('inner', [
                [3.0, 3.0],
                [3.0, 7.0],
                [7.0, 7.0],
                [7.0, 3.0],
                [3.0, 3.0],
              ]),
            ],
          ),
        ],
      });

      final fc = sut.assembleAndSimplify(rawJson);
      final features = fc['features']! as List;
      expect(features, hasLength(1));
      final coords =
          ((features.first as Map)['geometry'] as Map)['coordinates'] as List;
      final rings = coords.first as List;
      expect(rings, hasLength(2)); // outer + inner
    });

    test('tighter tolerance keeps more points', () {
      // Circle approximated with 24 vertices, radius 5 units.
      final ring = <List<double>>[
        for (var i = 0; i < 24; i++)
          [
            5.0 + 5.0 * math.cos(i * 2 * math.pi / 24),
            5.0 + 5.0 * math.sin(i * 2 * math.pi / 24),
          ],
        [10, 5],
      ];

      final rawJson = jsonEncode({
        'elements': [
          _relation(
            id: 102,
            level: 8,
            name: 'CircleLand',
            members: [
              _wayLonLat('outer', ring),
            ],
          ),
        ],
      });

      const looser = AdminPolygonSimplifier(
        tolerancesPerLevel: {8: 100000},
      );
      const tighter = AdminPolygonSimplifier(
        tolerancesPerLevel: {8: 100},
      );

      final looseFc = looser.assembleAndSimplify(rawJson);
      final tightFc = tighter.assembleAndSimplify(rawJson);

      final looseRing = ((((looseFc['features']! as List).first as Map)
                  ['geometry']!
              as Map)['coordinates']! as List)
          .first as List;
      final tightRing = ((((tightFc['features']! as List).first as Map)
                  ['geometry']!
              as Map)['coordinates']! as List)
          .first as List;

      final looseCount = (looseRing.first as List).length;
      final tightCount = (tightRing.first as List).length;
      expect(tightCount, greaterThan(looseCount));
    });

    test('name and name:de preserved on feature properties', () {
      final rawJson = jsonEncode({
        'elements': [
          _relation(
            id: 103,
            level: 4,
            name: 'Bayern',
            extraTags: const {'name:de': 'Bayern'},
            members: [
              _way('outer', [
                [0.0, 0.0],
                [0.0, 1.0],
                [1.0, 1.0],
                [1.0, 0.0],
                [0.0, 0.0],
              ]),
            ],
          ),
        ],
      });

      final fc = sut.assembleAndSimplify(rawJson);
      final props =
          ((fc['features']! as List).first as Map)['properties']! as Map;
      expect(props['name'], 'Bayern');
      expect(props['name:de'], 'Bayern');
      expect(props['osm_id'], 103);
      expect(props['admin_level'], 4);
    });

    test('relations without a name are rejected', () {
      final rawJson = jsonEncode({
        'elements': [
          _relation(
            id: 999,
            level: 4,
            name: '',
            members: [
              _way('outer', [
                [0.0, 0.0],
                [0.0, 1.0],
                [1.0, 1.0],
                [1.0, 0.0],
                [0.0, 0.0],
              ]),
            ],
          ),
        ],
      });

      final fc = sut.assembleAndSimplify(rawJson);
      expect(fc['features'], isEmpty);
    });
  });
}

// ---------- fixture helpers ----------

Map<String, dynamic> _relation({
  required int id,
  required int level,
  required String name,
  required List<Map<String, dynamic>> members,
  Map<String, String>? extraTags,
}) {
  final tags = <String, String>{
    if (name.isNotEmpty) 'name': name,
    'admin_level': '$level',
    'type': 'boundary',
    'boundary': 'administrative',
    ...?extraTags,
  };
  return {
    'type': 'relation',
    'id': id,
    'tags': tags,
    'members': members,
  };
}

// [lat, lon] pairs.
Map<String, dynamic> _way(String role, List<List<double>> latLonPairs) {
  return {
    'type': 'way',
    'role': role,
    'geometry': [
      for (final p in latLonPairs) {'lat': p[0], 'lon': p[1]},
    ],
  };
}

// [lon, lat] pairs (test-side builders that construct points geometrically).
Map<String, dynamic> _wayLonLat(String role, List<List<double>> lonLatPairs) {
  return {
    'type': 'way',
    'role': role,
    'geometry': [
      for (final p in lonLatPairs) {'lat': p[1], 'lon': p[0]},
    ],
  };
}
