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

  /// Phase-3 only: camera follows current location AND rotates to match
  /// current heading (bearing-lock while driving).
  locationAndHeading,
}
