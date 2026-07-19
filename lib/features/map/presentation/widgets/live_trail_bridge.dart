// Trailblazer live-nav:
// LiveTrailBridge — headless ConsumerStatefulWidget that paints the raw driven
// GPS path as a SOLID polyline, live, while a trip is recording.
//
// 2026-07-13 (coverage-from-trail rework): the live trail is now drawn SOLID
// in the current coverage color so it reads as "coverage being drawn live" —
// the raw GPS trail is very accurate on-road, and the persistent coverage that
// finalizes post-trip is this same trail trimmed to on-road segments. On trip
// stop the live source is removed and the persistent coverage overlay
// (coverage_overlay_layers.dart) takes over with an identical look.
//
// Architecture mirrors CoverageOverlayBridge:
//   - Watches mapStyleLoadedTickProvider: a style (re)load wipes all
//     programmatic sources (Pitfall 1), so on each tick change we re-add the
//     source+layer from the accumulated trail.
//   - ref.listen(liveFixProvider): append each accepted fix's LatLng and push
//     an in-place source update (setGeoJsonSource) — or add on first two points.
//   - ref.listen(trackingStateProvider): on → TrackingIdle, clear the trail and
//     remove the source+layer.
//
// Safety invariants (06-05 lesson — map must never crash):
//   - All applier calls guarded by a non-null controller inside the applier.
//   - All async applier calls dispatched via unawaited() with caught throws.
//
// Renders const SizedBox.shrink(). Mount in MapScreen as a zero-size Positioned
// OUTSIDE any `if (isMapTab)` guard so it persists across tab switches.

import 'dart:async';

import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/live_trail_applier.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

final _log = Logger('LiveTrailBridge');

/// Headless widget painting the live dashed raw-GPS trail during recording.
///
/// Renders `const SizedBox.shrink()`. Mount as a zero-size [Positioned] in
/// `MapScreen` outside the `isMapTab` block (same pattern as
/// `CoverageOverlayBridge` / `TrackingCameraSync`).
class LiveTrailBridge extends ConsumerStatefulWidget {
  const LiveTrailBridge({super.key});

  @override
  ConsumerState<LiveTrailBridge> createState() => _LiveTrailBridgeState();
}

class _LiveTrailBridgeState extends ConsumerState<LiveTrailBridge> {
  /// Accumulated raw GPS trail for the active recording. Cleared on stop.
  final List<LatLng> _trail = <LatLng>[];

  /// True once the source+layer have been added on the current style. Reset on
  /// every style-load tick (setStyle wipes sources — Pitfall 1) and on stop.
  bool _sourceAdded = false;

  /// Style-load tick sentinel (see `CoverageOverlayBridge`).
  int _lastTick = -1;

  bool _styleReady = false;

  @override
  Widget build(BuildContext context) {
    final tick = ref.watch(mapStyleLoadedTickProvider);
    if (tick != _lastTick) {
      _lastTick = tick;
      _styleReady = true;
      // A (re)loaded style wiped our source — re-add from the accumulated
      // trail so the dashed line survives a light/dark brightness swap.
      _sourceAdded = false;
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
    _trail.add(LatLng(fix.lat, fix.lon));
    if (!_styleReady) return;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(liveTrailApplierProvider);
    if (!_sourceAdded) {
      // We render one fix BEHIND (see _renderTrail), so the rendered set only
      // reaches the 2-point LineString minimum once 3 fixes have accumulated.
      if (_trail.length < 3) return;
      _sourceAdded = true;
      _dispatch(
        () => applier.addOrUpdate(controller, _renderTrail(), colorHex: _coverageColorHex()),
        'addOrUpdate(initial)',
      );
    } else {
      _dispatch(
        () => applier.addOrUpdate(controller, _renderTrail(), colorHex: _coverageColorHex()),
        'addOrUpdate',
      );
    }
  }

  void _onStop() {
    _trail.clear();
    _sourceAdded = false;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(liveTrailApplierProvider);
    _dispatch(() => applier.remove(controller), 'remove');
  }

  /// Re-add after a style reload if we still have a trail to draw.
  void _scheduleReadd() {
    // Rendered set is one fix behind, so we need 3 accumulated points to have
    // the 2-point LineString minimum.
    if (_trail.length < 3) return;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(liveTrailApplierProvider);
    _sourceAdded = true;
    _dispatch(
      () => applier.addOrUpdate(controller, _renderTrail(), colorHex: _coverageColorHex()),
      'addOrUpdate(re-add)',
    );
  }

  /// The trail to render: all accumulated fixes EXCEPT the last one, so the
  /// live line tip sits one fix behind the true position. The native MapLibre
  /// puck follows the true position closely but slightly behind its own
  /// cadence; drawing the line one fix back makes the tip and the puck
  /// visually coincide (a single dot at the tip) rather than the line racing
  /// ahead of the puck. No data is lost — post-trip coverage is rebuilt from
  /// the full point set in the DB by the matcher.
  List<LatLng> _renderTrail() =>
      List<LatLng>.unmodifiable(_trail.sublist(0, _trail.length - 1));

  /// Current coverage color as a `#RRGGBB` hex, matching the persistent
  /// coverage overlay, so the live line looks identical to what finalizes
  /// post-trip. Reads the same preset + platform brightness the overlay uses.
  String _coverageColorHex() {
    final preset = ref.read(coveragePresetValueProvider);
    final brightness =
        View.of(context).platformDispatcher.platformBrightness;
    return preset.forBrightness(brightness).fullHex;
  }

  void _dispatch(Future<void> Function() action, String label) {
    unawaited(action().catchError((Object e, StackTrace st) {
      _log.warning('LiveTrailBridge: $label threw — map kept stable.', e, st);
    }));
  }
}
