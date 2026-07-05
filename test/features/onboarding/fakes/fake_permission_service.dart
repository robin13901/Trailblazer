import 'package:auto_explore/features/onboarding/data/permission_service.dart';
import 'package:permission_handler/permission_handler.dart';

/// Test double for [PermissionService].
///
/// Records each call in [requestLog] and returns scripted statuses.
/// No method-channel mocking — the seam IS the mocking boundary.
class FakePermissionService implements PermissionService {
  FakePermissionService({
    this.whenInUseResult = PermissionStatus.granted,
    this.alwaysResult = PermissionStatus.granted,
    this.sensorsResult = PermissionStatus.granted,
    this.notificationResult = PermissionStatus.granted,
  });

  PermissionStatus whenInUseResult;
  PermissionStatus alwaysResult;
  PermissionStatus sensorsResult;
  PermissionStatus notificationResult;

  PermissionStatus? _alwaysStatusOverride;
  PermissionStatus? _notificationStatusOverride;

  int openAppSettingsCalls = 0;
  final List<String> requestLog = [];

  // Setters without getters: intentional — tests only write these values;
  // reads go through `statusAlways()` / `statusNotification()` methods.
  // ignore: avoid_setters_without_getters
  set alwaysStatus(PermissionStatus s) => _alwaysStatusOverride = s;

  // Setters without getters: intentional — tests only write these values;
  // reads go through `statusAlways()` / `statusNotification()` methods.
  // ignore: avoid_setters_without_getters
  set notificationStatus(PermissionStatus s) => _notificationStatusOverride = s;

  @override
  Future<PermissionStatus> requestWhenInUse() async {
    requestLog.add('whenInUse');
    return whenInUseResult;
  }

  @override
  Future<PermissionStatus> requestAlways() async {
    requestLog.add('always');
    return alwaysResult;
  }

  @override
  Future<PermissionStatus> requestSensors() async {
    requestLog.add('sensors');
    return sensorsResult;
  }

  @override
  Future<PermissionStatus> requestNotification() async {
    requestLog.add('notification');
    return notificationResult;
  }

  @override
  Future<PermissionStatus> statusAlways() async =>
      _alwaysStatusOverride ?? alwaysResult;

  @override
  Future<PermissionStatus> statusNotification() async =>
      _notificationStatusOverride ?? notificationResult;

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalls++;
    return true;
  }
}
