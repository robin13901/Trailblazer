import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:permission_handler/permission_handler.dart';

/// Read-once location repository for Phase 2.
///
/// Phase 2 needs the current position ONLY to open the camera at
/// the right place on app launch. Phase 3 replaces the "position
/// stream" concern with `flutter_background_geolocation`; this
/// repo does NOT provide a stream.
///
/// The blue-dot on the map is rendered by MapLibre's built-in
/// location engine; we don't provide those coordinates ourselves.
class LocationRepository {
  const LocationRepository();

  /// Returns the current permission status without triggering a
  /// prompt.
  Future<PermissionStatus> currentStatus() =>
      Permission.locationWhenInUse.status;

  /// Requests `whenInUse` permission (idempotent — iOS shows the
  /// system prompt at most once).
  Future<PermissionStatus> requestPermission() =>
      Permission.locationWhenInUse.request();

  /// Phase 2 uses MapLibre's built-in engine for both the blue
  /// dot AND the initial camera target — via
  /// `MyLocationTrackingMode.tracking`. This method exists as
  /// an extension point but is intentionally not called in
  /// Phase 2. Returning `Err(PermissionDeniedError(...))` on
  /// denied keeps callers honest.
  Future<Result<bool>> hasPermission() async {
    try {
      final s = await Permission.locationWhenInUse.status;
      return Ok(s.isGranted || s.isLimited);
    } on Object catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }
}
