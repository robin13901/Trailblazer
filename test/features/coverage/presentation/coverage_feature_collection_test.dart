// Trailblazer Phase 7, Plan 07-04:
// Unit tests for buildCoverageFeatureCollection.

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_feature_collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

void main() {
  group('buildCoverageFeatureCollection', () {
    // Helpers ---------------------------------------------------------------

    CoverageWay makeFullWay(int id) => CoverageWay(
          wayId: id,
          geometry: const [
            LatLng(48.1371, 11.5754), // Munich city centre — lat, lon
            LatLng(48.1380, 11.5762),
            LatLng(48.1390, 11.5770),
          ],
          datum: const CoverageDatum(fraction: 1, isFull: true),
        );

    CoverageWay makePartialWay(int id, double fraction) => CoverageWay(
          wayId: id,
          geometry: const [
            LatLng(48.2000, 11.6000),
            LatLng(48.2010, 11.6010),
          ],
          datum: CoverageDatum(fraction: fraction, isFull: false),
        );

    CoverageWay makeDegenerateWay(int id) => CoverageWay(
          wayId: id,
          geometry: const [LatLng(48, 11)], // only 1 point — degenerate
          datum: const CoverageDatum(fraction: 0.5, isFull: false),
        );

    // Tests -----------------------------------------------------------------

    test('returns a valid FeatureCollection structure', () {
      final result = buildCoverageFeatureCollection([makeFullWay(1)]);
      expect(result['type'], equals('FeatureCollection'));
      expect(result['features'], isA<List<dynamic>>());
    });

    test('empty list produces FeatureCollection with empty features', () {
      final result = buildCoverageFeatureCollection([]);
      expect(result['type'], equals('FeatureCollection'));
      expect(result['features'], isEmpty);
    });

    test('full way produces is_full == 1', () {
      final result = buildCoverageFeatureCollection([makeFullWay(42)]);
      final features = result['features'] as List<dynamic>;
      expect(features, hasLength(1));
      final props = (features[0] as Map<dynamic, dynamic>)['properties']
          as Map<dynamic, dynamic>;
      expect(props['is_full'], equals(1));
      expect(props['is_full'], isA<int>());
    });

    test('partial way produces is_full == 0', () {
      final result =
          buildCoverageFeatureCollection([makePartialWay(99, 0.65)]);
      final features = result['features'] as List<dynamic>;
      expect(features, hasLength(1));
      final props = (features[0] as Map<dynamic, dynamic>)['properties']
          as Map<dynamic, dynamic>;
      expect(props['is_full'], equals(0));
      expect(props['is_full'], isA<int>());
    });

    test('fraction is preserved as a double in properties', () {
      final result =
          buildCoverageFeatureCollection([makePartialWay(7, 0.73)]);
      final features = result['features'] as List<dynamic>;
      final props = (features[0] as Map<dynamic, dynamic>)['properties']
          as Map<dynamic, dynamic>;
      expect(props['fraction'], closeTo(0.73, 1e-10));
      expect(props['fraction'], isA<double>());
    });

    test('way_id is set from CoverageWay.wayId', () {
      final result = buildCoverageFeatureCollection([makeFullWay(123456789)]);
      final features = result['features'] as List<dynamic>;
      final props = (features[0] as Map<dynamic, dynamic>)['properties']
          as Map<dynamic, dynamic>;
      expect(props['way_id'], equals(123456789));
    });

    test('coordinates are [longitude, latitude] — GeoJSON RFC 7946 order', () {
      final result = buildCoverageFeatureCollection([makeFullWay(1)]);
      final features = result['features'] as List<dynamic>;
      final geometry = (features[0] as Map<dynamic, dynamic>)['geometry']
          as Map<dynamic, dynamic>;
      expect(geometry['type'], equals('LineString'));
      final coords = geometry['coordinates'] as List<dynamic>;
      // First point: LatLng(48.1371, 11.5754) → [lon=11.5754, lat=48.1371]
      final first = coords[0] as List<dynamic>;
      expect(first[0], closeTo(11.5754, 1e-10)); // longitude first
      expect(first[1], closeTo(48.1371, 1e-10)); // latitude second
    });

    test('two ways produce two features', () {
      final result = buildCoverageFeatureCollection([
        makeFullWay(1),
        makePartialWay(2, 0.5),
      ]);
      final features = result['features'] as List<dynamic>;
      expect(features, hasLength(2));
    });

    test('degenerate way with 1 point is dropped', () {
      final result = buildCoverageFeatureCollection([
        makeDegenerateWay(10),
        makeFullWay(11),
      ]);
      final features = result['features'] as List<dynamic>;
      // Degenerate way dropped; only the full way survives.
      expect(features, hasLength(1));
      final props = (features[0] as Map<dynamic, dynamic>)['properties']
          as Map<dynamic, dynamic>;
      expect(props['way_id'], equals(11));
    });

    test('list of only degenerate ways produces empty features', () {
      final result = buildCoverageFeatureCollection([
        makeDegenerateWay(1),
        makeDegenerateWay(2),
      ]);
      expect(result['features'], isEmpty);
    });

    test('all geometry points are included in coordinates', () {
      final result = buildCoverageFeatureCollection([makeFullWay(1)]);
      final features = result['features'] as List<dynamic>;
      final geometry = (features[0] as Map<dynamic, dynamic>)['geometry']
          as Map<dynamic, dynamic>;
      final coords = geometry['coordinates'] as List<dynamic>;
      // makeFullWay has 3 points.
      expect(coords, hasLength(3));
    });
  });
}
