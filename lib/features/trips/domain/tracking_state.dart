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
  });

  final int tripId;
  final DateTime startedAt;
  final double distanceMeters;
  final int pointCount;
  final bool manuallyStarted;
  final double? currentSpeedKmh;

  /// Live elapsed time, excluding accumulated gap seconds.
  Duration duration(DateTime now) => now.difference(startedAt);
}
