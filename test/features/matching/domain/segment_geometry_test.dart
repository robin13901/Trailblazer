// Phase 5 (Plan 05-02): Segment geometry — golden-value unit tests.
//
// Test geometry is based on local equirectangular projection at German
// latitudes (~49.7°N, Bavaria). All distances are in meters; tolerance
// is ±0.1 m for perpendicular-distance tests and ±0.5 m for segment-length
// tests.
//
// No Flutter binding — pure `dart test`.

import 'dart:math' as math;

import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // metersPerDegreeLon
  // ---------------------------------------------------------------------------
  group('metersPerDegreeLon', () {
    // Test 1: at equator cos(0) = 1 → metersPerDegreeLon(0) = 111320
    test('at equator (lat=0) ≈ 111320', () {
      expect(metersPerDegreeLon(0), closeTo(111320, 1));
    });

    // Test 2: at Bavaria (lat=49.7°) ≈ 72000 ±100
    // cos(49.7°) ≈ 0.6468 → 111320 × 0.6468 ≈ 71998
    test('at Bavaria (lat=49.7°) ≈ 71998 ±100', () {
      final expected = 111320 * math.cos(49.7 * math.pi / 180);
      expect(metersPerDegreeLon(49.7), closeTo(expected, 1));
      // Sanity-check the expected value is close to 72000 ±100
      expect(metersPerDegreeLon(49.7), closeTo(72000, 100));
    });
  });

  // ---------------------------------------------------------------------------
  // perpDistanceToSegmentMeters
  // ---------------------------------------------------------------------------
  group('perpDistanceToSegmentMeters', () {
    // Reference segment: horizontal E-W 72m segment at lat=49.7°
    // aLat=49.7, aLon=9.0 → bLat=49.7, bLon=9.001
    const aLat = 49.7;
    const aLon = 9.0;
    const bLat = 49.7;
    const bLon = 9.001;

    // Test 3: point on the segment → distance ≈ 0 (< 0.01 m)
    test('point on the segment midpoint → distance < 0.01 m', () {
      // midpoint of the segment
      const mLon = (aLon + bLon) / 2;
      final dist = perpDistanceToSegmentMeters(
        pLat: aLat,
        pLon: mLon,
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
      expect(dist, closeTo(0, 0.01));
    });

    // Test 4: point 10 m north (perpendicular) of midpoint → ≈ 10 m ±0.1 m
    // pLat = aLat + 10 / metersPerDegreeLat;  pLon = midpoint lon
    test('point 10 m north of E-W segment midpoint → ≈ 10.0 m ±0.1 m', () {
      const pLat = aLat + 10 / metersPerDegreeLat;
      const midLon = (aLon + bLon) / 2;
      final dist = perpDistanceToSegmentMeters(
        pLat: pLat,
        pLon: midLon,
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
      expect(dist, closeTo(10.0, 0.1));
    });

    // Test 5: point beyond endpoint → distance to that endpoint
    // Place point 20° east of b; projection t > 1 → clamp to b, dist = pt-to-b
    test('point beyond b endpoint → distance equals point-to-b distance', () {
      // Point far to the east, same latitude
      const pLon = bLon + 0.01; // well beyond segment end
      const pLat = aLat;
      final dist = perpDistanceToSegmentMeters(
        pLat: pLat,
        pLon: pLon,
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
      // dist-to-b = (pLon - bLon) * metersPerDegreeLon(aLat)
      final mLon = metersPerDegreeLon(aLat);
      final expectedDist = (pLon - bLon) * mLon;
      expect(dist, closeTo(expectedDist, 0.1));
    });

    // Test 5b: point before a endpoint → distance to that endpoint
    test('point before a endpoint → distance equals point-to-a distance', () {
      const pLon = aLon - 0.01; // well before segment start
      const pLat = aLat;
      final dist = perpDistanceToSegmentMeters(
        pLat: pLat,
        pLon: pLon,
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
      final mLon = metersPerDegreeLon(aLat);
      final expectedDist = (aLon - pLon) * mLon;
      expect(dist, closeTo(expectedDist, 0.1));
    });

    // Test 6: degenerate segment (a == b) → distance to point a
    test('degenerate segment (a == b) → distance to point a', () {
      // Point 30m north of a degenerate point at (49.7, 9.0)
      const pLat = 49.7 + 30 / metersPerDegreeLat;
      const pLon = 9.0;
      final dist = perpDistanceToSegmentMeters(
        pLat: pLat,
        pLon: pLon,
        aLat: 49.7,
        aLon: 9,
        bLat: 49.7,
        bLon: 9, // same as a → degenerate
      );
      expect(dist, closeTo(30.0, 0.1));
    });
  });

  // ---------------------------------------------------------------------------
  // projectionFractionOnSegment
  // ---------------------------------------------------------------------------
  group('projectionFractionOnSegment', () {
    const aLat = 49.7;
    const aLon = 9.0;
    const bLat = 49.7;
    const bLon = 9.001;

    // Test 7: midpoint → fraction ≈ 0.5
    test('midpoint of segment → fraction ≈ 0.5 ±1e-3', () {
      const midLon = (aLon + bLon) / 2;
      final t = projectionFractionOnSegment(
        pLat: aLat,
        pLon: midLon,
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
      expect(t, closeTo(0.5, 1e-3));
    });

    // Test 8: point before a → fraction = 0 (clamped)
    test('point before a → fraction clamped to 0.0', () {
      final t = projectionFractionOnSegment(
        pLat: aLat,
        pLon: aLon - 0.01, // well west of a
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
      expect(t, equals(0.0));
    });

    // Test 9: point past b → fraction = 1 (clamped)
    test('point past b → fraction clamped to 1.0', () {
      final t = projectionFractionOnSegment(
        pLat: aLat,
        pLon: bLon + 0.01, // well east of b
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
      expect(t, equals(1.0));
    });

    // Extra: degenerate segment → fraction = 0
    test('degenerate segment → fraction 0.0', () {
      final t = projectionFractionOnSegment(
        pLat: aLat,
        pLon: aLon + 0.005,
        aLat: aLat,
        aLon: aLon,
        bLat: aLat,
        bLon: aLon, // degenerate
      );
      expect(t, equals(0.0));
    });
  });

  // ---------------------------------------------------------------------------
  // segmentLengthMeters
  // ---------------------------------------------------------------------------
  group('segmentLengthMeters', () {
    // Test 10: 100 m east-west segment at lat=49.7°
    // dlon = 100 / metersPerDegreeLon(49.7)
    test('100 m E-W segment at lat=49.7° → ≈ 100 m ±0.5 m', () {
      final mLon = metersPerDegreeLon(49.7);
      final dLon = 100 / mLon;
      final len = segmentLengthMeters(
        aLat: 49.7,
        aLon: 9,
        bLat: 49.7,
        bLon: 9.0 + dLon,
      );
      expect(len, closeTo(100, 0.5));
    });

    // Test 11: 100 m north-south segment at lat=49.7°
    // dlat = 100 / metersPerDegreeLat
    test('100 m N-S segment → ≈ 100 m ±0.5 m', () {
      const dLat = 100 / metersPerDegreeLat;
      final len = segmentLengthMeters(
        aLat: 49.7,
        aLon: 9,
        bLat: 49.7 + dLat,
        bLon: 9,
      );
      expect(len, closeTo(100, 0.5));
    });

    // Extra: zero-length degenerate segment → 0.0
    test('degenerate segment (a == b) → 0.0', () {
      final len = segmentLengthMeters(
        aLat: 49.7,
        aLon: 9,
        bLat: 49.7,
        bLon: 9,
      );
      expect(len, equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // Test 12: cross-check against haversineMeters
  // ---------------------------------------------------------------------------
  group('perpDistance vs haversineMeters cross-check', () {
    // A point 15 m north of a horizontal E-W segment (at the midpoint
    // longitude). perpDistance ≈ haversineMeters(p, closest) within ±0.5 m.
    test('point 15 m north → perpDist ≈ haversine to closest ±0.5 m', () {
      const aLat = 49.7;
      const aLon = 9.0;
      const bLat = 49.7;
      const bLon = 9.001;
      const midLon = (aLon + bLon) / 2;
      const pLat = aLat + 15 / metersPerDegreeLat;
      const pLon = midLon;

      final perpDist = perpDistanceToSegmentMeters(
        pLat: pLat,
        pLon: pLon,
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );

      // Closest point on segment is (aLat, midLon) — directly below p
      // (p projects to midpoint since pLon == midLon and segment is horizontal)
      final hvDist = haversineMeters(pLat, pLon, aLat, midLon);

      expect(perpDist, closeTo(hvDist, 0.5));
    });
  });
}
