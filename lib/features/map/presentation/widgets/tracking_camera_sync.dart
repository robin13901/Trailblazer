import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Headless widget: no visible UI. Listens to [trackingStateProvider] and
/// drives [cameraStateProvider] on trip start/stop transitions.
///
/// Closes H2 from 03-1-RESEARCH — before this widget landed, nothing in
/// `lib/` linked tracking state to camera follow mode, so the reserved
/// `FollowMode.locationAndHeading` slot (STATE Plan 02-03) was never
/// activated during recording.
///
/// Fires ONLY on state TRANSITIONS (`previous` != `next`) between
/// [TrackingIdle] and [TrackingRecording], NOT on every state read.
/// A user pan (`onCameraTrackingDismissed` in the map widget) mid-trip
/// pushes `FollowMode.none`; subsequent same-state re-emits from tracking
/// (per accepted fix — 03-1-RESEARCH §5.1) are a NO-OP here. This
/// preserves pan-dismiss precedence: once the user pans, follow stays off
/// until they explicitly stop and re-start (or hit the recenter button).
///
/// Registration is via `ref.listen` inside `build()`, not `initState()` —
/// Riverpod dedups the listener across rebuilds of the same widget
/// instance, so hot reload cannot double-register (03-1-RESEARCH §9
/// Risk 3). It also avoids the `dispose()` `ref` hazard documented in
/// STATE Plan 02-03.
class TrackingCameraSync extends ConsumerWidget {
  const TrackingCameraSync({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<TrackingState>(trackingStateProvider, (previous, next) {
      // TrackingIdle → TrackingRecording: activate heading-lock.
      if (previous is TrackingIdle && next is TrackingRecording) {
        ref
            .read(cameraStateProvider.notifier)
            .setFollowMode(FollowMode.locationAndHeading);
        return;
      }
      // TrackingRecording → TrackingIdle: release follow mode.
      if (previous is TrackingRecording && next is TrackingIdle) {
        ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
        return;
      }
      // TrackingRecording → TrackingRecording (per-fix re-emit): NO-OP.
      // Preserves user pan-dismiss precedence — if the pan handler already
      // pushed FollowMode.none, we must not fight it on the next fix.
    });
    return const SizedBox.shrink();
  }
}
