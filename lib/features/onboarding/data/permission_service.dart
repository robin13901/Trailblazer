import 'package:permission_handler/permission_handler.dart' as ph;

/// Narrow seam over permission_handler.
///
/// Widget code, providers, and tests go through here — no direct
/// `Permission.X.request()` anywhere in `lib/features/**` outside
/// [PermissionHandlerService].
///
/// Using a prefixed import (`as ph`) on the real impl avoids the name
/// collision between this method and `ph.openAppSettings()`.
abstract interface class PermissionService {
  Future<ph.PermissionStatus> requestWhenInUse();
  Future<ph.PermissionStatus> requestAlways();

  /// iOS Motion & Fitness sensor permission.
  Future<ph.PermissionStatus> requestSensors();

  /// Android 13+ notification permission.
  Future<ph.PermissionStatus> requestNotification();

  Future<ph.PermissionStatus> statusAlways();
  Future<ph.PermissionStatus> statusNotification();
  Future<bool> openAppSettings();
}

/// Production implementation backed by `permission_handler`.
class PermissionHandlerService implements PermissionService {
  const PermissionHandlerService();

  @override
  Future<ph.PermissionStatus> requestWhenInUse() =>
      ph.Permission.locationWhenInUse.request();

  @override
  Future<ph.PermissionStatus> requestAlways() =>
      ph.Permission.locationAlways.request();

  @override
  Future<ph.PermissionStatus> requestSensors() =>
      ph.Permission.sensors.request();

  @override
  Future<ph.PermissionStatus> requestNotification() =>
      ph.Permission.notification.request();

  @override
  Future<ph.PermissionStatus> statusAlways() =>
      ph.Permission.locationAlways.status;

  @override
  Future<ph.PermissionStatus> statusNotification() =>
      ph.Permission.notification.status;

  @override
  Future<bool> openAppSettings() => ph.openAppSettings();
}
