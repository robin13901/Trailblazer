// Trailblazer live-nav:
// LivePuckBridge — headless ConsumerStatefulWidget that paints a location
// puck from the same liveFixProvider feed as LiveTrailBridge, in the same
// tick, so the puck is always at the tip of the live coverage line.
//
// Fixes F5 (10-02): during recording the blue MapLibre NATIVE location layer
// runs on its own slower/smoothed cadence and lags the live coverage line.
// This bridge draws OUR OWN puck driven by the same LiveFixSample stream,
// placed above the live trail layer so the dot sits on the line tip every
// tick.  The native dot is suppressed by MapWidget while recording
// (myLocationEnabled=false) and restored when idle.
//
// Architecture mirrors LiveTrailBridge / CoverageOverlayBridge:
//   - Watches mapStyleLoadedTickProvider: a style (re)load wipes all
//     programmatic sources (Pitfall 1), so on each tick change we re-add the
//     puck from the last known point.
//   - ref.listen(liveFixProvider): on each accepted fix call
//     applier.addOrUpdate() — same feed, same tick as the trail.
//   - ref.listen(trackingStateProvider): on → TrackingIdle, call
//     applier.remove().
//
// Safety invariants (06-05 lesson — map must never crash):
//   - All applier calls guarded by a non-null controller inside the applier.
//   - All async applier calls dispatched via unawaited() with caught throws.
//   - ref is NOT used in dispose() — notifiers cached in initState().
//
// Renders const SizedBox.shrink(). Mount in MapScreen as a zero-size
// Positioned OUTSIDE any `if (isMapTab)` guard, right next to
// LiveTrailBridge, so it persists across tab switches.

import 'dart:async';

import 'package:auto_explore/features/map/presentation/providers/live_puck_applier.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

final _log = Logger('LivePuckBridge');

/// Headless widget drawing the live location puck during recording.
///
/// Renders `const SizedBox.shrink()`. Mount as a zero-size [Positioned] in
/// `MapScreen` outside the `isMapTab` block (same pattern as `LiveTrailBridge`
/// / `CoverageOverlayBridge`).
class LivePuckBridge extends ConsumerStatefulWidget {
  const LivePuckBridge({super.key});

  @override
  ConsumerState<LivePuckBridge> createState() => _LivePuckBridgeState();
}

class _LivePuckBridgeState extends ConsumerState<LivePuckBridge> {
  /// Last known puck position — used for style-reload re-add.
  LatLng? _lastPoint;

  /// Last known heading — forwarded to the applier on re-add.
  double? _lastHeading;

  /// Style-load tick sentinel (see `CoverageOverlayBridge`).
  int _lastTick = -1;

  bool _styleReady = false;

  @override
  Widget build(BuildContext context) {
    final tick = ref.watch(mapStyleLoadedTickProvider);
    if (tick != _lastTick) {
      _lastTick = tick;
      _styleReady = true;
      // A (re)loaded style wiped our source — re-add from the last known
      // position so the puck survives a light/dark brightness swap mid-drive.
      _scheduleReadd();
    }

    ref
      ..listen<AsyncValue<LiveFixSample>>(liveFixProvider, (_, next) {
        if (next case AsyncData(:final value)) {
          _onFix(value);
        }
      })
      ..listen<TrackingState>(trackingStateProvider, (_, next) {
        if (next is TrackingIdle) _onStop();
      });

    return const SizedBox.shrink();
  }

  void _onFix(LiveFixSample fix) {
    _lastPoint = LatLng(fix.lat, fix.lon);
    _lastHeading = fix.headingDegrees;
    if (!_styleReady) return;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(livePuckApplierProvider);
    _dispatch(
      () => applier.addOrUpdate(
        controller,
        _lastPoint!,
        heading: _lastHeading,
      ),
      'addOrUpdate',
    );
  }

  void _onStop() {
    _lastPoint = null;
    _lastHeading = null;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(livePuckApplierProvider);
    _dispatch(() => applier.remove(controller), 'remove');
  }

  /// Re-add after a style reload if we still have a last known position.
  void _scheduleReadd() {
    final point = _lastPoint;
    if (point == null) return;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(livePuckApplierProvider);
    _dispatch(
      () => applier.addOrUpdate(controller, point, heading: _lastHeading),
      'addOrUpdate(re-add)',
    );
  }

  void _dispatch(Future<void> Function() action, String label) {
    unawaited(action().catchError((Object e, StackTrace st) {
      _log.warning('LivePuckBridge: $label threw — map kept stable.', e, st);
    }));
  }
}
