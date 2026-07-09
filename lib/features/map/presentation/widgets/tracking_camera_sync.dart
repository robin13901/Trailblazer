import 'dart:async';

import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Headless widget: no visible UI. Listens to [trackingStateProvider] and
/// drives [cameraStateProvider] on trip start/stop transitions, AND rotates
/// the map camera to the live driving direction while recording.
///
/// Closes H2 from 03-1-RESEARCH — before this widget landed, nothing in
/// `lib/` linked tracking state to camera follow mode, so the reserved
/// `FollowMode.locationAndHeading` slot (STATE Plan 02-03) was never
/// activated during recording.
///
/// **Plan 06-07 — motion-vector camera rotation.** `MyLocationTrackingMode`
/// (set by `MapWidget` from the follow mode) only rotates the map if
/// MapLibre's INTERNAL location engine emits a bearing. Trailblazer's fixes
/// come from `flutter_background_geolocation`, which MapLibre's engine never
/// sees — so the map never rotated. This widget now watches the live
/// [TrackingRecording.headingDegrees] (computed by `TrackingService` from
/// consecutive GPS fixes) and explicitly animates the camera bearing via
/// [MapLibreMapController.animateCamera] + [CameraUpdate.bearingTo]. This is
/// layered ON TOP of the location-follow (centering) mode — we only add the
/// rotation.
///
/// Follow/idle transitions fire ONLY on state TRANSITIONS (`previous` !=
/// `next`) between [TrackingIdle] and [TrackingRecording]. A user pan
/// (`onCameraTrackingDismissed` in the map widget) mid-trip pushes
/// `FollowMode.none`; when follow is off we stop animating the bearing so we
/// don't fight the user's manual orientation.
///
/// Registration is via `ref.listen` inside `build()`, not `initState()` —
/// Riverpod dedups the listener across rebuilds of the same widget
/// instance, so hot reload cannot double-register (03-1-RESEARCH §9
/// Risk 3). It also avoids the `dispose()` `ref` hazard documented in
/// STATE Plan 02-03.
class TrackingCameraSync extends ConsumerStatefulWidget {
  const TrackingCameraSync({super.key});

  @override
  ConsumerState<TrackingCameraSync> createState() => _TrackingCameraSyncState();
}

class _TrackingCameraSyncState extends ConsumerState<TrackingCameraSync> {
  /// Last camera bearing we animated to. Used to throttle: we only animate
  /// when the heading moved more than [_minHeadingDeltaDegrees], so we're not
  /// firing an `animateCamera` on every 1 Hz fix (which would jank).
  double? _lastAnimatedHeading;

  /// Minimum heading change (degrees) before we re-animate the camera.
  static const double _minHeadingDeltaDegrees = 5;

  @override
  Widget build(BuildContext context) {
    ref.listen<TrackingState>(trackingStateProvider, (previous, next) {
      // TrackingIdle → TrackingRecording: activate heading-lock.
      if (previous is TrackingIdle && next is TrackingRecording) {
        _lastAnimatedHeading = null;
        ref
            .read(cameraStateProvider.notifier)
            .setFollowMode(FollowMode.locationAndHeading);
        return;
      }
      // TrackingRecording → TrackingIdle: release follow mode.
      if (previous is TrackingRecording && next is TrackingIdle) {
        _lastAnimatedHeading = null;
        ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
        return;
      }
      // TrackingRecording → TrackingRecording (per-fix re-emit): rotate the
      // camera to the fresh motion-vector heading. NO follow-mode change here
      // — that preserves user pan-dismiss precedence (once the user pans, the
      // follow mode is FollowMode.none and the guard below stops rotation).
      if (next is TrackingRecording) {
        _maybeAnimateHeading(next.headingDegrees);
      }
    });
    return const SizedBox.shrink();
  }

  /// Animate the map camera bearing to [heading] when it is fresh, the map is
  /// still following (heading-lock not dismissed by a user pan), and the
  /// change exceeds [_minHeadingDeltaDegrees].
  void _maybeAnimateHeading(double? heading) {
    if (heading == null) return;

    // Respect pan-dismiss: if the user panned (follow mode dropped to none),
    // do not fight their manual orientation.
    final followMode = ref.read(cameraStateProvider).followMode;
    if (followMode != FollowMode.locationAndHeading) return;

    final last = _lastAnimatedHeading;
    if (last != null && _headingDelta(last, heading) < _minHeadingDeltaDegrees) {
      return;
    }

    final controller = ref.read(mapControllerProvider);
    if (controller == null) return;

    _lastAnimatedHeading = heading;
    unawaited(controller.animateCamera(CameraUpdate.bearingTo(heading)));
  }

  /// Smallest absolute angular difference between two bearings (0..180).
  static double _headingDelta(double a, double b) {
    final diff = (a - b).abs() % 360.0;
    return diff > 180.0 ? 360.0 - diff : diff;
  }
}
