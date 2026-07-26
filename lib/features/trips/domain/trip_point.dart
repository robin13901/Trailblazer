import 'package:meta/meta.dart';

/// Domain-level TripPoint DTO accumulated by TripFixBatcher.
///
/// This is intentionally NOT the Drift-generated `TripPointsCompanion` from
/// Plan 03-01 — keeping this pure-Dart allows Plan 03-02 to compile in
/// Wave 1 independently of Plan 03-01's Drift types. The adapter converting
/// TripPoint → `TripPointsCompanion` lives in Plan 03-04.
@immutable
class TripPoint {
  const TripPoint({
    required this.tripId,
    required this.seq,
    required this.ts,
    required this.lat,
    required this.lon,
    this.speedKmh,
    this.accuracyMeters,
    this.altitudeMeters,
    this.motionType,
    this.headingDegrees,
  });

  final int tripId;
  final int seq;
  final DateTime ts;
  final double lat;
  final double lon;
  final double? speedKmh;
  final double? accuracyMeters;
  final double? altitudeMeters;
  final String? motionType;

  /// GPS course-over-ground in degrees (0=N, 90=E) at this fix: the OS
  /// `coords.heading` when valid, else a motion-vector bearing from the
  /// previous accepted fix. Null when neither is available (e.g. the first
  /// stationary fix). Persisted to `trip_points.heading` (schema v8) so the
  /// road matcher can disambiguate divided-carriageway direction (#11).
  final double? headingDegrees;
}
