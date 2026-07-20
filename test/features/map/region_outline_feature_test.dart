// Trailblazer region-outline overlay:
// Unit tests for buildRegionOutlineFeature — the pure GeoJSON (Multi)Polygon
// builder that turns an AdminRegion's polygons into a MapLibre-ready feature.

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/map/presentation/providers/region_outline_applier.dart';
import 'package:flutter_test/flutter_test.dart';

/// A closed square ring (5 points, first == last) in [lat, lon] order.
List<List<double>> _square({
  required double minLat,
  required double minLon,
  required double maxLat,
  required double maxLon,
}) =>
    [
      [minLat, minLon],
      [minLat, maxLon],
      [maxLat, maxLon],
      [maxLat, minLon],
      [minLat, minLon],
    ];

AdminRegion _region({
  required List<List<List<List<double>>>> polygons,
  int osmId = 111,
  int level = 8,
}) =>
    AdminRegion(
      osmId: osmId,
      adminLevel: level,
      name: 'Test',
      bboxMinLat: 0,
      bboxMinLon: 0,
      bboxMaxLat: 1,
      bboxMaxLon: 1,
      polygons: polygons,
    );

void main() {
  group('buildRegionOutlineFeature', () {
    test('single polygon → Feature with Polygon geometry', () {
      final region = _region(
        polygons: [
          [
            _square(minLat: 48, minLon: 11, maxLat: 49, maxLon: 12),
          ],
        ],
      );
      final f = buildRegionOutlineFeature(region);
      expect(f['type'], equals('Feature'));
      final geometry = f['geometry'] as Map<String, dynamic>;
      expect(geometry['type'], equals('Polygon'));
      final coords = geometry['coordinates'] as List<dynamic>;
      expect(coords, hasLength(1), reason: 'one ring (outer)');
    });

    test('coordinates are [lon, lat] — GeoJSON RFC 7946 order', () {
      final region = _region(
        polygons: [
          [
            _square(minLat: 48, minLon: 11, maxLat: 49, maxLon: 12),
          ],
        ],
      );
      final geometry =
          buildRegionOutlineFeature(region)['geometry'] as Map<String, dynamic>;
      final coords = geometry['coordinates'] as List<dynamic>;
      final ring = coords.first as List<dynamic>;
      final first = ring.first as List<dynamic>;
      // Source point is [lat=48, lon=11] → emitted [lon=11, lat=48].
      expect(first[0], closeTo(11, 1e-10)); // longitude first
      expect(first[1], closeTo(48, 1e-10)); // latitude second
    });

    test('multiple polygons → MultiPolygon geometry', () {
      final region = _region(
        polygons: [
          [
            _square(minLat: 48, minLon: 11, maxLat: 49, maxLon: 12),
          ],
          [
            _square(minLat: 50, minLon: 13, maxLat: 51, maxLon: 14),
          ],
        ],
      );
      final geometry =
          buildRegionOutlineFeature(region)['geometry'] as Map<String, dynamic>;
      expect(geometry['type'], equals('MultiPolygon'));
      final coords = geometry['coordinates'] as List<dynamic>;
      expect(coords, hasLength(2), reason: 'two polygons');
    });

    test('holes (inner rings) are preserved', () {
      final region = _region(
        polygons: [
          [
            _square(minLat: 48, minLon: 11, maxLat: 49, maxLon: 12), // outer
            _square(
              minLat: 48.2,
              minLon: 11.2,
              maxLat: 48.8,
              maxLon: 11.8,
            ), // hole
          ],
        ],
      );
      final geometry =
          buildRegionOutlineFeature(region)['geometry'] as Map<String, dynamic>;
      final coords = geometry['coordinates'] as List<dynamic>;
      expect(coords, hasLength(2), reason: 'outer ring + one hole');
    });

    test('rings with < 4 points are skipped', () {
      final region = _region(
        polygons: [
          [
            [
              [48.0, 11.0],
              [48.0, 12.0],
              [48.0, 11.0],
            ], // only 3 points — not a valid GeoJSON ring
          ],
        ],
      );
      final f = buildRegionOutlineFeature(region);
      // No valid ring survives → empty FeatureCollection.
      expect(f['type'], equals('FeatureCollection'));
      expect(f['features'], isEmpty);
    });

    test('empty polygons → empty FeatureCollection', () {
      final region = _region(polygons: []);
      final f = buildRegionOutlineFeature(region);
      expect(f['type'], equals('FeatureCollection'));
      expect(f['features'], isEmpty);
    });

    test('osm_id is carried in properties', () {
      final region = _region(
        osmId: 987654,
        polygons: [
          [
            _square(minLat: 48, minLon: 11, maxLat: 49, maxLon: 12),
          ],
        ],
      );
      final props =
          buildRegionOutlineFeature(region)['properties'] as Map<String, dynamic>;
      expect(props['osm_id'], equals(987654));
    });
  });
}
