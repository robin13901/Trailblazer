// STAGE-1 clip-per-region attribution tests (2026-07-25). Exercises
// computeCoverageAttribution() directly — no isolate spawned. The function no
// longer takes driven intervals or totals: it returns durable
// WayRegionAttributionRow meter-ranges (offsets along each way) per (way,
// region, level). STAGE-2 driven/total aggregation is tested in
// coverage_compute_service_test.dart.
//
// SEMANTIC CHANGE FROM THE CENTROID MODEL (deliberate, #7): a way is no longer
// attributed whole to the ONE region containing its centroid. Instead each
// segment is attributed to the region containing its midpoint and consecutive
// same-region segments are merged into one meter-range — so a boundary-crossing
// way splits its length across the two regions it passes through.

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_attribution.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
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

/// A level-8 region: WEST half [lon 9.17..9.195].
AdminRegion _regionWest() => const AdminRegion(
  osmId: 111,
  adminLevel: 8,
  name: 'West',
  bboxMinLat: 49.78,
  bboxMinLon: 9.17,
  bboxMaxLat: 49.82,
  bboxMaxLon: 9.195,
  polygons: [
    [
      [
        [49.78, 9.17],
        [49.82, 9.17],
        [49.82, 9.195],
        [49.78, 9.195],
        [49.78, 9.17],
      ],
    ],
  ],
  areaKm2: 0,
);

/// A level-8 region: EAST half [lon 9.195..9.22].
AdminRegion _regionEast() => const AdminRegion(
  osmId: 222,
  adminLevel: 8,
  name: 'East',
  bboxMinLat: 49.78,
  bboxMinLon: 9.195,
  bboxMaxLat: 49.82,
  bboxMaxLon: 9.22,
  polygons: [
    [
      [
        [49.78, 9.195],
        [49.82, 9.195],
        [49.82, 9.22],
        [49.78, 9.22],
        [49.78, 9.195],
      ],
    ],
  ],
  areaKm2: 0,
);

/// A single level-8 region covering the whole test square.
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
  areaKm2: 0,
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
  areaKm2: 0,
);

/// 3-point vertical way inside `_regionLevel8` (all at lon 9.190).
WayCandidate _fixtureWay({int wayId = 100001}) => WayCandidate(
  wayId: wayId,
  highwayClass: 'residential',
  geometry: const [
    LatLng(49.799, 9.190),
    LatLng(49.800, 9.190),
    LatLng(49.801, 9.190),
  ],
);

double _len(List<LatLng> g) {
  var total = 0.0;
  for (var i = 0; i < g.length - 1; i++) {
    total += haversineMeters(
      g[i].latitude,
      g[i].longitude,
      g[i + 1].latitude,
      g[i + 1].longitude,
    );
  }
  return total;
}

void main() {
  group('computeCoverageAttribution (clip-per-region)', () {
    test('way inside one region → one row spanning [0, wayLen]', () {
      final way = _fixtureWay();
      final rows = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        gzippedTiles: [
          _gzTile([way]),
        ],
        tileBboxes: const [_bbox],
      );

      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.wayId, way.wayId);
      expect(r.regionId, '151999');
      expect(r.adminLevel, 8);
      expect(r.rangeStartM, 0);
      // Full way length inside the single covering region.
      expect(r.rangeEndM, closeTo(_len(way.geometry), 0.01));
    });

    test('boundary-crossing way splits length across two regions with '
        'correct meter-ranges', () {
      // Horizontal way from lon 9.18 (west) → 9.21 (east) at fixed lat.
      const way = WayCandidate(
        wayId: 500,
        highwayClass: 'residential',
        geometry: [
          LatLng(49.80, 9.180),
          LatLng(49.80, 9.190), // west midpoints
          LatLng(49.80, 9.200), // segment 2 midpoint (9.195) = boundary
          LatLng(49.80, 9.210), // east
        ],
      );
      final rows = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionWest(), _regionEast()],
        },
        gzippedTiles: [
          _gzTile([way]),
        ],
        tileBboxes: const [_bbox],
      );

      // One row per region (west run then east run), contiguous + adjacent.
      final west = rows.where((r) => r.regionId == '111').toList();
      final east = rows.where((r) => r.regionId == '222').toList();
      expect(west, hasLength(1), reason: 'one west run');
      expect(east, hasLength(1), reason: 'one east run');

      // Ranges are adjacent and cover the whole way with no gap/overlap.
      final total = _len(way.geometry);
      expect(west.single.rangeStartM, 0);
      expect(east.single.rangeEndM, closeTo(total, 0.01));
      expect(
        west.single.rangeEndM,
        closeTo(east.single.rangeStartM, 0.01),
        reason: 'runs meet at the boundary offset',
      );
      // Both regions get a non-trivial share.
      expect(west.single.rangeEndM - west.single.rangeStartM, greaterThan(0));
      expect(east.single.rangeEndM - east.single.rangeStartM, greaterThan(0));
    });

    test('already-attributed wayIds are skipped', () {
      final way = _fixtureWay();
      final rows = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        gzippedTiles: [
          _gzTile([way]),
        ],
        tileBboxes: const [_bbox],
        alreadyAttributedWayIds: {way.wayId},
      );
      expect(rows, isEmpty, reason: 'cached way must not be re-clipped');
    });

    test('level 2 region is never attributed (excluded from levels)', () {
      final way = _fixtureWay();
      final rows = computeCoverageAttribution(
        regionsByLevel: {
          2: [_regionLevel2()],
          8: [_regionLevel8()],
        },
        gzippedTiles: [
          _gzTile([way]),
        ],
        tileBboxes: const [_bbox],
      );
      expect(
        rows.any((r) => r.regionId == '51477'),
        isFalse,
        reason: 'level-2 Deutschland must never be attributed',
      );
      expect(rows.any((r) => r.regionId == '151999'), isTrue);
    });

    test('empty tiles → no rows', () {
      final rows = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        gzippedTiles: const [],
        tileBboxes: const [],
      );
      expect(rows, isEmpty);
    });

    test('way outside every region → not attributed', () {
      const way = WayCandidate(
        wayId: 999,
        highwayClass: 'residential',
        geometry: [LatLng(10, 10), LatLng(10.001, 10)],
      );
      final rows = computeCoverageAttribution(
        regionsByLevel: {
          8: [_regionLevel8()],
        },
        gzippedTiles: [
          _gzTile([way]),
        ],
        tileBboxes: const [
          LatLonBbox(minLat: 9, minLon: 9, maxLat: 11, maxLon: 11),
        ],
      );
      expect(rows, isEmpty);
    });
  });
}
