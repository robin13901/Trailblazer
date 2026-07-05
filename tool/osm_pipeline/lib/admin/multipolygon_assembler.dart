/// Assemble an OSM multipolygon relation into a [MultiPolygon].
///
/// Handles fragment stitching (outer/inner ways rarely arrive pre-closed),
/// winding correction (outer CCW, inner CW), self-intersection detection,
/// and inner→outer nesting.
///
/// Skip-log-continue error handling per 04-CONTEXT: malformed rings are
/// written to a `skippedLog` and dropped, never thrown.
library;

import 'dart:io';

import 'package:osm_pipeline/admin/geometry.dart';
import 'package:osm_pipeline/pbf/entities.dart';

/// Node lookup shape used by the assembler — resolves an OSM node id to a
/// lat/lng tuple.
typedef NodeLookup = ({double lat, double lng}) Function(int nodeId);

/// A resolved lat/lng lookup that returns null when the node is unknown.
typedef NullableNodeLookup = ({double lat, double lng})? Function(int nodeId);

/// Assembler entrypoint — pure functions, no state.
class MultipolygonAssembler {
  MultipolygonAssembler._();

  /// Assemble [relation] into a [MultiPolygon].
  ///
  /// Returns `null` when the relation yields zero valid rings. All errors,
  /// missing refs, self-intersections, and orphan inner rings are appended
  /// to [skippedLog] with the relation id for traceability.
  static MultiPolygon? assemble(
    OsmRelation relation,
    Map<int, OsmWay> waysById,
    NullableNodeLookup nodeLookup,
    IOSink? skippedLog,
  ) {
    final outerWayIds = <int>[];
    final innerWayIds = <int>[];
    for (final m in relation.members) {
      if (m.type != OsmMemberType.way) continue;
      // OSM convention: empty role defaults to `outer` for a multipolygon.
      if (m.role == 'inner') {
        innerWayIds.add(m.refId);
      } else if (m.role == 'outer' || m.role.isEmpty) {
        outerWayIds.add(m.refId);
      } // Anything else (e.g. `admin_centre`, `label`) — ignore.
    }

    final outerFragments = _resolveFragments(
      relation.id,
      outerWayIds,
      waysById,
      nodeLookup,
      skippedLog,
    );
    final innerFragments = _resolveFragments(
      relation.id,
      innerWayIds,
      waysById,
      nodeLookup,
      skippedLog,
    );

    final outerRings = _stitchRings(
      relation.id,
      outerFragments,
      roleLabel: 'outer',
      skippedLog: skippedLog,
    );
    final innerRings = _stitchRings(
      relation.id,
      innerFragments,
      roleLabel: 'inner',
      skippedLog: skippedLog,
    );

    // Winding correction + self-intersection filter.
    final cleanOuters = <List<Point>>[];
    for (final ring in outerRings) {
      if (hasSelfIntersection(ring)) {
        _log(
          skippedLog,
          'SKIP relation ${relation.id}: self-intersecting outer ring',
        );
        continue;
      }
      if (!isCounterClockwise(ring)) reverseRingInPlace(ring);
      cleanOuters.add(ring);
    }
    final cleanInners = <List<Point>>[];
    for (final ring in innerRings) {
      if (hasSelfIntersection(ring)) {
        _log(
          skippedLog,
          'SKIP relation ${relation.id}: self-intersecting inner ring',
        );
        continue;
      }
      if (isCounterClockwise(ring)) reverseRingInPlace(ring);
      cleanInners.add(ring);
    }

    if (cleanOuters.isEmpty) return null;

    // Bucket inners into their containing outer — smallest containing outer
    // wins when multiple outers contain the same inner (nested outers).
    final polygons = <Polygon>[
      for (final o in cleanOuters) Polygon(outer: o, holes: []),
    ];
    for (final inner in cleanInners) {
      // Use any vertex of the inner for the containment test — a well-formed
      // inner is entirely inside its outer, so one point suffices.
      final probe = inner.first;
      var winnerIdx = -1;
      var winnerExtent = double.infinity;
      for (var i = 0; i < cleanOuters.length; i++) {
        if (pointInRing(probe, cleanOuters[i])) {
          final ext = ringExtent(cleanOuters[i]);
          if (ext < winnerExtent) {
            winnerExtent = ext;
            winnerIdx = i;
          }
        }
      }
      if (winnerIdx == -1) {
        _log(
          skippedLog,
          'SKIP relation ${relation.id}: inner ring lies outside every outer',
        );
        continue;
      }
      final old = polygons[winnerIdx];
      polygons[winnerIdx] = Polygon(
        outer: old.outer,
        holes: [...old.holes, inner],
      );
    }

    return MultiPolygon(polygons);
  }

  static List<_Fragment> _resolveFragments(
    int relationId,
    List<int> wayIds,
    Map<int, OsmWay> waysById,
    NullableNodeLookup nodeLookup,
    IOSink? skippedLog,
  ) {
    final out = <_Fragment>[];
    for (final wid in wayIds) {
      final way = waysById[wid];
      if (way == null) {
        _log(
          skippedLog,
          'SKIP relation $relationId: missing member way $wid '
          '(deleted-node cascade or truncated PBF)',
        );
        continue;
      }
      final points = <Point>[];
      var abort = false;
      for (final nid in way.nodeRefs) {
        final coord = nodeLookup(nid);
        if (coord == null) {
          _log(
            skippedLog,
            'SKIP relation $relationId: missing node $nid on way $wid',
          );
          abort = true;
          break;
        }
        points.add(Point(coord.lng, coord.lat));
      }
      if (abort || points.length < 2) continue;
      out.add(_Fragment(wid, points));
    }
    return out;
  }

  /// Stitch open fragments into closed rings.
  ///
  /// Repeats: pop an unused fragment; walk both ends looking for another
  /// fragment that starts or ends at the current tip; append (reversing if
  /// needed) until the tip equals the tail — a closed ring. If no matching
  /// fragment mid-walk, log and drop the partial ring.
  static List<List<Point>> _stitchRings(
    int relationId,
    List<_Fragment> fragments, {
    required String roleLabel,
    required IOSink? skippedLog,
  }) {
    final rings = <List<Point>>[];
    final used = List<bool>.filled(fragments.length, false);
    for (var seed = 0; seed < fragments.length; seed++) {
      if (used[seed]) continue;
      used[seed] = true;
      final ring = List<Point>.from(fragments[seed].points);
      // Walk forward from ring.last.
      var closed = ring.first.equalsCoord(ring.last);
      while (!closed) {
        final tip = ring.last;
        var extended = false;
        for (var i = 0; i < fragments.length; i++) {
          if (used[i]) continue;
          final frag = fragments[i].points;
          if (frag.first.equalsCoord(tip)) {
            ring.addAll(frag.skip(1));
            used[i] = true;
            extended = true;
            break;
          }
          if (frag.last.equalsCoord(tip)) {
            for (var k = frag.length - 2; k >= 0; k--) {
              ring.add(frag[k]);
            }
            used[i] = true;
            extended = true;
            break;
          }
        }
        if (!extended) {
          _log(
            skippedLog,
            'SKIP relation $relationId: broken $roleLabel ring (no fragment '
            'meets tip at ${tip.lng},${tip.lat})',
          );
          break;
        }
        closed = ring.first.equalsCoord(ring.last);
      }
      if (closed) {
        rings.add(ring);
      }
    }
    return rings;
  }
}

class _Fragment {
  const _Fragment(this.wayId, this.points);
  final int wayId;
  final List<Point> points;
}

void _log(IOSink? sink, String line) {
  if (sink == null) return;
  sink.writeln(line);
}
