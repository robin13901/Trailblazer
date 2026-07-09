import 'package:meta/meta.dart';

/// FGB-agnostic fix DTO. FGB-specific fields (`bg.Location`) are converted
/// to this type at the boundary in Wave 2's `tracking_service.dart`.
@immutable
class FixInput {
  const FixInput({
    required this.ts,
    required this.lat,
    required this.lon,
    required this.accuracyMeters,
    this.speedMps,
    this.headingDegrees,
    this.altitudeMeters,
    this.activityType,
    this.uuid,
  });

  final DateTime ts;
  final double lat;
  final double lon;
  final double accuracyMeters;
  final double? speedMps;

  /// Course over ground in degrees (0..360, 0 = N, 90 = E), as reported by
  /// the OS/FGB (`coords.heading`). Null when unknown — FGB reports `-1` for
  /// an invalid/unknown heading (e.g. while stationary), which the boundary
  /// maps to null. Plan 06-07: consumed by `TrackingService` to drive the
  /// map's motion-vector camera rotation.
  final double? headingDegrees;

  final double? altitudeMeters;

  /// FGB activity type string (e.g. 'in_vehicle', 'on_foot').
  final String? activityType;

  /// FGB per-fix UUID, used for de-duplication on replay.
  final String? uuid;
}
