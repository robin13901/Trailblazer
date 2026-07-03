import 'package:auto_explore/features/map/data/location_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// Async notifier that surfaces the current `locationWhenInUse` permission
/// status.
///
/// Plain [AsyncNotifier] — no `@Riverpod` codegen (see STATE.md Plan 01-01
/// decision).
class LocationPermissionNotifier extends AsyncNotifier<PermissionStatus> {
  @override
  Future<PermissionStatus> build() {
    final repo = ref.watch(locationRepositoryProvider);
    return repo.currentStatus();
  }

  /// Called from the onboarding Continue button. Triggers the system prompt
  /// (first-time only on iOS), then refreshes state.
  Future<PermissionStatus> requestOnce() async {
    final repo = ref.read(locationRepositoryProvider);
    final result = await repo.requestPermission();
    state = AsyncData(result);
    return result;
  }

  /// Called if the user changes permission in system settings and returns
  /// to the app. Phase 2 does not hook this automatically; a future plan
  /// can wire it via `WidgetsBindingObserver.didChangeAppLifecycleState`.
  Future<void> refresh() async {
    final repo = ref.read(locationRepositoryProvider);
    state = AsyncData(await repo.currentStatus());
  }
}

/// Provider for the current [PermissionStatus] of `locationWhenInUse`.
final locationPermissionProvider =
    AsyncNotifierProvider<LocationPermissionNotifier, PermissionStatus>(
  LocationPermissionNotifier.new,
);
