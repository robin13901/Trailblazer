// Trailblazer 2026-07-18 (route-aware transition):
// NodeGraph — an in-memory routing graph over the candidate ways of ONE trip,
// keyed by OSM node id (or the coordinate-hash surrogate from WaySegment when
// ids are absent). Built once per trip alongside WaySegmentIndex.
//
// Purpose: give the Viterbi decoder a REAL on-road distance between two
// candidate projection points, replacing the old `routeDist = gc * 1.4`
// constant (which carried no topology and degenerated the transition term to a
// no-op — the root cause of the triangle/fan/zigzag artifacts). Two segments
// meet iff they share a node id, so adjacency is exact — no coordinate-radius
// guessing.
//
// The graph is UNDIRECTED for routing purposes (one-way legality is scored
// separately in the emission/transition penalties, not by pruning the graph):
// a bounded shortest-path just needs to know whether two points are reachable
// on tarmac within a sane distance, and by how much. Vertices are OSM nodes;
// edges are way segments carrying their metric length.
//
// Pure Dart — no Drift, no Flutter, no isolate API. Safe on the matcher isolate.

import 'dart:collection';

import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:collection/collection.dart';

/// One directed half of an undirected graph edge: from an implicit source node
/// to [toNode], along way [wayId] segment [segIdx], costing [lengthMeters].
class NodeEdge {
  const NodeEdge({
    required this.toNode,
    required this.wayId,
    required this.segIdx,
    required this.lengthMeters,
  });

  final int toNode;
  final int wayId;
  final int segIdx;
  final double lengthMeters;
}

/// Adjacency graph over the trip's candidate ways, keyed by node id.
///
/// Build via [NodeGraph.fromWays]; query reachable route distance via
/// [routeDistanceMeters]. All distances are metric (equirectangular
/// [segmentLengthMeters], consistent with the rest of the matcher).
class NodeGraph {
  NodeGraph._(this._adj, this._segLen);

  /// Build the graph from the same [WayCandidate] list the matcher indexes.
  ///
  /// Each way segment becomes an undirected edge between its two node ids
  /// (`aNodeId`/`bNodeId` from [WaySegment.fromWay], which already falls back
  /// to a coordinate-hash surrogate when OSM ids are absent). Duplicate edges
  /// (a node pair connected by more than one segment) are all kept — the
  /// shortest is naturally preferred by the search.
  factory NodeGraph.fromWays(List<WayCandidate> ways) {
    final adj = <int, List<NodeEdge>>{};
    final segLen = <(int, int), double>{};
    for (final w in ways) {
      for (final s in WaySegment.fromWay(w)) {
        final len = segmentLengthMeters(
          aLat: s.aLat,
          aLon: s.aLon,
          bLat: s.bLat,
          bLon: s.bLon,
        );
        segLen[(s.wayId, s.segIdx)] = len;
        (adj[s.aNodeId] ??= []).add(
          NodeEdge(
            toNode: s.bNodeId,
            wayId: s.wayId,
            segIdx: s.segIdx,
            lengthMeters: len,
          ),
        );
        (adj[s.bNodeId] ??= []).add(
          NodeEdge(
            toNode: s.aNodeId,
            wayId: s.wayId,
            segIdx: s.segIdx,
            lengthMeters: len,
          ),
        );
      }
    }
    return NodeGraph._(adj, segLen);
  }

  /// nodeId → outgoing edges.
  final Map<int, List<NodeEdge>> _adj;

  /// (wayId, segIdx) → segment metric length, for adding partial-segment stubs
  /// at the two ends of a route query without recomputing geometry.
  final Map<(int, int), double> _segLen;

  /// Metric length of segment (wayId, segIdx), or 0 when unknown.
  double segmentLength(int wayId, int segIdx) => _segLen[(wayId, segIdx)] ?? 0;

  /// Bounded shortest on-road distance (meters) between two candidate
  /// projection points, or `null` when no path exists within [maxMeters].
  ///
  /// A candidate is a point at [fromFraction] along segment
  /// (`fromWayId`,`fromSegIdx`) and similarly for the target. The search runs a
  /// Dijkstra over node ids seeded from BOTH endpoints of the source segment
  /// (offset by the partial-segment stub distance to the projection point), and
  /// terminates when it settles either endpoint of the target segment; the
  /// matching target stub is then added. Expansion stops once the best label
  /// exceeds [maxMeters], so the search touches only a small neighbourhood —
  /// consecutive GPS fixes are seconds apart, so the true route is short.
  ///
  /// Same-segment case (both candidates on the same wayId+segIdx) is answered
  /// directly as the along-segment distance, no search.
  double? routeDistanceMeters({
    required int fromWayId,
    required int fromSegIdx,
    required double fromFraction,
    required int fromANode,
    required int fromBNode,
    required int toWayId,
    required int toSegIdx,
    required double toFraction,
    required int toANode,
    required int toBNode,
    required double maxMeters,
  }) {
    final fromLen = segmentLength(fromWayId, fromSegIdx);
    final toLen = segmentLength(toWayId, toSegIdx);

    // Same physical segment: distance is just the along-segment delta.
    if (fromWayId == toWayId && fromSegIdx == toSegIdx) {
      return ((toFraction - fromFraction).abs()) * fromLen;
    }

    // Distance from the source projection point to each end of its segment.
    final srcToA = fromFraction * fromLen; // back toward node A
    final srcToB = (1 - fromFraction) * fromLen; // forward toward node B
    // Distance from each end of the target segment to the target point.
    final aToTgt = toFraction * toLen;
    final bToTgt = (1 - toFraction) * toLen;

    // Dijkstra seeded from both source-segment endpoints.
    final dist = HashMap<int, double>();
    final pq = HeapPriorityQueue<(double, int)>(
      (a, b) => a.$1.compareTo(b.$1),
    );
    void seed(int node, double d) {
      if (d > maxMeters) return;
      final existing = dist[node];
      if (existing == null || d < existing) {
        dist[node] = d;
        pq.add((d, node));
      }
    }

    seed(fromANode, srcToA);
    seed(fromBNode, srcToB);

    var best = double.infinity;
    while (pq.isNotEmpty) {
      final (d, node) = pq.removeFirst();
      if (d > (dist[node] ?? double.infinity)) continue; // stale
      if (d > maxMeters) break; // frontier beyond cap — nothing closer remains

      // Reached a target-segment endpoint? Fold in the target stub.
      if (node == toANode) {
        final total = d + aToTgt;
        if (total < best) best = total;
      }
      if (node == toBNode) {
        final total = d + bToTgt;
        if (total < best) best = total;
      }

      final edges = _adj[node];
      if (edges == null) continue;
      for (final e in edges) {
        final nd = d + e.lengthMeters;
        if (nd > maxMeters) continue;
        final existing = dist[e.toNode];
        if (existing == null || nd < existing) {
          dist[e.toNode] = nd;
          pq.add((nd, e.toNode));
        }
      }
    }

    if (best.isFinite && best <= maxMeters) return best;
    return null;
  }
}
