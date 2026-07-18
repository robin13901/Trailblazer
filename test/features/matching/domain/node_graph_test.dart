// Tests for NodeGraph — the per-trip routing graph that gives the Viterbi
// decoder a real bounded on-road route distance (2026-07-18 route-aware fix).

import 'package:auto_explore/features/matching/domain/node_graph.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

void main() {
  // A simple + junction, node ids explicit:
  //   Way 1 (E-W main): nodes 10-11-12 along lat 49.700
  //   Way 2 (N-S side): nodes 20-11-21 through the shared junction node 11
  // Coordinates are ~each 0.001° apart (~111 m lat, ~73 m lon at 49.7°).
  const mainWay = WayCandidate(
    wayId: 1,
    geometry: [
      LatLng(49.700, 9.100),
      LatLng(49.700, 9.101),
      LatLng(49.700, 9.102),
    ],
    nodeIds: [10, 11, 12],
    highwayClass: 'residential',
  );
  const sideWay = WayCandidate(
    wayId: 2,
    geometry: [
      LatLng(49.699, 9.101),
      LatLng(49.700, 9.101), // shared junction node 11
      LatLng(49.701, 9.101),
    ],
    nodeIds: [20, 11, 21],
    highwayClass: 'residential',
  );

  group('NodeGraph.routeDistanceMeters', () {
    test('same segment → along-segment distance, no search', () {
      final g = NodeGraph.fromWays([mainWay]);
      // Segment 0 of way 1 is node 10→11. Fractions 0.2 and 0.8 along it.
      final segLen = g.segmentLength(1, 0);
      final d = g.routeDistanceMeters(
        fromWayId: 1, fromSegIdx: 0, fromFraction: 0.2, fromANode: 10, fromBNode: 11,
        toWayId: 1, toSegIdx: 0, toFraction: 0.8, toANode: 10, toBNode: 11,
        maxMeters: 5000,
      );
      expect(d, isNotNull);
      expect(d, closeTo(0.6 * segLen, 1e-6));
    });

    test('adjacent segments on same way → sums via shared node', () {
      final g = NodeGraph.fromWays([mainWay]);
      final seg0 = g.segmentLength(1, 0);
      final seg1 = g.segmentLength(1, 1);
      // Start at end of seg0 (frac 1.0 → node 11), end at end of seg1 (node 12).
      final d = g.routeDistanceMeters(
        fromWayId: 1, fromSegIdx: 0, fromFraction: 1, fromANode: 10, fromBNode: 11,
        toWayId: 1, toSegIdx: 1, toFraction: 1, toANode: 11, toBNode: 12,
        maxMeters: 5000,
      );
      expect(d, isNotNull);
      expect(d, closeTo(seg1, seg0 * 0.01 + 1e-6));
    });

    test('cross-way via shared junction node is reachable', () {
      final g = NodeGraph.fromWays([mainWay, sideWay]);
      // From main way near junction (node 11) to side way's far end (node 21).
      final d = g.routeDistanceMeters(
        fromWayId: 1, fromSegIdx: 0, fromFraction: 1, fromANode: 10, fromBNode: 11,
        toWayId: 2, toSegIdx: 1, toFraction: 1, toANode: 11, toBNode: 21,
        maxMeters: 5000,
      );
      expect(d, isNotNull, reason: 'shared node 11 links the two ways');
    });

    test('disconnected ways → null (broken path)', () {
      // A way with no shared node ids with mainWay.
      const isolated = WayCandidate(
        wayId: 3,
        geometry: [LatLng(50, 10), LatLng(50.001, 10.001)],
        nodeIds: [30, 31],
        highwayClass: 'residential',
      );
      final g = NodeGraph.fromWays([mainWay, isolated]);
      final d = g.routeDistanceMeters(
        fromWayId: 1, fromSegIdx: 0, fromFraction: 0.5, fromANode: 10, fromBNode: 11,
        toWayId: 3, toSegIdx: 0, toFraction: 0.5, toANode: 30, toBNode: 31,
        maxMeters: 5000,
      );
      expect(d, isNull);
    });

    test('reachable but beyond maxMeters cap → null', () {
      final g = NodeGraph.fromWays([mainWay, sideWay]);
      final d = g.routeDistanceMeters(
        fromWayId: 1, fromSegIdx: 0, fromFraction: 0, fromANode: 10, fromBNode: 11,
        toWayId: 2, toSegIdx: 1, toFraction: 1, toANode: 11, toBNode: 21,
        maxMeters: 1, // absurdly tight
      );
      expect(d, isNull);
    });

    test('coordinate-hash fallback links ways sharing a vertex (no ids)', () {
      // Same geometry as main+side but WITHOUT node ids — the surrogate keys
      // must still connect them at the shared (49.700, 9.101) vertex.
      const mainNoIds = WayCandidate(
        wayId: 1,
        geometry: [
          LatLng(49.700, 9.100),
          LatLng(49.700, 9.101),
          LatLng(49.700, 9.102),
        ],
        highwayClass: 'residential',
      );
      const sideNoIds = WayCandidate(
        wayId: 2,
        geometry: [
          LatLng(49.699, 9.101),
          LatLng(49.700, 9.101),
          LatLng(49.701, 9.101),
        ],
        highwayClass: 'residential',
      );
      final g = NodeGraph.fromWays([mainNoIds, sideNoIds]);
      // Use the surrogate keys via WaySegment; easiest is to route from way1
      // seg0 to way2 seg1 using the same-coordinate surrogate the graph built.
      // We can't name the surrogate ids here, so assert reachability by routing
      // within-graph using the endpoints the graph itself derived: fromBNode of
      // way1 seg0 == aNode of way1 seg1 == the junction; reuse fromANode/BNode
      // through a same-segment query is trivial, so instead assert the two
      // ways are connected by checking a cross-way route via the shared vertex.
      // Route from way1 seg0 (frac 1 = junction) to way2 seg1 (frac 1 = far).
      // The junction node key is shared, so distance is finite.
      // Derive the surrogate id the same way WaySegment does is internal; the
      // public guarantee we assert is simply "not null".
      final junctionKey = _surrogate(49.700, 9.101);
      final farKey = _surrogate(49.701, 9.101);
      final nearMainKey = _surrogate(49.700, 9.100);
      final d = g.routeDistanceMeters(
        fromWayId: 1, fromSegIdx: 0, fromFraction: 1,
        fromANode: nearMainKey, fromBNode: junctionKey,
        toWayId: 2, toSegIdx: 1, toFraction: 1,
        toANode: junctionKey, toBNode: farKey,
        maxMeters: 5000,
      );
      expect(d, isNotNull);
    });
  });
}

// Mirror of WaySegment.nodeKeyFor for the fallback test.
int _surrogate(double lat, double lon) {
  final qLat = (lat * 1e6).round();
  final qLon = (lon * 1e6).round();
  return -(qLat * 1000000007 + qLon).abs() - 1;
}
