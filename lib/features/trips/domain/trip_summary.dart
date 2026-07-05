import 'package:meta/meta.dart';

/// Immutable summary of a completed trip, computed at close time.
///
/// All fields are required — a partial summary cannot be committed (close
/// requires a complete snapshot). Phase 9 wires [autoStopped] to the FGB
/// motion-stop callback; Phase 3 callers set it explicitly.
@immutable
class TripSummary {
  const TripSummary({
    required this.startedAt,
    required this.endedAt,
    required this.durationSeconds,
    required this.distanceMeters,
    required this.avgSpeedKmh,
    required this.maxSpeedKmh,
    required this.pointCount,
    required this.bboxMinLat,
    required this.bboxMinLon,
    required this.bboxMaxLat,
    required this.bboxMaxLon,
    required this.autoStopped,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final int durationSeconds;
  final double distanceMeters;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final int pointCount;
  final double bboxMinLat;
  final double bboxMinLon;
  final double bboxMaxLat;
  final double bboxMaxLon;
  final bool autoStopped;
}
