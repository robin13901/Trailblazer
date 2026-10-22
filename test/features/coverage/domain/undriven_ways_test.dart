// Unit tests for computeUndrivenWays — the pure complement/clip that powers the
// on-demand blue "undriven roads inside a region" overlay.

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/coverage/domain/undriven_ways.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Axis-aligned rectangular region (ring points are `[lat, lon]`).
AdminRegion _rect({
  required double minLat,
  required double minLon,
  required double maxLat,
  required double maxLon,
  int level = 10,
  int osmId = 1,
}) {
  final ring = <List<double>>[
    [minLat, minLon],
    [minLat, maxLon],
    [maxLat, maxLon],
    [maxLat, minLon],
    [minLat, minLon],
  ];
  return AdminRegion(
    osmId: osmId,
    adminLevel: level,
    name: 'Test',
    bboxMinLat: minLat,
    bboxMinLon: minLon,
    bboxMaxLat: maxLat,
    bboxMaxLon: maxLon,
    polygons: [
      [ring],
    ],
    areaKm2: 0,
  );
}

WayCandidate _way(int id, List<LatLng> geom) =>
    WayCandidate(wayId: id, geometry: geom, highwayClass: 'residential');

void main() {
  // Region: ~2.2 km (lat) × ~1.4 km (lon) box around lat 50.
  final region = _rect(
    minLat: 49.99,
    minLon: 8,
    maxLat: 50.01,
    maxLon: 8.02,
  );

  // A straight way fully inside the region, running west→east along lon.
  final insideGeom = <LatLng>[
    const LatLng(50, 8.004),
    const LatLng(50, 8.008),
    const LatLng(50, 8.012),
    const LatLng(50, 8.016),
  ];
  final insideTotal = polylineLengthMeters(insideGeom);

  group('computeUndrivenWays', () {
    test('fully-inside, undriven way → emitted whole', () {
      final out = computeUndrivenWays(
        ways: [_way(1, insideGeom)],
        region: region,
        drivenByWayId: const {},
      );
      expect(out, hasLength(1));
      expect(out.first.wayId, 1);
      expect(out.first.geometry.length, greaterThanOrEqualTo(2));
      expect(out.first.datum.isFull, isFalse);
    });

    test('fully-driven way → nothing emitted', () {
      final out = computeUndrivenWays(
        ways: [_way(1, insideGeom)],
        region: region,
        drivenByWayId: {
          1: [Interval(0, insideTotal + 100)],
        },
      );
      expect(out, isEmpty);
    });

    test('driven middle → two undriven gaps (before + after)', () {
      final out = computeUndrivenWays(
        ways: [_way(1, insideGeom)],
        region: region,
        drivenByWayId: {
          1: [Interval(insideTotal * 0.3, insideTotal * 0.7)],
        },
      );
      expect(out, hasLength(2));
      for (final w in out) {
        expect(w.geometry.length, greaterThanOrEqualTo(2));
      }
    });

    test('way entirely outside region → nothing emitted', () {
      final outsideGeom = <LatLng>[
        const LatLng(50, 8.10),
        const LatLng(50, 8.11),
      ];
      final out = computeUndrivenWays(
        ways: [_way(2, outsideGeom)],
        region: region,
        drivenByWayId: const {},
      );
      expect(out, isEmpty);
    });

    test('boundary-crossing way → only the in-region part is emitted', () {
      final narrow = _rect(
        minLat: 49.99,
        minLon: 8,
        maxLat: 50.01,
        maxLon: 8.009, // boundary between vertex 8.006 (in) and 8.014 (out)
      );
      final crossingGeom = <LatLng>[
        const LatLng(50, 8.002),
        const LatLng(50, 8.004),
        const LatLng(50, 8.006),
        const LatLng(50, 8.014),
        const LatLng(50, 8.018),
      ];
      final out = computeUndrivenWays(
        ways: [_way(3, crossingGeom)],
        region: narrow,
        drivenByWayId: const {},
      );
      expect(out, isNotEmpty);
      // No emitted point reaches past the in-region vertices (≤ 8.006, + tol).
      final maxLon = out
          .expand((w) => w.geometry)
          .map((p) => p.longitude)
          .reduce((a, b) => a > b ? a : b);
      expect(maxLon, lessThanOrEqualTo(8.007));
    });

    test('sub-floor undriven slivers are dropped', () {
      // Drive all but the last ~1 m — the residual gap is below the 5 m floor.
      final out = computeUndrivenWays(
        ways: [_way(1, insideGeom)],
        region: region,
        drivenByWayId: {
          1: [Interval(0, insideTotal - 1)],
        },
      );
      expect(out, isEmpty);
    });
  });
}
