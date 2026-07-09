import 'dart:math' as math;

/// Great-circle distance in meters between two WGS84 points.
double haversineMeters(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const earthRadiusMeters = 6371000.0;
  final dLat = _deg2rad(lat2 - lat1);
  final dLon = _deg2rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_deg2rad(lat1)) *
          math.cos(_deg2rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

double _deg2rad(double deg) => deg * (math.pi / 180.0);

double _rad2deg(double rad) => rad * (180.0 / math.pi);

/// Initial bearing (forward azimuth) in degrees from point 1 to point 2.
///
/// Returns a compass bearing in the range 0..360 where 0 = North, 90 = East,
/// 180 = South, 270 = West. Uses the standard great-circle forward-azimuth
/// formula over WGS84 lat/lon. Plan 06-07: consumed by `TrackingService` to
/// compute a motion-vector heading from consecutive GPS fixes when the OS
/// does not supply a valid course over ground.
double bearingDegrees(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final phi1 = _deg2rad(lat1);
  final phi2 = _deg2rad(lat2);
  final dLambda = _deg2rad(lon2 - lon1);
  final y = math.sin(dLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  final theta = math.atan2(y, x);
  // Normalise -180..180 → 0..360.
  return (_rad2deg(theta) + 360.0) % 360.0;
}
