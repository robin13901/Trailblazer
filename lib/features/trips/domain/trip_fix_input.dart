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
    this.altitudeMeters,
    this.activityType,
    this.uuid,
  });

  final DateTime ts;
  final double lat;
  final double lon;
  final double accuracyMeters;
  final double? speedMps;
  final double? altitudeMeters;

  /// FGB activity type string (e.g. 'in_vehicle', 'on_foot').
  final String? activityType;

  /// FGB per-fix UUID, used for de-duplication on replay.
  final String? uuid;
}
