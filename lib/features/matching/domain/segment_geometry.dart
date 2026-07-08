// Phase 5 (Plan 05-02): Segment geometry primitives.
//
// Uses equirectangular projection scaled by cos(mean_lat) — accurate to
// < 0.3 % for German latitudes over sub-kilometer segments (Newson-Krumm
// 2009 §III uses the same approximation). For anything larger than a
// single OSM segment (~100 m), use haversineMeters from
// `lib/features/trips/domain/haversine.dart` instead.

import 'dart:math' as math;

/// Meters per degree of latitude at any latitude (roughly constant on WGS84).
const double metersPerDegreeLat = 111320;

/// Meters per degree of longitude at latitude [latDeg].
double metersPerDegreeLon(double latDeg) =>
    metersPerDegreeLat * math.cos(latDeg * math.pi / 180);

/// Perpendicular distance in meters from point p to segment ab, measured
/// via projection to a local equirectangular plane centered at the mean
/// latitude of a and b. If p projects outside [a, b], the distance to the
/// nearer endpoint is returned.
double perpDistanceToSegmentMeters({
  required double pLat,
  required double pLon,
  required double aLat,
  required double aLon,
  required double bLat,
  required double bLon,
}) {
  final meanLat = (aLat + bLat) / 2;
  final mLon = metersPerDegreeLon(meanLat);
  const mLat = metersPerDegreeLat;

  final ax = aLon * mLon;
  final ay = aLat * mLat;
  final bx = bLon * mLon;
  final by = bLat * mLat;
  final px = pLon * mLon;
  final py = pLat * mLat;

  final dx = bx - ax;
  final dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  if (lenSq == 0) {
    // Degenerate segment; distance to point a.
    final ex = px - ax;
    final ey = py - ay;
    return math.sqrt(ex * ex + ey * ey);
  }

  // Vector projection fraction, clamped so distance-to-endpoint is used
  // when the point projects beyond the segment.
  var t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
  if (t < 0) t = 0;
  if (t > 1) t = 1;

  final cx = ax + t * dx;
  final cy = ay + t * dy;
  final ex = px - cx;
  final ey = py - cy;
  return math.sqrt(ex * ex + ey * ey);
}

/// Projection fraction of point p onto segment ab, clamped to [0, 1].
/// 0.0 = point projects onto a; 1.0 = onto b; values in between = along
/// the segment.
double projectionFractionOnSegment({
  required double pLat,
  required double pLon,
  required double aLat,
  required double aLon,
  required double bLat,
  required double bLon,
}) {
  final meanLat = (aLat + bLat) / 2;
  final mLon = metersPerDegreeLon(meanLat);
  const mLat = metersPerDegreeLat;

  final ax = aLon * mLon;
  final ay = aLat * mLat;
  final bx = bLon * mLon;
  final by = bLat * mLat;
  final px = pLon * mLon;
  final py = pLat * mLat;

  final dx = bx - ax;
  final dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  if (lenSq == 0) return 0;

  var t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return t;
}

/// Length of the segment ab in meters (local plane).
double segmentLengthMeters({
  required double aLat,
  required double aLon,
  required double bLat,
  required double bLon,
}) {
  final meanLat = (aLat + bLat) / 2;
  final mLon = metersPerDegreeLon(meanLat);
  const mLat = metersPerDegreeLat;
  final dx = (bLon - aLon) * mLon;
  final dy = (bLat - aLat) * mLat;
  return math.sqrt(dx * dx + dy * dy);
}
