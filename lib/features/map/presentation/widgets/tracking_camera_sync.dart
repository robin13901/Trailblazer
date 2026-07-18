import 'dart:async';

import 'package:auto_explore/features/map/domain/camera_state.dart';
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
/// drives [cameraStateProvider] on trip start/stop transitions, AND drives the
/// map camera — BOTH centering and rotation — to follow the live driving
/// position + direction while recording.
///
/// **Why fully-manual camera (2026-07-18).** While recording we suppress the
/// native MapLibre location puck (MapWidget sets `myLocationEnabled=false`) so
/// our own `LivePuckBridge` dot sits exactly at the live coverage-line tip with
/// zero lag. But disabling the native puck ALSO disables MapLibre's native
/// camera follow — which did both centering and rotation. So this widget now
/// drives the whole camera itself: a [Ticker] eases a `_displayLat/_displayLon`
/// toward the latest live-fix position and a `_displayBearing` toward the
/// travel direction, then pushes both (plus the user's current zoom) in a
/// single `moveCamera(newCameraPosition)` each frame. The result is a
/// continuous Google-Maps-style glide that keeps the puck near screen-center
/// and the map rotated heading-up.
///
/// The bearing target is the ROAD-SNAPPED heading from
/// [roadSnapHeadingServiceProvider] (stabilised to the current OSM road's
/// tangent), falling back to the raw GPS heading from [liveFixProvider] when no
/// snap is available.
///
/// Follow/idle transitions fire ONLY on state TRANSITIONS between
/// [TrackingIdle] and [TrackingRecording]. A user pan
/// (`onCameraTrackingDismissed` in the map widget) mid-trip pushes
/// [FollowMode.none]; the per-frame tick is a no-op whenever follow is not
/// [FollowMode.locationAndHeading], so we never fight the user's manual
/// pan/zoom/orientation.
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
  /// Per-frame easing factor: fraction of the remaining gap closed each tick.
  /// ~0.15 at 60 fps converges in ~150 ms — smooth but responsive, and
  /// self-damping (no overshoot). Shared by position and bearing easing.
  static const double _easeFactor = 0.15;

  /// Below this angular gap (degrees) we snap bearing exactly and skip the
  /// update, so an idle ticker doesn't spam sub-degree no-ops.
  static const double _epsilonDegrees = 0.1;

  /// Below this positional gap (degrees lat/lon, ~1 cm) we snap position
  /// exactly rather than easing forever toward an unreachable float target.
  static const double _epsilonDegreesPos = 1e-7;

  late final Ticker _ticker;

  /// The bearing the camera currently shows (what we last pushed).
  double? _displayBearing;

  /// The position the camera is currently centered on (what we last pushed).
  double? _displayLat;
  double? _displayLon;

  /// Latest live-fix position — the target the camera center eases toward.
  double? _targetLat;
  double? _targetLon;

  /// Last raw GPS heading seen (fallback when the road-snap service has no
  /// bearing yet, e.g. before the first way index loads).
  double? _rawHeading;

  /// Last zoom we observed from the controller. Preserved across frames so the
  /// user's pinch-zoom persists while we drive center + bearing.
  double? _lastZoom;

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
        // TrackingIdle → TrackingRecording: activate follow-lock + ticker.
        if (previous is TrackingIdle && next is TrackingRecording) {
          _resetFollowState();
          ref
              .read(cameraStateProvider.notifier)
              .setFollowMode(FollowMode.locationAndHeading);
          if (!_ticker.isActive) unawaited(_ticker.start());
          return;
        }
        // TrackingRecording → TrackingIdle: release follow mode + stop ticker.
        if (previous is TrackingRecording && next is TrackingIdle) {
          if (_ticker.isActive) _ticker.stop();
          _resetFollowState();
          ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
        }
      })
      // Keep the target position + raw-heading fallback fresh from the live fix
      // stream. The road-snap service also consumes this stream (via its own
      // provider) and exposes the stabilised bearing we prefer in the tick.
      ..listen<AsyncValue<LiveFixSample>>(liveFixProvider, (_, next) {
        if (next case AsyncData(:final value)) {
          _targetLat = value.lat;
          _targetLon = value.lon;
          final h = value.headingDegrees;
          if (h != null) _rawHeading = h;
        }
      });
    return const SizedBox.shrink();
  }

  void _resetFollowState() {
    _displayBearing = null;
    _displayLat = null;
    _displayLon = null;
    _targetLat = null;
    _targetLon = null;
    _rawHeading = null;
    _lastZoom = null;
  }

  /// Per-frame: ease display position + bearing toward their live targets and
  /// push them (plus the user's current zoom) in one camera update.
  void _onTick(Duration _) {
    // Respect pan-dismiss: only auto-follow while heading-locked.
    if (ref.read(cameraStateProvider).followMode !=
        FollowMode.locationAndHeading) {
      return;
    }

    final tLat = _targetLat;
    final tLon = _targetLon;
    if (tLat == null || tLon == null) return; // no fix yet

    // Bearing target: road-snapped heading, falling back to raw GPS heading.
    final targetBearing =
        ref.read(roadSnapHeadingServiceProvider).targetBearing ?? _rawHeading;

    // --- Position easing -------------------------------------------------
    final dLat = _displayLat;
    final dLon = _displayLon;
    double nextLat;
    double nextLon;
    if (dLat == null || dLon == null) {
      // First frame with a known target — jump straight to it, no ease-in.
      nextLat = tLat;
      nextLon = tLon;
    } else {
      final gapLat = tLat - dLat;
      final gapLon = tLon - dLon;
      nextLat = gapLat.abs() < _epsilonDegreesPos ? tLat : dLat + gapLat * _easeFactor;
      nextLon = gapLon.abs() < _epsilonDegreesPos ? tLon : dLon + gapLon * _easeFactor;
    }
    _displayLat = nextLat;
    _displayLon = nextLon;

    // --- Bearing easing --------------------------------------------------
    var nextBearing = _displayBearing;
    if (targetBearing != null) {
      final db = _displayBearing;
      if (db == null) {
        nextBearing = targetBearing; // first frame — snap
      } else {
        final delta = _shortestSignedDelta(db, targetBearing);
        nextBearing = delta.abs() < _epsilonDegrees
            ? db
            : (db + delta * _easeFactor + 360.0) % 360.0;
      }
      _displayBearing = nextBearing;
    }

    _pushCamera(nextLat, nextLon, nextBearing ?? 0);
  }

  /// Push the full camera (center + bearing + preserved zoom) in one update.
  void _pushCamera(double lat, double lon, double bearing) {
    final controller = ref.read(mapControllerProvider);
    if (controller == null) return;
    // Preserve the user's current zoom (they can still pinch-zoom while we
    // drive center + bearing). trackCameraPosition:true keeps cameraPosition
    // fresh; fall back to the last seen zoom, then the recenter default.
    final zoom = controller.cameraPosition?.zoom ??
        _lastZoom ??
        CameraState.recenterZoom;
    _lastZoom = zoom;
    unawaited(
      controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(lat, lon),
            zoom: zoom,
            bearing: bearing,
          ),
        ),
      ),
    );
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
