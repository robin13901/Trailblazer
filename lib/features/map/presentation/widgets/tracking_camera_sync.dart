import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Headless widget: no visible UI. Listens to [trackingStateProvider] and
/// drives [cameraStateProvider]'s follow mode on trip start/stop transitions.
///
/// **Single native camera owner (2026-07-19).** While recording, the native
/// MapLibre location component owns the camera: `MapWidget` maps
/// [FollowMode.locationAndHeading] → `MyLocationTrackingMode.trackingGps`,
/// which does BOTH centering and heading-up rotation from the GPS motion
/// bearing. This widget's only job is to flip follow mode on the state
/// transitions so native tracking arms/disarms with the trip.
///
/// An earlier version (reverted) drove the camera itself via a per-frame
/// `Ticker` + `moveCamera` on top of native tracking. That fought the engine:
/// each programmatic camera nudge tripped `onCameraTrackingDismissed`
/// (`map_widget.dart`), which set [FollowMode.none] and silently killed
/// rotation, while requiring a second (manual) puck to hide the tip lag. Both
/// are gone — the native puck follows closely and the live coverage line is
/// drawn one fix behind (`LiveTrailBridge`) so its tip coincides with the puck.
///
/// Follow/idle transitions fire ONLY on state TRANSITIONS between
/// [TrackingIdle] and [TrackingRecording]. A user pan
/// (`onCameraTrackingDismissed` in the map widget) mid-trip pushes
/// [FollowMode.none]; we do not re-arm on subsequent [TrackingRecording]
/// re-emits, so we never fight the user's manual pan/zoom/orientation.
///
/// Registration is via `ref.listen` inside `build()`, not `initState()` —
/// Riverpod dedups the listener across rebuilds of the same widget instance,
/// so hot reload cannot double-register.
class TrackingCameraSync extends ConsumerWidget {
  const TrackingCameraSync({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<TrackingState>(trackingStateProvider, (previous, next) {
      // TrackingIdle → TrackingRecording: arm native heading-lock follow.
      if (previous is TrackingIdle && next is TrackingRecording) {
        ref
            .read(cameraStateProvider.notifier)
            .setFollowMode(FollowMode.locationAndHeading);
        return;
      }
      // TrackingRecording → TrackingIdle: release follow mode.
      if (previous is TrackingRecording && next is TrackingIdle) {
        ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
      }
    });
    return const SizedBox.shrink();
  }
}
