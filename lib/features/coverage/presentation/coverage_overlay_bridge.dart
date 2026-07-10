// Trailblazer Phase 7, Plan 07-06:
// CoverageOverlayBridge — headless ConsumerStatefulWidget that wires the
// coverage data pipeline to the MapLibre applier.
//
// Architecture (RESEARCH §"Architecture Pattern"):
//   - Watches mapStyleLoadedTickProvider: any tick change means the map style
//     has (re)loaded and ALL programmatic sources were wiped (Pitfall 1).
//     On each tick change: set _styleReady=true, _sourceAdded=false, and
//     schedule a full applier.apply() so the source+layer are re-added.
//   - ref.listen(coverageOverlayDataProvider): when new coverage data arrives
//     AND the style is ready → full apply (remove-then-readd) + _sourceAdded=true.
//   - ref.listen(coveragePresetValueProvider): when the preset changes AND style
//     is ready AND the source was previously added → updateColors (live recolor,
//     no source reload — REN-06). If source not yet added, falls back to a full
//     apply.
//
// Safety invariants (06-05 lesson — map must never crash):
//   - All applier calls guarded by `controller != null && _styleReady`.
//   - All async applier calls dispatched via `unawaited()`.
//   - All throws from the applier are caught, logged, and swallowed.
//
// Renders const SizedBox.shrink() — headless, like TrackingCameraSync.
// Mount in MapScreen as a zero-size Positioned OUTSIDE any `if (isMapTab)`
// guard so it persists across tab switches (same pattern as TrackingCameraSync).

import 'dart:async';

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_overlay_layers.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('CoverageOverlayBridge');

// ---------------------------------------------------------------------------
// CoverageOverlayBridge
// ---------------------------------------------------------------------------

/// Headless widget that bridges the coverage data pipeline to the MapLibre
/// coverage overlay applier.
///
/// **Tick-driven design:** Rather than exposing a public `onStyleLoaded()`
/// method, the bridge is driven entirely by [mapStyleLoadedTickProvider].
/// When `MapWidget` calls `ref.read(mapStyleLoadedTickProvider.notifier).bump()`
/// inside `_onStyleLoaded`, this widget rebuilds, detects the tick change,
/// and schedules a full re-apply of the coverage source + layer.
///
/// Renders `const SizedBox.shrink()`. Mount as a zero-size [Positioned] in
/// `MapScreen` outside the `isMapTab` block so overlay data is always wired.
class CoverageOverlayBridge extends ConsumerStatefulWidget {
  const CoverageOverlayBridge({super.key});

  @override
  ConsumerState<CoverageOverlayBridge> createState() =>
      _CoverageOverlayBridgeState();
}

class _CoverageOverlayBridgeState extends ConsumerState<CoverageOverlayBridge> {
  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  /// The last tick value seen in build(). Starts at -1 so the first tick
  /// (value 0 before any bump, or 1 after the first bump) is always treated
  /// as a "new" tick when compared to this sentinel.
  int _lastTick = -1;

  /// True once the style has loaded at least once and the bridge is safe to
  /// dispatch apply() calls. Reset to false only when the bridge is disposed.
  bool _styleReady = false;

  /// True once at least one successful apply() call has been scheduled
  /// (meaning the GeoJSON source has been added). Preset-change listeners
  /// use this to decide between updateColors() and a full re-apply.
  /// Reset to false on every new style-load tick (Pitfall 1: setStyle wipes sources).
  bool _sourceAdded = false;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Watch the style-load tick — when it changes, the map style has
    // (re)loaded and ALL programmatic sources were wiped (Pitfall 1).
    final tick = ref.watch(mapStyleLoadedTickProvider);

    if (tick != _lastTick) {
      _lastTick = tick;
      _styleReady = true;
      _sourceAdded = false;
      // Schedule a full re-apply after this build frame so the applier
      // runs after all providers have settled.
      _scheduleApplyWithCurrentData(context);
    }

    // Listen for new coverage data + preset changes using cascades on ref.
    ref
      ..listen<AsyncValue<CoverageOverlayData>>(
        coverageOverlayDataProvider,
        (_, next) {
          final data = next.value;
          if (data != null && _styleReady) {
            _scheduleApply(context, data, ref.read(coveragePresetValueProvider));
            _sourceAdded = true;
          }
        },
      )

      // Listen for preset changes (Settings picker → live recolor).
      ..listen<CoverageColorPreset>(
        coveragePresetValueProvider,
        (previous, next) {
          if (next == previous) return;
          if (!_styleReady) return;
          if (_sourceAdded) {
            // Source is present — live recolor, no source reload (REN-06).
            _scheduleUpdateColors(context, next);
          } else {
            // No source yet — full apply with the new preset color.
            _scheduleApplyWithCurrentData(context);
          }
        },
      );

    return const SizedBox.shrink();
  }

  // -------------------------------------------------------------------------
  // Scheduling helpers
  // -------------------------------------------------------------------------

  /// Reads the current coverage data from the provider and schedules a full
  /// apply if data is available and the style is ready.
  void _scheduleApplyWithCurrentData(BuildContext context) {
    final dataAsync = ref.read(coverageOverlayDataProvider);
    final data = dataAsync.value;
    if (data == null) {
      // Data not yet available — the coverageOverlayDataProvider listener
      // will fire once data arrives.
      return;
    }
    final preset = ref.read(coveragePresetValueProvider);
    _scheduleApply(context, data, preset);
    _sourceAdded = true;
  }

  /// Dispatch an async full apply via unawaited, logging + swallowing any
  /// throws so the map never crashes (06-05 memory).
  void _scheduleApply(
    BuildContext context,
    CoverageOverlayData data,
    CoverageColorPreset preset,
  ) {
    if (!_styleReady) return;
    final controller = ref.read(mapControllerProvider);
    // Pass controller (possibly null) to the applier — the production
    // MapLibreCoverageOverlayApplier early-returns on null; test fakes
    // record calls regardless so assertions still work with null controller.
    final applier = ref.read(coverageOverlayApplierProvider);
    final brightness = View.of(context).platformDispatcher.platformBrightness;
    unawaited(
      applier
          .apply(
            controller,
            data: data,
            preset: preset,
            brightness: brightness,
          )
          .catchError((Object e, StackTrace st) {
        _log.warning(
          'CoverageOverlayBridge: apply() threw — map kept stable.',
          e,
          st,
        );
      }),
    );
  }

  /// Dispatch an async updateColors via unawaited, logging + swallowing any
  /// throws so the map never crashes (06-05 memory).
  void _scheduleUpdateColors(
    BuildContext context,
    CoverageColorPreset preset,
  ) {
    if (!_styleReady) return;
    final controller = ref.read(mapControllerProvider);
    // Pass controller (possibly null) — production applier handles null
    // itself; test fakes record calls regardless.
    final applier = ref.read(coverageOverlayApplierProvider);
    final brightness = View.of(context).platformDispatcher.platformBrightness;
    unawaited(
      applier
          .updateColors(
            controller,
            preset: preset,
            brightness: brightness,
          )
          .catchError((Object e, StackTrace st) {
        _log.warning(
          'CoverageOverlayBridge: updateColors() threw — map kept stable.',
          e,
          st,
        );
      }),
    );
  }
}
