import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Notifier for the current camera state.
///
/// Updated from the map widget when:
/// - the map reports a camera idle event ([updateFromMap])
/// - the user pans away from tracking ([setFollowMode])
///
/// Plain [Notifier] — no `@Riverpod` codegen (see STATE.md Plan 01-01 decision).
class CameraStateNotifier extends Notifier<CameraState> {
  @override
  CameraState build() => CameraState.initial;

  /// Sync camera position/zoom/bearing from a MapLibre [CameraPosition] event.
  ///
  /// Does NOT change [CameraState.followMode] — follow mode transitions are
  /// explicit via [setFollowMode].
  void updateFromMap(CameraPosition position) {
    state = state.copyWith(
      latitude: position.target.latitude,
      longitude: position.target.longitude,
      zoom: position.zoom,
      bearing: position.bearing,
    );
  }

  /// Explicitly change follow mode (e.g. pan-dismiss → [FollowMode.none],
  /// re-center tap → [FollowMode.location]).
  void setFollowMode(FollowMode mode) =>
      state = state.copyWith(followMode: mode);

  /// Replace the entire camera state (position + zoom + follow mode).
  ///
  /// Used by "Jump to on map" (region detail sheet, 2026-07-11): the Map tab's
  /// MapWidget is disposed while off-tab and re-seeds its initialCameraPosition
  /// from this provider on remount, so writing the target here makes the map
  /// open already centered on the region. Setting [FollowMode.none] prevents
  /// MapLibre's GPS tracking from snapping the camera back to the user.
  // ignore: use_setters_to_change_properties — semantic "jump" verb, not a setter
  void jumpTo(CameraState target) => state = target;
}

/// Provider for the current [CameraState].
final cameraStateProvider = NotifierProvider<CameraStateNotifier, CameraState>(
  CameraStateNotifier.new,
);
