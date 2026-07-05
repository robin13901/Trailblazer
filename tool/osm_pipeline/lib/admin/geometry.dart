/// Value types for assembled multipolygon geometries.
///
/// Kept dependency-free so the assembler and the WKB writer can share them
/// without pulling in `dart:ui` `Offset`/`Rect` or any package geometry lib.
/// See 04-04-PLAN.md Task 2.
library;

import 'dart:math' as math;

/// A single lat/lng vertex.
///
/// Deliberately not `@immutable` — pipeline creates thousands per relation
/// and holds them in mutable ring lists; annotation would just be noise.
class Point {
  /// Create a point.
  const Point(this.lng, this.lat);

  /// Longitude in decimal degrees.
  final double lng;

  /// Latitude in decimal degrees.
  final double lat;

  @override
  String toString() => 'Point($lng, $lat)';

  /// Structural equality — used by the fragment stitcher to detect
  /// endpoint matches. Two points are equal iff their lat AND lng match.
  bool equalsCoord(Point other) => other.lng == lng && other.lat == lat;
}

/// One polygon = one outer ring + zero or more inner rings (holes).
class Polygon {
  /// Create a polygon. Rings are lists of points with the first == last.
  const Polygon({required this.outer, this.holes = const []});

  /// Outer ring, CCW-oriented, first point == last point.
  final List<Point> outer;

  /// Zero or more inner rings, CW-oriented, first point == last point.
  final List<List<Point>> holes;
}

/// A collection of polygons. WKB-serialisable via `wkb_writer.dart`.
class MultiPolygon {
  /// Create a multi-polygon.
  const MultiPolygon(this.polygons);

  /// The contained polygons (may be empty).
  final List<Polygon> polygons;

  /// True iff [polygons] is empty.
  bool get isEmpty => polygons.isEmpty;

  /// True iff [polygons] is non-empty.
  bool get isNotEmpty => polygons.isNotEmpty;

  /// Computes the lat/lng bounding box in one pass.
  ///
  /// Returns a record `(minLat, maxLat, minLng, maxLng)`. Throws
  /// [StateError] on an empty multi-polygon (bbox undefined).
  ({double minLat, double maxLat, double minLng, double maxLng}) bbox() {
    if (polygons.isEmpty) {
      throw StateError('bbox() on empty MultiPolygon');
    }
    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    var minLng = double.infinity;
    var maxLng = double.negativeInfinity;
    for (final poly in polygons) {
      for (final p in poly.outer) {
        if (p.lat < minLat) minLat = p.lat;
        if (p.lat > maxLat) maxLat = p.lat;
        if (p.lng < minLng) minLng = p.lng;
        if (p.lng > maxLng) maxLng = p.lng;
      }
      for (final hole in poly.holes) {
        for (final p in hole) {
          if (p.lat < minLat) minLat = p.lat;
          if (p.lat > maxLat) maxLat = p.lat;
          if (p.lng < minLng) minLng = p.lng;
          if (p.lng > maxLng) maxLng = p.lng;
        }
      }
    }
    return (
      minLat: minLat,
      maxLat: maxLat,
      minLng: minLng,
      maxLng: maxLng,
    );
  }
}

/// Signed shoelace area of a ring (2 × real area, in degrees²).
///
/// Positive when the ring is CCW in a standard `x = lng, y = lat` frame,
/// negative when CW. The ring must be closed (first == last).
double signedRingArea(List<Point> ring) {
  var sum = 0.0;
  for (var i = 0; i < ring.length - 1; i++) {
    final a = ring[i];
    final b = ring[i + 1];
    sum += a.lng * b.lat - b.lng * a.lat;
  }
  return sum / 2.0;
}

/// True iff [ring] is oriented counter-clockwise (signed area > 0).
bool isCounterClockwise(List<Point> ring) => signedRingArea(ring) > 0;

/// Ray-cast point-in-polygon test.
///
/// [ring] must be closed. Returns true when the point is strictly inside
/// or on the boundary. Deterministic — good enough for the "does this
/// inner ring lie inside that outer ring?" bucketing in the assembler.
bool pointInRing(Point p, List<Point> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].lng;
    final yi = ring[i].lat;
    final xj = ring[j].lng;
    final yj = ring[j].lat;
    final intersect = (yi > p.lat) != (yj > p.lat) &&
        p.lng <
            (xj - xi) * (p.lat - yi) / ((yj - yi) == 0 ? 1e-30 : (yj - yi)) +
                xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

/// True iff any two non-adjacent segments of [ring] cross.
///
/// O(N²) — acceptable for admin rings with thousands of vertices, unacceptable
/// for degenerate 100k-vertex rings (see 04-04-PLAN.md Deviation Handling).
///
/// [ring] must be closed (first == last).
bool hasSelfIntersection(List<Point> ring) {
  final n = ring.length - 1; // skip the closing repeat
  if (n < 4) return false;
  for (var i = 0; i < n; i++) {
    final a1 = ring[i];
    final a2 = ring[i + 1];
    for (var j = i + 2; j < n; j++) {
      // Skip adjacent segments (shared endpoints don't count as crossings).
      if (i == 0 && j == n - 1) continue;
      final b1 = ring[j];
      final b2 = ring[j + 1];
      if (_segmentsProperlyIntersect(a1, a2, b1, b2)) return true;
    }
  }
  return false;
}

// Segment (a1,a2) properly crosses segment (b1,b2) — strict interior crossing,
// endpoint touches do not count.
bool _segmentsProperlyIntersect(Point a1, Point a2, Point b1, Point b2) {
  final d1 = _cross(b2.lng - b1.lng, b2.lat - b1.lat, a1.lng - b1.lng,
      a1.lat - b1.lat,);
  final d2 = _cross(b2.lng - b1.lng, b2.lat - b1.lat, a2.lng - b1.lng,
      a2.lat - b1.lat,);
  final d3 = _cross(a2.lng - a1.lng, a2.lat - a1.lat, b1.lng - a1.lng,
      b1.lat - a1.lat,);
  final d4 = _cross(a2.lng - a1.lng, a2.lat - a1.lat, b2.lng - a1.lng,
      b2.lat - a1.lat,);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

double _cross(double ax, double ay, double bx, double by) => ax * by - ay * bx;

/// Reverses [ring] in place. Preserves the closing repeat.
void reverseRingInPlace(List<Point> ring) {
  // Reverse everything except the closing repeat (which becomes the new first,
  // and needs to equal the new last for the ring to remain closed — which it
  // does because the closing repeat == the original first).
  final n = ring.length;
  for (var i = 0, j = n - 1; i < j; i++, j--) {
    final tmp = ring[i];
    ring[i] = ring[j];
    ring[j] = tmp;
  }
}

/// Approximate ring "size" in degrees — used only as a heuristic tiebreak
/// when bucketing inners into outers (smallest containing outer wins).
double ringExtent(List<Point> ring) {
  var minLat = double.infinity;
  var maxLat = double.negativeInfinity;
  var minLng = double.infinity;
  var maxLng = double.negativeInfinity;
  for (final p in ring) {
    if (p.lat < minLat) minLat = p.lat;
    if (p.lat > maxLat) maxLat = p.lat;
    if (p.lng < minLng) minLng = p.lng;
    if (p.lng > maxLng) maxLng = p.lng;
  }
  return math.max(maxLat - minLat, maxLng - minLng);
}
