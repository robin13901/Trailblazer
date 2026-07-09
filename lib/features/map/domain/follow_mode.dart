/// Camera follow modes.
///
/// Phase 2 uses only [none] and [location].
/// Phase 3 (Tracking MVP) will activate `locationAndHeading` during
/// active trip recording — the enum slot is reserved here so that
/// Phase 3 does not touch the camera state shape.
enum FollowMode {
  /// User has panned/rotated freely. Camera does not follow anything.
  none,

  /// Camera follows current location (blue dot centered). No heading
  /// rotation — user rotation gestures are preserved.
  location,

  /// GPS-heading follow (map rotates to match motion bearing).
  ///
  /// Active during a recording trip. Maps to
  /// `MyLocationTrackingMode.trackingGps` in the widget layer (Plan 04-19):
  /// uses the motion-vector bearing computed from consecutive GPS fixes,
  /// not the device compass — car metal + phone-mount magnets deflect
  /// compass readings by 20-90° in a typical vehicle.
  locationAndHeading,
}
