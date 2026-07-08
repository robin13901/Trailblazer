// Phase 5 (Plan 05-04): GpsFix — one GPS observation as consumed by the
// Viterbi decoder. Deliberately decoupled from the Drift `TripPoint`
// row so the matcher can be tested / isolate-shipped without dragging
// Drift into pure-Dart code.
//
// The coordinator (Plan 05-07) maps TripPoint → GpsFix at the DB boundary.

import 'package:meta/meta.dart';

/// One GPS observation as consumed by `ViterbiDecoder`.
///
/// Deliberately decoupled from the Drift `TripPoint` row type so the
/// decoder can be tested without any Drift dependency.
@immutable
class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lon,
    required this.accuracyMeters,
    required this.speedKmh,
    required this.ts,
  });

  /// WGS84 latitude (degrees).
  final double lat;

  /// WGS84 longitude (degrees).
  final double lon;

  /// Horizontal accuracy in meters (HDOP-derived, from
  /// flutter_background_geolocation). Values <= 0 or NaN are treated as
  /// "unknown" downstream and default the emission sigma to
  /// `kEmissionSigmaMeters`.
  final double accuracyMeters;

  /// Speed in km/h; may be 0 for stationary fixes.
  final double speedKmh;

  /// Timestamp of the GPS fix.
  final DateTime ts;

  @override
  String toString() =>
      'GpsFix($lat, $lon acc=${accuracyMeters}m spd=${speedKmh}km/h @$ts)';
}
