import 'dart:async';

import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/road_snap_heading_provider.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Headless widget: no visible UI. Listens to [trackingStateProvider] and
/// drives [cameraStateProvider] on trip start/stop transitions, AND rotates
/// the map camera to the live driving direction while recording.
///
/// **Live-nav rewrite.** Earlier (Plan 06-07) this fired a discrete
/// `animateCamera(bearingTo)` per fix, gated behind a 5° delta throttle — a
/// stepped, laggy rotation. It now runs a [Ticker] that every frame eases a
/// `_displayBearing` toward a `_targetBearing` along the shortest arc and
/// applies it via `moveCamera(bearingTo)` (a cheap bearing-only update). The
/// target is the ROAD-SNAPPED heading from [roadSnapHeadingServiceProvider]
/// (which stabilizes to the current OSM road's tangent), falling back to the
/// raw GPS heading from [liveFixProvider] when no snap is available. The result
/// is a continuous Google-Maps-style glide instead of 5° steps.
///
/// Follow/idle transitions fire ONLY on state TRANSITIONS between
/// [TrackingIdle] and [TrackingRecording]. A user pan
/// (`onCameraTrackingDismissed` in the map widget) mid-trip pushes
/// [FollowMode.none]; the per-frame tick is a no-op whenever follow is not
/// [FollowMode.locationAndHeading], so we never fight the user's manual
/// orientation.
///
/// Registration is via `ref.listen` inside `build()`, not `initState()` —
/// Riverpod dedups the listener across rebuilds of the same widget instance,
/// so hot reload cannot double-register. The [Ticker] lifecycle is owned by
/// this State (created on init, disposed on teardown).
class TrackingCameraSync extends ConsumerStatefulWidget {
  const TrackingCameraSync({super.key});

  @override
  ConsumerState<TrackingCameraSync> createState() => _TrackingCameraSyncState();
}

class _TrackingCameraSyncState extends ConsumerState<TrackingCameraSync>
    with SingleTickerProviderStateMixin {
  /// Per-frame easing factor: fraction of the remaining angular gap closed
  /// each tick. ~0.15 at 60 fps reaches the target in ~150 ms — smooth but
  /// responsive, and self-damping (no overshoot).
  static const double _easeFactor = 0.15;

  /// Below this gap (degrees) we snap exactly and skip the camera call, so an
  /// idle ticker doesn't spam `moveCamera` with sub-degree no-ops.
  static const double _epsilonDegrees = 0.1;

  late final Ticker _ticker;

  /// The bearing the camera currently shows (what we last pushed).
  double? _displayBearing;

  /// Last raw GPS heading seen (fallback when the road-snap service has no
  /// bearing yet, e.g. before the first way index loads).
  double? _rawHeading;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref
      ..listen<TrackingState>(trackingStateProvider, (previous, next) {
        // TrackingIdle → TrackingRecording: activate heading-lock + ticker.
        if (previous is TrackingIdle && next is TrackingRecording) {
          _displayBearing = null;
          _rawHeading = null;
          ref
              .read(cameraStateProvider.notifier)
              .setFollowMode(FollowMode.locationAndHeading);
          if (!_ticker.isActive) unawaited(_ticker.start());
          return;
        }
        // TrackingRecording → TrackingIdle: release follow mode + stop ticker.
        if (previous is TrackingRecording && next is TrackingIdle) {
          if (_ticker.isActive) _ticker.stop();
          _displayBearing = null;
          _rawHeading = null;
          ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
        }
      })
      // Keep a raw-heading fallback fresh from the live fix stream. The
      // road-snap service also consumes this stream (via its own provider) and
      // exposes the stabilized bearing we prefer in the tick.
      ..listen<AsyncValue<LiveFixSample>>(liveFixProvider, (_, next) {
        if (next case AsyncData(:final value)) {
          final h = value.headingDegrees;
          if (h != null) _rawHeading = h;
        }
      });
    return const SizedBox.shrink();
  }

  /// Per-frame: refresh the target from the road-snap service (fallback raw),
  /// ease the display bearing toward it along the shortest arc, and push it.
  void _onTick(Duration _) {
    // Respect pan-dismiss: only rotate while heading-locked.
    if (ref.read(cameraStateProvider).followMode !=
        FollowMode.locationAndHeading) {
      return;
    }

    final target =
        ref.read(roadSnapHeadingServiceProvider).targetBearing ?? _rawHeading;
    if (target == null) return;

    final display = _displayBearing;
    if (display == null) {
      // First frame with a known target — jump straight to it, no ease-in.
      _displayBearing = target;
      _pushBearing(target);
      return;
    }

    final delta = _shortestSignedDelta(display, target);
    if (delta.abs() < _epsilonDegrees) return;

    final next = (display + delta * _easeFactor + 360.0) % 360.0;
    _displayBearing = next;
    _pushBearing(next);
  }

  void _pushBearing(double bearing) {
    final controller = ref.read(mapControllerProvider);
    if (controller == null) return;
    unawaited(controller.moveCamera(CameraUpdate.bearingTo(bearing)));
  }

  /// Signed shortest angular delta from [from] to [to], in (-180, 180].
  /// Positive = clockwise. Used so easing always takes the short way round.
  static double _shortestSignedDelta(double from, double to) {
    var diff = (to - from) % 360.0;
    if (diff < -180.0) diff += 360.0;
    if (diff > 180.0) diff -= 360.0;
    return diff;
  }
}
