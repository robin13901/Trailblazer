/// Linestring-vs-multipolygon clipper for the segmented-intersection stage.
///
/// See 04-05-PLAN.md Task 1 + 04-RESEARCH.md §7.
///
/// The clipper returns disjoint sub-linestrings covering the portion of the
/// input line that lies INSIDE the polygon (outer ring minus inner rings).
/// Each sub-linestring carries fractional `fractionStart` / `fractionEnd`
/// positions along the source line — enough for Phase 8 coverage math
/// without storing sub-geometries.
///
/// Correctness contract (per 04-RESEARCH §7):
///   * Enter / exit / re-enter is supported — produces multiple subsegments.
///   * Coincident-edge tie-break: the line, when coincident with a polygon
///     edge, is treated as being on the LEFT side of that edge (relative to
///     the line's own direction of travel). See `_isPointInsidePolygon` and
///     the inside-flag state machine below.
///   * Epsilon-clip: sub-linestrings whose accumulated haversine length is
///     less than `epsilonMeters` are dropped.
///   * Inner rings are subtracted from their containing outer.
library;

import 'dart:math' as math;

import 'package:osm_pipeline/intersect/vec2.dart';

/// One connected inside-sub-linestring produced by [clipLinestringToPolygon].
class Subsegment {
  /// Create a subsegment.
  const Subsegment({
    required this.points,
    required this.fractionStart,
    required this.fractionEnd,
  });

  /// The subsegment vertices (in original line direction). Length >= 2.
  final List<Vec2> points;

  /// Position along the source line where this subsegment begins, in `[0,1]`.
  final double fractionStart;

  /// Position along the source line where this subsegment ends, in `[0,1]`.
  final double fractionEnd;
}

/// A polygon shape usable by [clipLinestringToPolygon].
///
/// One outer ring (CCW-oriented) plus zero or more inner rings (CW-oriented),
/// each ring closed (first point == last point).
class ClipPolygon {
  /// Create a polygon.
  const ClipPolygon({required this.outer, this.holes = const []});

  /// Outer ring.
  final List<Vec2> outer;

  /// Inner rings (holes).
  final List<List<Vec2>> holes;
}

/// A multi-polygon usable by [clipLinestringToPolygon].
class ClipMultiPolygon {
  /// Create a multi-polygon.
  const ClipMultiPolygon(this.polygons);

  /// The contained polygons.
  final List<ClipPolygon> polygons;
}

/// Clip [line] against [polygon]. Returns the inside-sub-linestrings, sorted
/// in line-order.
///
/// Empty [line], empty polygons, or an all-outside line returns an
/// empty list. Subsegments shorter than [epsilonMeters] are dropped.
List<Subsegment> clipLinestringToPolygon(
  List<Vec2> line,
  ClipMultiPolygon polygon, {
  double epsilonMeters = 1.0,
}) {
  if (line.length < 2 || polygon.polygons.isEmpty) return const [];

  // 1. Compute cumulative haversine distance along [line]. cumDist[i] is the
  //    accumulated length up to (and including) line[i]; cumDist[last] is the
  //    total length.
  final n = line.length;
  final cumDist = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    cumDist[i] = cumDist[i - 1] + haversineMeters(line[i - 1], line[i]);
  }
  final totalLen = cumDist[n - 1];
  if (totalLen == 0) return const [];

  // 2. Walk each source segment. Compute intersection parameters against
  //    every polygon edge (outer + inners), sort by tA, and split the segment
  //    at those parameters. Each resulting sub-segment is either fully inside
  //    the polygon or fully outside; midpoint probe decides.
  //
  //    We accumulate inside sub-segments across source-segment boundaries so
  //    the caller gets one Subsegment per connected inside run — not one per
  //    source segment.
  final subsegments = <Subsegment>[];
  var openPoints = <Vec2>[];
  var openStartMeters = 0.0;

  void closeOpenIfAny(double endMeters) {
    if (openPoints.isEmpty) return;
    final segLen = endMeters - openStartMeters;
    if (segLen >= epsilonMeters && openPoints.length >= 2) {
      subsegments.add(
        Subsegment(
          points: openPoints,
          fractionStart: openStartMeters / totalLen,
          fractionEnd: endMeters / totalLen,
        ),
      );
    }
    openPoints = <Vec2>[];
  }

  for (var i = 0; i < n - 1; i++) {
    final a = line[i];
    final b = line[i + 1];
    final segLen = cumDist[i + 1] - cumDist[i];
    if (segLen == 0) continue;

    // Collect all intersection parameters tA in [0..1] along a→b.
    final events = <_ClipEvent>[
      const _ClipEvent(t: 0),
      const _ClipEvent(t: 1),
    ];
    _collectRingIntersections(a, b, polygon, events);

    events.sort((x, y) => x.t.compareTo(y.t));
    // Deduplicate near-equal ts to avoid zero-length probes.
    final unique = <double>[];
    for (final e in events) {
      if (unique.isEmpty || (e.t - unique.last).abs() > 1e-12) {
        unique.add(e.t);
      }
    }

    for (var k = 0; k < unique.length - 1; k++) {
      final t0 = unique[k];
      final t1 = unique[k + 1];
      final startPt = _interpolate(a, b, t0);
      final endPt = _interpolate(a, b, t1);
      final startMeters = cumDist[i] + t0 * segLen;
      final midT = 0.5 * (t0 + t1);
      final midPt = _interpolate(a, b, midT);
      // Coincident-edge tie-break (04-RESEARCH §7): nudge the probe point a
      // tiny perpendicular step to the LEFT of the source-line direction
      // before running the inside test. A line running exactly along the
      // polygon boundary is then classified by which side of the line the
      // polygon interior lies on.
      final nudged = _nudgeLeft(a, b, midPt);
      final inside = _isPointInsidePolygon(nudged, polygon);
      if (inside) {
        if (openPoints.isEmpty) {
          openPoints.add(startPt);
          openStartMeters = startMeters;
        }
        // Only append endPt if it differs from the tip.
        final tip = openPoints.last;
        if (!tip.equalsCoord(endPt)) {
          openPoints.add(endPt);
        }
      } else {
        closeOpenIfAny(startMeters);
      }
    }
  }
  closeOpenIfAny(totalLen);

  return subsegments;
}

class _ClipEvent {
  const _ClipEvent({required this.t});
  final double t;
}

Vec2 _interpolate(Vec2 a, Vec2 b, double t) =>
    Vec2(a.lng + (b.lng - a.lng) * t, a.lat + (b.lat - a.lat) * t);

void _collectRingIntersections(
  Vec2 a,
  Vec2 b,
  ClipMultiPolygon polygon,
  List<_ClipEvent> out,
) {
  for (final poly in polygon.polygons) {
    _collectForRing(a, b, poly.outer, out);
    for (final hole in poly.holes) {
      _collectForRing(a, b, hole, out);
    }
  }
}

void _collectForRing(Vec2 a, Vec2 b, List<Vec2> ring, List<_ClipEvent> out) {
  final n = ring.length;
  if (n < 2) return;
  for (var i = 0; i < n - 1; i++) {
    final r1 = ring[i];
    final r2 = ring[i + 1];
    final hit = segmentIntersection(a, b, r1, r2);
    if (hit == null) continue;
    // For collinear-overlap, add BOTH ends of the overlap so the state
    // machine can decide inside/outside using midpoint probes on either side.
    if (hit.collinear) {
      // Recover both endpoint parameters along a→b for the overlap.
      final r1t = _paramOnAB(a, b, r1);
      final r2t = _paramOnAB(a, b, r2);
      final t0 = math.min(r1t, r2t);
      final t1 = math.max(r1t, r2t);
      if (t0 > 0 && t0 < 1) out.add(_ClipEvent(t: t0));
      if (t1 > 0 && t1 < 1) out.add(_ClipEvent(t: t1));
    } else {
      if (hit.tA > 0 && hit.tA < 1) out.add(_ClipEvent(t: hit.tA));
    }
  }
}

double _paramOnAB(Vec2 a, Vec2 b, Vec2 p) {
  final rx = b.lng - a.lng;
  final ry = b.lat - a.lat;
  final rDotR = rx * rx + ry * ry;
  if (rDotR == 0) return 0;
  return ((p.lng - a.lng) * rx + (p.lat - a.lat) * ry) / rDotR;
}

bool _isPointInsidePolygon(Vec2 p, ClipMultiPolygon polygon) {
  for (final poly in polygon.polygons) {
    if (!pointInRing(p, poly.outer)) continue;
    var inHole = false;
    for (final hole in poly.holes) {
      if (pointInRing(p, hole)) {
        inHole = true;
        break;
      }
    }
    if (!inHole) return true;
  }
  return false;
}

/// Nudge [midPt] a tiny perpendicular step to the LEFT of the direction
/// vector `a → b`. In lat/lng-frame (x=lng, y=lat), rotating (dx, dy) by
/// +90° gives (-dy, dx). The magnitude is tiny relative to typical polygon
/// scale so it never crosses a nearby edge unrelated to the tie-break.
Vec2 _nudgeLeft(Vec2 a, Vec2 b, Vec2 midPt) {
  final dx = b.lng - a.lng;
  final dy = b.lat - a.lat;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) return midPt;
  // ~1e-10 degrees == ~1 cm at the equator — well below our 1 m epsilon.
  const step = 1e-10;
  final nx = -dy / len * step;
  final ny = dx / len * step;
  return Vec2(midPt.lng + nx, midPt.lat + ny);
}
