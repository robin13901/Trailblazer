// Tests for clipDrivenWays — the topology-aware render logic that drops thorns,
// closes junction connectors, and stitches adjacent driven ways at shared OSM
// nodes (2026-07-18 gaps+thorns fix).

import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// A straight east-west way of ~[count-1]*~73m segments along one latitude.
// At lat 49, 0.001° lon ≈ 73 m. Node ids parallel to geometry.
({List<LatLng> geom, List<int> nodes}) ewWay({
  required double lat,
  required double lonStart,
  required int points,
  required List<int> nodeIds,
  double stepLon = 0.001,
}) {
  final g = <LatLng>[
    for (var i = 0; i < points; i++) LatLng(lat, lonStart + i * stepLon),
  ];
  return (geom: g, nodes: nodeIds);
}

void main() {
  group('clipDrivenWays — thorn drop', () {
    test('short non-bridging leaf (one end dangling) is dropped', () {
      // Way L: 2 points (~73m), shares its FIRST node (100) with neighbour N,
      // last node (199) dangles. Driven union only 5m → thorn.
      final l = ewWay(lat: 49, lonStart: 9, points: 2, nodeIds: [100, 199]);
      // Neighbour N shares node 100 at ITS end.
      final n = ewWay(lat: 49, lonStart: 8.999, points: 2, nodeIds: [98, 100]);
      final out = clipDrivenWays(
        unionByWayId: {
          1: [(0, 5)], // 5m driven on L — below thorn floor
          2: [(0, 73)], // N fully driven (keeps it in the driven set)
        },
        geomByWayId: {1: l.geom, 2: n.geom},
        nodesByWayId: {1: l.nodes, 2: n.nodes},
      );
      expect(out.map((c) => c.wayId), isNot(contains(1)),
          reason: 'dangling 5m leaf must be dropped as a thorn');
      expect(out.map((c) => c.wayId), contains(2));
    });

    test('short way with NO node ids is NOT thorn-dropped (fixture fallback)',
        () {
      final w = ewWay(lat: 49, lonStart: 9, points: 2, nodeIds: []);
      final out = clipDrivenWays(
        unionByWayId: {
          1: [(0, 5)],
        },
        geomByWayId: {1: w.geom},
        nodesByWayId: {1: const []},
      );
      // No positive topology → cannot classify as thorn → keep (old behavior).
      expect(out.map((c) => c.wayId), contains(1));
    });
  });

  group('clipDrivenWays — connector close', () {
    test('short bridging way (both ends shared) is drawn full-length', () {
      // Connector C (2 pts, ~73m) bridges A (shares C.start node 10) and
      // B (shares C.end node 11). Driven union collapsed to a point at 0m.
      final c = ewWay(lat: 49, lonStart: 9, points: 2, nodeIds: [10, 11]);
      final a = ewWay(lat: 49, lonStart: 8.999, points: 2, nodeIds: [9, 10]);
      final b = ewWay(lat: 49, lonStart: 9.001, points: 2, nodeIds: [11, 12]);
      final out = clipDrivenWays(
        unionByWayId: {
          1: [(0, 0)], // C: near-zero measured span
          2: [(0, 73)],
          3: [(0, 73)],
        },
        geomByWayId: {1: c.geom, 2: a.geom, 3: b.geom},
        nodesByWayId: {1: c.nodes, 2: a.nodes, 3: b.nodes},
      );
      final cSegs = out.where((x) => x.wayId == 1).toList();
      expect(cSegs, isNotEmpty, reason: 'bridging connector must render');
      final drawn = polylineLengthMeters(cSegs.first.geometry);
      final full = polylineLengthMeters(c.geom);
      expect(drawn, closeTo(full, full * 0.02),
          reason: 'bridging connector drawn full-length to close the gap');
    });
  });

  group('clipDrivenWays — gap stitch', () {
    test('adjacent ways sharing a node meet exactly at the junction', () {
      // A ends at node 50; B starts at node 50 (shared junction). A's driven
      // interval stops 10m short of A's end; B's starts 10m in. After stitch,
      // A's last point == A.geom.last and B's first == B.geom.first (== node).
      final a = ewWay(lat: 49, lonStart: 9, points: 3, nodeIds: [48, 49, 50]);
      final b = ewWay(lat: 49, lonStart: 9.002, points: 3, nodeIds: [50, 51, 52]);
      final aFull = polylineLengthMeters(a.geom);
      final out = clipDrivenWays(
        unionByWayId: {
          1: [(0, aFull - 10)], // stops 10m short of shared node
          2: [(10, polylineLengthMeters(b.geom))], // starts 10m in
        },
        geomByWayId: {1: a.geom, 2: b.geom},
        nodesByWayId: {1: a.nodes, 2: b.nodes},
      );
      final aSeg = out.firstWhere((c) => c.wayId == 1);
      final bSeg = out.firstWhere((c) => c.wayId == 2);
      // A's last point snapped to A.geom.last (the shared node coord); B's
      // first snapped to B.geom.first (same coord). They meet exactly.
      expect(aSeg.geometry.last.latitude, closeTo(a.geom.last.latitude, 1e-9));
      expect(aSeg.geometry.last.longitude, closeTo(a.geom.last.longitude, 1e-9));
      expect(bSeg.geometry.first.latitude, closeTo(b.geom.first.latitude, 1e-9));
      expect(
          bSeg.geometry.first.longitude, closeTo(b.geom.first.longitude, 1e-9));
      // And the two meeting points are identical (shared junction node).
      expect(aSeg.geometry.last.longitude,
          closeTo(bSeg.geometry.first.longitude, 1e-9));
    });
  });

  group('clipDrivenWays — over-draw guard', () {
    test('LONG bridging way driven only in the middle is NOT full-drawn', () {
      // Way M: ~292m (5 pts). Bridges A (start node 60) and B (end node 64),
      // but was only driven in the MIDDLE [75..125]. full > connector cap (80),
      // so CONNECTOR-CLOSE must NOT fire — only the middle ~50m is drawn.
      final m = ewWay(lat: 49, lonStart: 9, points: 5, nodeIds: [60, 61, 62, 63, 64]);
      final a = ewWay(lat: 49, lonStart: 8.999, points: 2, nodeIds: [59, 60]);
      final b = ewWay(lat: 49, lonStart: 9.004, points: 2, nodeIds: [64, 65]);
      final out = clipDrivenWays(
        unionByWayId: {
          1: [(75, 125)], // middle only
          2: [(0, 73)],
          3: [(0, 73)],
        },
        geomByWayId: {1: m.geom, 2: a.geom, 3: b.geom},
        nodesByWayId: {1: m.nodes, 2: a.nodes, 3: b.nodes},
      );
      final mSegs = out.where((c) => c.wayId == 1).toList();
      expect(mSegs, isNotEmpty);
      final drawn =
          mSegs.fold<double>(0, (a, c) => a + polylineLengthMeters(c.geometry));
      final full = polylineLengthMeters(m.geom);
      expect(drawn, lessThan(full * 0.5),
          reason: 'long bridging way driven mid-span must NOT be full-drawn '
              '(no over-draw of the undriven ends)');
    });
  });
}
