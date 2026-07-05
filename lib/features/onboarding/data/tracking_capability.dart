/// Persisted tracking capability — whether Trailblazer can record trips
/// automatically in the background or requires manual control only.
enum TrackingCapability {
  /// Background location (Always) and, on Android 13+, notification
  /// permission are both granted. Auto-recording is possible.
  fullAuto,

  /// At least one required permission is not granted. Tracking requires
  /// manual user interaction.
  manualOnly,
}
