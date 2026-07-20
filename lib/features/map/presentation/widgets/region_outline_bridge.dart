// Trailblazer region-outline overlay:
// RegionOutlineBridge — headless ConsumerStatefulWidget that draws the currently
// selected region's boundary (faint fill + dashed neutral border) on the map.
//
// Shown after "Auf Karte anzeigen" (RegionDetailSheet sets regionOutlineProvider)
// and dismissed by the on-map X chip (which clears it). Neutral color, NOT the
// coverage accent: a light shade in dark mode, a dark shade in light mode.
//
// Architecture mirrors LiveTrailBridge / CoverageOverlayBridge:
//   - ref.listen(regionOutlineProvider): on show → addOrUpdate; on clear → remove.
//   - ref.watch(mapStyleLoadedTickProvider): a style (re)load wipes all
//     programmatic sources (Pitfall 1), so on each tick change we re-add the
//     source+layers if a region is currently set.
//
// Safety invariants (06-05 lesson — map must never crash):
//   - applier early-returns on a null controller;
//   - all async applier calls dispatched via unawaited() with caught throws.
//
// Renders const SizedBox.shrink(). Mount in MapScreen as a zero-size Positioned
// OUTSIDE any `if (isMapTab)` guard so it persists across tab switches.

import 'dart:async';

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/region_outline_applier.dart';
import 'package:auto_explore/features/map/presentation/providers/region_outline_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('RegionOutlineBridge');

/// Neutral border color in dark mode (light gray/white).
const String kRegionOutlineBorderDarkMode = '#E0E0E0';

/// Neutral border color in light mode (dark gray/black).
const String kRegionOutlineBorderLightMode = '#303030';

/// Neutral fill color in dark mode (white, drawn at [kRegionOutlineFillOpacity]).
const String kRegionOutlineFillDarkMode = '#FFFFFF';

/// Neutral fill color in light mode (black, drawn at [kRegionOutlineFillOpacity]).
const String kRegionOutlineFillLightMode = '#000000';

/// Headless widget painting the selected region's boundary on the map.
///
/// Renders `const SizedBox.shrink()`. Mount as a zero-size [Positioned] in
/// `MapScreen` outside the `isMapTab` block (same pattern as
/// `CoverageOverlayBridge` / `LiveTrailBridge`).
class RegionOutlineBridge extends ConsumerStatefulWidget {
  const RegionOutlineBridge({super.key});

  @override
  ConsumerState<RegionOutlineBridge> createState() =>
      _RegionOutlineBridgeState();
}

class _RegionOutlineBridgeState extends ConsumerState<RegionOutlineBridge> {
  /// Style-load tick sentinel (see `CoverageOverlayBridge`).
  int _lastTick = -1;

  @override
  Widget build(BuildContext context) {
    // A (re)loaded style wiped our source (Pitfall 1) — re-add from the current
    // region so the outline survives a light/dark brightness swap.
    final tick = ref.watch(mapStyleLoadedTickProvider);
    if (tick != _lastTick) {
      _lastTick = tick;
      final region = ref.read(regionOutlineProvider);
      if (region != null) _apply(region);
    }

    // React to show/clear transitions (not every rebuild).
    ref.listen<AdminRegion?>(regionOutlineProvider, (_, next) {
      if (next != null) {
        _apply(next);
      } else {
        _clear();
      }
    });

    return const SizedBox.shrink();
  }

  void _apply(AdminRegion region) {
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(regionOutlineApplierProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderHex =
        isDark ? kRegionOutlineBorderDarkMode : kRegionOutlineBorderLightMode;
    final fillHex =
        isDark ? kRegionOutlineFillDarkMode : kRegionOutlineFillLightMode;
    _dispatch(
      () => applier.addOrUpdate(
        controller,
        region,
        borderHex: borderHex,
        fillHex: fillHex,
      ),
      'addOrUpdate',
    );
  }

  void _clear() {
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(regionOutlineApplierProvider);
    _dispatch(() => applier.remove(controller), 'remove');
  }

  void _dispatch(Future<void> Function() action, String label) {
    unawaited(action().catchError((Object e, StackTrace st) {
      _log.warning('RegionOutlineBridge: $label threw — map kept stable.', e, st);
    }));
  }
}
