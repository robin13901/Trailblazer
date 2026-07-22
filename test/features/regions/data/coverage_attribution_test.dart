// Pure coverage-attribution tests (2026-07-22). Exercises
// computeCoverageAttribution() directly — no isolate spawned — mirroring the
// coverage_compute_service_test fixtures and the matcher_isolate_test tile
// helper.

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_attribution.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Generous bbox covering all test geometry (Kleinheubach area).
const _bbox = LatLonBbox(minLat: 49.7, minLon: 9.1, maxLat: 49.9, maxLon: 9.3);

/// Gzip a synthetic single-tile Overpass envelope wrapping [ways].
Uint8List _gzTile(List<WayCandidate> ways) {
  final env = {
    'version': 0.6,
    'elements': [
      for (final w in ways)
        {
          'type': 'way',
          'id': w.wayId,
          'geometry': [
            for (final p in w.geometry) {'lat': p.latitude, 'lon': p.longitude},
          ],
          'tags': {'highway': w.highwayClass},
        },
    ],
  };
  return Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(env))));
}

AdminRegion _regionLevel8({int osmId = 151999}) => AdminRegion(
      osmId: osmId,
      adminLevel: 8,
      name: 'Kleinheubach',
      bboxMinLat: 49.78,
      bboxMinLon: 9.17,
      bboxMaxLat: 49.82,
      bboxMaxLon: 9.22,
      polygons: const [
        [
          [
            [49.78, 9.17],
            [49.82, 9.17],
            [49.82, 9.22],
            [49.78, 9.22],
            [49.78, 9.17],
          ],
        ],
      ],
    );

AdminRegion _regionLevel2({int osmId = 51477}) => AdminRegion(
      osmId: osmId,
      adminLevel: 2,
      name: 'Deutschland',
      bboxMinLat: 47,
      bboxMinLon: 5,
      bboxMaxLat: 55.1,
      bboxMaxLon: 15.1,
      polygons: const [
        [
          [
            [47.0, 5.0],
            [55.1, 5.0],
            [55.1, 15.1],
            [47.0, 15.1],
            [47.0, 5.0],
          ],
        ],
      ],
    );

/// 3-point way inside `_regionLevel8`.
WayCandidate _fixtureWay({int wayId = 100001}) => WayCandidate(
      wayId: wayId,
      highwayClass: 'residential',
      geometry: const [
        LatLng(49.799, 9.190),
        LatLng(49.800, 9.190),
        LatLng(49.801, 9.190),
      ],
    );

void main() {
  group('computeCoverageAttribution', () {
    test('driven way inside region → total>0, driven>0, realTotal from totals',
        () {
      final way = _fixtureWay();
      final out = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        totals: {'151999': 1234.5},
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
        intervalsByWayId: {way.wayId: [0, 100]},
      );

      final acc = out['151999'];
      expect(acc, isNotNull);
      expect(acc!.total, greaterThan(0));
      expect(acc.driven, greaterThan(0));
      expect(acc.realTotal, 1234.5);
    });

    test('un-driven way (no intervals) → total>0 but driven==0', () {
      final way = _fixtureWay();
      final out = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        totals: null,
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
        intervalsByWayId: const {}, // no driven intervals
      );

      final acc = out['151999'];
      expect(acc, isNotNull);
      expect(acc!.total, greaterThan(0));
      expect(acc.driven, 0);
    });

    test('null totals → realTotal is null', () {
      final way = _fixtureWay();
      final out = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        totals: null,
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
        intervalsByWayId: {way.wayId: [0, 100]},
      );
      expect(out['151999']!.realTotal, isNull);
    });

    test('level 2 region is never attributed (excluded from kComputeAdminLevels)',
        () {
      final way = _fixtureWay();
      final out = computeCoverageAttribution(
        regionsByLevel: {
          2: [_regionLevel2()],
          8: [_regionLevel8()],
        },
        totals: null,
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
        intervalsByWayId: {way.wayId: [0, 100]},
      );
      expect(out.containsKey('51477'), isFalse,
          reason: 'level-2 Deutschland must never be written');
      expect(out.containsKey('151999'), isTrue);
    });

    test('empty tiles → empty result', () {
      final out = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        totals: null,
        gzippedTiles: const [],
        tileBboxes: const [],
        intervalsByWayId: const {},
      );
      expect(out, isEmpty);
    });

    test('way outside every region → not attributed', () {
      // A way far from Kleinheubach (over open sea coords).
      const way = WayCandidate(
        wayId: 999,
        highwayClass: 'residential',
        geometry: [LatLng(10, 10), LatLng(10.001, 10)],
      );
      final out = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        totals: null,
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [LatLonBbox(minLat: 9, minLon: 9, maxLat: 11, maxLon: 11)],
        intervalsByWayId: {999: [0, 100]},
      );
      expect(out, isEmpty);
    });
  });
}
