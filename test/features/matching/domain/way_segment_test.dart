// Phase 5 (Plan 05-03): Tests for WaySegment value type.
//
// Covers:
//   1. fromWay decomposition (3-point way → 2 segments with correct segIdx)
//   2. fromWay on single-point way → empty list
//   3. fromWay on 0-point way → empty list
//   4. minLat/maxLat/minLon/maxLon correctness (NE and SW oriented)
//   5. Equality: same (wayId, segIdx) even with different coords
//   6. Equality: same wayId different segIdx → NOT equal
//   7. hashCode consistent with equality

import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

void main() {
  // ---------------------------------------------------------------------------
  // fromWay decomposition
  // ---------------------------------------------------------------------------
  group('WaySegment.fromWay — decomposition', () {
    // A three-point way → two segments.
    const way3pt = WayCandidate(
      wayId: 42,
      geometry: [
        LatLng(49.700, 9.100),
        LatLng(49.701, 9.101),
        LatLng(49.702, 9.102),
      ],
      highwayClass: 'residential',
    );

    test('fromWay on 3-point way returns 2 segments', () {
      final segs = WaySegment.fromWay(way3pt);
      expect(segs.length, 2);
    });

    test('first segment has segIdx=0, correct coords', () {
      final segs = WaySegment.fromWay(way3pt);
      expect(segs[0].segIdx, 0);
      expect(segs[0].wayId, 42);
      expect(segs[0].aLat, closeTo(49.700, 1e-10));
      expect(segs[0].aLon, closeTo(9.100, 1e-10));
      expect(segs[0].bLat, closeTo(49.701, 1e-10));
      expect(segs[0].bLon, closeTo(9.101, 1e-10));
    });

    test('second segment has segIdx=1, correct coords', () {
      final segs = WaySegment.fromWay(way3pt);
      expect(segs[1].segIdx, 1);
      expect(segs[1].aLat, closeTo(49.701, 1e-10));
      expect(segs[1].bLat, closeTo(49.702, 1e-10));
    });

    test('fromWay on 1-point way returns empty list', () {
      const way1pt = WayCandidate(
        wayId: 1,
        geometry: [LatLng(49.700, 9.100)],
        highwayClass: 'primary',
      );
      expect(WaySegment.fromWay(way1pt), isEmpty);
    });

    test('fromWay on 0-point way returns empty list', () {
      const way0pt = WayCandidate(
        wayId: 2,
        geometry: [],
        highwayClass: 'primary',
      );
      expect(WaySegment.fromWay(way0pt), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Node ids (exact topology + coordinate-hash fallback)
  // ---------------------------------------------------------------------------
  group('WaySegment.fromWay — node ids', () {
    test('uses OSM node ids when nodeIds length matches geometry', () {
      const way = WayCandidate(
        wayId: 42,
        geometry: [
          LatLng(49.700, 9.100),
          LatLng(49.701, 9.101),
          LatLng(49.702, 9.102),
        ],
        nodeIds: [500, 501, 502],
        highwayClass: 'residential',
      );
      final segs = WaySegment.fromWay(way);
      expect(segs[0].aNodeId, 500);
      expect(segs[0].bNodeId, 501);
      expect(segs[1].aNodeId, 501); // shared junction node with seg[0].b
      expect(segs[1].bNodeId, 502);
    });

    test('two ways sharing a coordinate share a node key when ids absent', () {
      // Junction point (49.701, 9.101) is the END of wayA and the START of wayB.
      const wayA = WayCandidate(
        wayId: 1,
        geometry: [LatLng(49.700, 9.100), LatLng(49.701, 9.101)],
        highwayClass: 'residential',
      );
      const wayB = WayCandidate(
        wayId: 2,
        geometry: [LatLng(49.701, 9.101), LatLng(49.702, 9.102)],
        highwayClass: 'residential',
      );
      final a = WaySegment.fromWay(wayA).single;
      final b = WaySegment.fromWay(wayB).single;
      // No OSM ids → coordinate-hash surrogate; the shared vertex hashes equal.
      expect(a.bNodeId, b.aNodeId);
      // Surrogate keys are negative (never collide with real OSM node ids).
      expect(a.aNodeId, isNegative);
    });

    test('nodeIds length mismatch → falls back to coordinate hash', () {
      const way = WayCandidate(
        wayId: 3,
        geometry: [LatLng(49.700, 9.100), LatLng(49.701, 9.101)],
        nodeIds: [500], // wrong length → ignored
        highwayClass: 'residential',
      );
      final seg = WaySegment.fromWay(way).single;
      expect(seg.aNodeId, isNegative);
      expect(seg.bNodeId, isNegative);
    });
  });

  // ---------------------------------------------------------------------------
  // Bounding-box helpers
  // ---------------------------------------------------------------------------
  group('WaySegment bbox helpers', () {
    // NE-oriented segment: a is SW, b is NE.
    const segNE = WaySegment(
      wayId: 10,
      segIdx: 0,
      aLat: 49.700,
      aLon: 9.100,
      bLat: 49.710,
      bLon: 9.110,
      highwayClass: 'primary',
      oneway: OnewayDirection.no,
    );

    // SW-oriented segment: a is NE, b is SW.
    const segSW = WaySegment(
      wayId: 11,
      segIdx: 0,
      aLat: 49.710,
      aLon: 9.110,
      bLat: 49.700,
      bLon: 9.100,
      highwayClass: 'primary',
      oneway: OnewayDirection.no,
    );

    test('NE segment: minLat/maxLat/minLon/maxLon correct', () {
      expect(segNE.minLat, 49.700);
      expect(segNE.maxLat, 49.710);
      expect(segNE.minLon, 9.100);
      expect(segNE.maxLon, 9.110);
    });

    test('SW segment (reversed coords): minLat/maxLat/minLon/maxLon correct', () {
      expect(segSW.minLat, 49.700);
      expect(segSW.maxLat, 49.710);
      expect(segSW.minLon, 9.100);
      expect(segSW.maxLon, 9.110);
    });
  });

  // ---------------------------------------------------------------------------
  // Equality and hashCode
  // ---------------------------------------------------------------------------
  group('WaySegment equality', () {
    // Same (wayId, segIdx) but different coords — still equal.
    const segA = WaySegment(
      wayId: 100,
      segIdx: 3,
      aLat: 49.700,
      aLon: 9.100,
      bLat: 49.701,
      bLon: 9.101,
      highwayClass: 'primary',
      oneway: OnewayDirection.no,
    );
    const segB = WaySegment(
      wayId: 100,
      segIdx: 3,
      // Different coords — simulating re-densified geometry.
      aLat: 49.750,
      aLon: 9.150,
      bLat: 49.760,
      bLon: 9.160,
      highwayClass: 'secondary',
      oneway: OnewayDirection.forward,
    );
    // Different segIdx → NOT equal.
    const segC = WaySegment(
      wayId: 100,
      segIdx: 4,
      aLat: 49.700,
      aLon: 9.100,
      bLat: 49.701,
      bLon: 9.101,
      highwayClass: 'primary',
      oneway: OnewayDirection.no,
    );

    test('same (wayId, segIdx) with different coords are equal', () {
      expect(segA, equals(segB));
    });

    test('same wayId but different segIdx are NOT equal', () {
      expect(segA, isNot(equals(segC)));
    });

    test('hashCode matches for equal segments', () {
      expect(segA.hashCode, segB.hashCode);
    });

    test('hashCode differs for non-equal segments', () {
      // Not guaranteed by contract but practically true for distinct slots.
      expect(segA.hashCode, isNot(segC.hashCode));
    });

    test('works correctly in a Set', () {
      final set = {segA, segB, segC};
      // segA == segB, so set should have 2 elements.
      expect(set.length, 2);
    });
  });
}
