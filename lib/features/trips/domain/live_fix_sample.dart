import 'package:meta/meta.dart';

/// A single accepted GPS fix, emitted live during recording.
///
/// Plan (live-nav): unlike `TrackingRecording` — which carries only aggregate
/// stats and is equality-compared for Riverpod rebuilds — this DTO carries the
/// raw coordinate of each accepted fix so live consumers (the dashed trail
/// layer and the road-snap heading service) can react per fix without bloating
/// the tracking state or hitting the DB batcher.
///
/// Distinct from the internal `LastFixSample` (which carries accuracy/speed for
/// the diagnostics HUD); this one carries the live driving direction instead.
@immutable
class LiveFixSample {
  const LiveFixSample({
    required this.ts,
    required this.lat,
    required this.lon,
    this.headingDegrees,
  });

  /// Timestamp of the fix (from the ingestor outcome).
  final DateTime ts;

  /// Accepted latitude.
  final double lat;

  /// Accepted longitude.
  final double lon;

  /// Live driving direction in degrees (0..360, 0 = N, 90 = E) as computed by
  /// `TrackingService` — the fix's own course over ground when valid, otherwise
  /// the motion-vector bearing between consecutive accepted fixes. Null until
  /// the first meaningful movement.
  final double? headingDegrees;
}
