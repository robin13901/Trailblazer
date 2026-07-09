import 'package:meta/meta.dart';

/// Sealed state machine for the tracking subsystem.
///
/// Both variants are const-constructable so they can be used as default
/// values in Riverpod providers without allocating new instances.
@immutable
sealed class TrackingState {
  const TrackingState();
}

/// No active trip recording.
final class TrackingIdle extends TrackingState {
  const TrackingIdle();
}

/// A trip is currently being recorded.
final class TrackingRecording extends TrackingState {
  const TrackingRecording({
    required this.tripId,
    required this.startedAt,
    required this.distanceMeters,
    required this.pointCount,
    required this.manuallyStarted,
    this.currentSpeedKmh,
    this.headingDegrees,
  });

  final int tripId;
  final DateTime startedAt;
  final double distanceMeters;
  final int pointCount;
  final bool manuallyStarted;
  final double? currentSpeedKmh;

  /// Live driving direction in degrees (0..360, 0 = N, 90 = E). Preferred
  /// from the fix's own course over ground when valid, otherwise computed as
  /// the motion-vector bearing between consecutive accepted fixes. Null until
  /// the first meaningful movement. Plan 06-07: drives the map camera rotation
  /// so the view pivots to the driving direction while recording.
  final double? headingDegrees;

  /// Live elapsed time, excluding accumulated gap seconds.
  Duration duration(DateTime now) => now.difference(startedAt);
}
