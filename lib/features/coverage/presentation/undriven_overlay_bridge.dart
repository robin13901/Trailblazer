// Trailblazer undriven-ways overlay:
// UndrivenOverlayBridge — headless ConsumerStatefulWidget that wires the
// on-demand undriven-ways data to its own MapLibre source+layer (blue).
//
// Mirrors CoverageOverlayBridge but drives the INDEPENDENT undriven applier
// (`undriven_overlay` / `undriven_layer`) from:
//   - undrivenOverlayControllerProvider (AsyncValue<CoverageOverlayData>): the
//     ad-hoc result of "show undriven roads for this region". AsyncData → apply
//     (empty data clears the layer visually); AsyncLoading → leave as-is.
//   - undrivenPresetValueProvider: live recolor on a Settings change.
//   - mapStyleLoadedTickProvider: a style (re)load wipes programmatic sources
//     (Pitfall 1) → re-apply the current data.
//
// Safety invariants (06-05 lesson — map must never crash): applier early-returns
// on null controller; all async calls dispatched via unawaited() with caught
// throws. Renders const SizedBox.shrink(); mount as a zero-size Positioned in
// MapScreen OUTSIDE any isMapTab guard (same pattern as CoverageOverlayBridge).

import 'dart:async';

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/undriven_overlay_providers.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_overlay_layers.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('UndrivenOverlayBridge');

/// Headless widget bridging the undriven-ways data to its own blue overlay.
class UndrivenOverlayBridge extends ConsumerStatefulWidget {
  const UndrivenOverlayBridge({super.key});

  @override
  ConsumerState<UndrivenOverlayBridge> createState() =>
      _UndrivenOverlayBridgeState();
}

class _UndrivenOverlayBridgeState extends ConsumerState<UndrivenOverlayBridge> {
  /// Style-load tick sentinel (see CoverageOverlayBridge).
  int _lastTick = -1;

  /// True once a style has loaded and we may dispatch applier calls.
  bool _styleReady = false;

  /// True once the source has been added under the current style tick.
  bool _sourceAdded = false;

  @override
  Widget build(BuildContext context) {
    final tick = ref.watch(mapStyleLoadedTickProvider);
    if (tick != _lastTick) {
      _lastTick = tick;
      _styleReady = true;
      _sourceAdded = false;
      _scheduleApplyWithCurrentData(context);
    }

    ref
      ..listen<AsyncValue<CoverageOverlayData>>(
        undrivenOverlayControllerProvider,
        (_, next) {
          final data = next.value;
          // Apply only on a settled value (AsyncData). AsyncLoading keeps the
          // previous visual until the result lands. Empty data clears the line.
          if (data != null && _styleReady) {
            _scheduleApply(context, data, ref.read(undrivenPresetValueProvider));
            _sourceAdded = true;
          }
        },
      )
      ..listen<CoverageColorPreset>(
        undrivenPresetValueProvider,
        (previous, next) {
          if (next == previous || !_styleReady) return;
          if (_sourceAdded) {
            _scheduleUpdateColors(context, next);
          } else {
            _scheduleApplyWithCurrentData(context);
          }
        },
      );

    return const SizedBox.shrink();
  }

  void _scheduleApplyWithCurrentData(BuildContext context) {
    final data = ref.read(undrivenOverlayControllerProvider).value;
    if (data == null) return;
    _scheduleApply(context, data, ref.read(undrivenPresetValueProvider));
    _sourceAdded = true;
  }

  void _scheduleApply(
    BuildContext context,
    CoverageOverlayData data,
    CoverageColorPreset preset,
  ) {
    if (!_styleReady) return;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(undrivenOverlayApplierProvider);
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
              'UndrivenOverlayBridge: apply() threw — map kept stable.',
              e,
              st,
            );
          }),
    );
  }

  void _scheduleUpdateColors(BuildContext context, CoverageColorPreset preset) {
    if (!_styleReady) return;
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(undrivenOverlayApplierProvider);
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
              'UndrivenOverlayBridge: updateColors() threw — map kept stable.',
              e,
              st,
            );
          }),
    );
  }
}
