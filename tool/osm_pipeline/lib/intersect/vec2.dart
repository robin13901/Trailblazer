/// Plain 2D lat/lng primitives for the segmented-intersection stage (04-05).
///
/// Kept dependency-free so `Vec2` and the segment/ring helpers can be reused
/// by `polygon_clip.dart` and the future R-Tree builder without pulling in
/// `dart:ui` `Offset`/`Rect` or a package geometry lib.
///
/// Coordinates are lat/lng WGS84 decimal degrees. Distances use the
/// haversine formula — sub-metre precision at 51°N is fine at REAL doubles.
library;

import 'dart:math' as math;

/// Approximate mean Earth radius in metres. WGS84 authalic radius.
const double kEarthRadiusMeters = 6371008.8;

/// A single lng/lat point in 2D lat/lng space.
///
/// Deliberately not `@immutable` — the clipper builds hundreds of thousands
/// of these per way and holds them in mutable segment lists; the annotation
/// would just add noise. Fields are `final` at the class level.
class Vec2 {
  /// Create a point.
  const Vec2(this.lng, this.lat);

  /// Longitude in decimal degrees.
  final double lng;

  /// Latitude in decimal degrees.
  final double lat;

  @override
  String toString() => 'Vec2($lng, $lat)';

  /// Coordinate equality — tolerant to double round-trip.
  bool equalsCoord(Vec2 other, {double eps = 1e-12}) =>
      (other.lng - lng).abs() < eps && (other.lat - lat).abs() < eps;
}

/// Great-circle distance between [a] and [b] in metres.
///
/// The Berlin-bbox smoke workload calls this billions of times — kept as a
/// single-branch straight-line function, no allocation.
double haversineMeters(Vec2 a, Vec2 b) {
  const toRad = math.pi / 180.0;
  final phi1 = a.lat * toRad;
  final phi2 = b.lat * toRad;
  final dPhi = (b.lat - a.lat) * toRad;
  final dLam = (b.lng - a.lng) * toRad;
  final s = math.sin(dPhi / 2.0);
  final t = math.sin(dLam / 2.0);
  final h = s * s + math.cos(phi1) * math.cos(phi2) * t * t;
  return 2.0 * kEarthRadiusMeters * math.asin(math.min(1.0, math.sqrt(h)));
}

/// The result of intersecting two line segments.
class SegmentIntersection {
  /// Create an intersection descriptor.
  const SegmentIntersection({
    required this.point,
    required this.tA,
    required this.tB,
    required this.collinear,
  });

  /// The intersection point in the shared lat/lng frame.
  final Vec2 point;

  /// Parameter along segment A: `a1 + tA * (a2 - a1)`, in `[0, 1]`.
  final double tA;

  /// Parameter along segment B: `b1 + tB * (b2 - b1)`, in `[0, 1]`.
  final double tB;

  /// True when the segments are collinear (overlap along a shared line).
  ///
  /// The reported [point] in that case is the collinear-overlap midpoint;
  /// callers that care about extent must probe both endpoints separately.
  final bool collinear;
}

/// Compute the intersection (if any) of segment `a1→a2` with `b1→b2`.
///
/// Returns null when the segments do not intersect. Endpoint touches count
/// as intersections (returned with `tA` or `tB` at 0 or 1).
///
/// Collinear-overlap case returns a descriptor with `collinear: true` and a
/// representative point at the midpoint of the overlap (see field docs).
SegmentIntersection? segmentIntersection(
  Vec2 a1,
  Vec2 a2,
  Vec2 b1,
  Vec2 b2, {
  double eps = 1e-12,
}) {
  final rx = a2.lng - a1.lng;
  final ry = a2.lat - a1.lat;
  final sx = b2.lng - b1.lng;
  final sy = b2.lat - b1.lat;
  final denom = rx * sy - ry * sx;
  final qmpX = b1.lng - a1.lng;
  final qmpY = b1.lat - a1.lat;

  if (denom.abs() < eps) {
    // Parallel. Collinear iff the cross product of (b1-a1) and r is zero.
    final crossQR = qmpX * ry - qmpY * rx;
    if (crossQR.abs() >= eps) return null;

    // Project onto r to find overlap parameters (in the a1..a2 frame).
    final rDotR = rx * rx + ry * ry;
    if (rDotR < eps) return null; // degenerate segment A
    final t0 = (qmpX * rx + qmpY * ry) / rDotR;
    final t1 = ((qmpX + sx) * rx + (qmpY + sy) * ry) / rDotR;
    final tMin = math.min(t0, t1);
    final tMax = math.max(t0, t1);
    final loA = math.max<double>(0, tMin);
    final hiA = math.min<double>(1, tMax);
    if (loA > hiA + eps) return null;
    final tA = 0.5 * (loA + hiA);
    // Represent tB via the same overlap midpoint, mapped back into b.
    final ix = a1.lng + tA * rx;
    final iy = a1.lat + tA * ry;
    final sDotS = sx * sx + sy * sy;
    final tB = sDotS < eps
        ? 0.0
        : ((ix - b1.lng) * sx + (iy - b1.lat) * sy) / sDotS;
    return SegmentIntersection(
      point: Vec2(ix, iy),
      tA: tA,
      tB: tB,
      collinear: true,
    );
  }

  final tA = (qmpX * sy - qmpY * sx) / denom;
  final tB = (qmpX * ry - qmpY * rx) / denom;
  if (tA < -eps || tA > 1.0 + eps) return null;
  if (tB < -eps || tB > 1.0 + eps) return null;
  final clampedA = tA.clamp(0.0, 1.0);
  return SegmentIntersection(
    point: Vec2(a1.lng + clampedA * rx, a1.lat + clampedA * ry),
    tA: clampedA,
    tB: tB.clamp(0.0, 1.0),
    collinear: false,
  );
}

/// Ray-cast point-in-polygon test.
///
/// [ring] must be closed (first == last). Boundary points return true —
/// the tie-break "left-of-line" logic in polygon_clip handles the ambiguous
/// case by nudging the sample point off the boundary before probing.
bool pointInRing(Vec2 p, List<Vec2> ring) {
  var inside = false;
  final n = ring.length;
  if (n < 2) return false;
  // Iterate segments (i, j=i-1 wrapping via the closing repeat).
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final xi = ring[i].lng;
    final yi = ring[i].lat;
    final xj = ring[j].lng;
    final yj = ring[j].lat;
    if ((yi > p.lat) != (yj > p.lat)) {
      final dy = yj - yi;
      final xCross = xi + (xj - xi) * (p.lat - yi) / (dy == 0 ? 1e-30 : dy);
      if (p.lng < xCross) inside = !inside;
    }
  }
  return inside;
}
