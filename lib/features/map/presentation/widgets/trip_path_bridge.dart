// Trailblazer trip-path overlay:
// TripPathBridge — headless ConsumerStatefulWidget that draws the currently
// selected trip's on-road (matched) line on the shared Map tab, in a distinct
// turquoise that is NOT one of the five user-selectable coverage colors
// (amber / green / blue / purple / red).
//
// Shown after "Auf Karte anzeigen" in the TripDetailSheet (which sets
// selectedTripProvider) and dismissed by the on-map X chip (which clears it).
//
// Architecture mirrors RegionOutlineBridge / LiveTrailBridge:
//   - ref.watch(selectedTripProvider): the trip id to draw (null = none).
//   - ref.watch(tripDetailDataProvider(id)): the geometry (matchedSegments),
//     loaded async and cache-first. Only matchedSegments is drawn — it comes
//     from driven_way_intervals (not trip_points), so it survives raw-GPS
//     deletion. Empty when fail-matched / offline → nothing drawn.
//   - ref.watch(mapStyleLoadedTickProvider): a style (re)load wipes all
//     programmatic sources (Pitfall 1); on each tick change we re-add.
//
// Safety invariants (map must never crash):
//   - applier early-returns on a null controller;
//   - all async applier calls dispatched via unawaited() with caught throws.
//
// Renders const SizedBox.shrink(). Mount in MapScreen as a zero-size Positioned
// OUTSIDE any `if (isMapTab)` guard so it persists across tab switches.

import 'dart:async';

import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/selected_trip_provider.dart';
import 'package:auto_explore/features/trips/presentation/providers/trip_path_data_provider.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_overlay_layers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger('TripPathBridge');

/// Trip-path line color in dark mode (bright turquoise). Distinct from every
/// coverage preset (amber/green/blue/purple/red).
const Color kTripPathColorDark = Color(0xFF1DE9B6);

/// Trip-path line color in light mode (deeper teal for contrast on light tiles).
const Color kTripPathColorLight = Color(0xFF00BFA5);

/// Headless widget painting the selected trip's on-road line on the map.
///
/// Renders `const SizedBox.shrink()`. Mount as a zero-size [Positioned] in
/// `MapScreen` outside the `isMapTab` block (same pattern as
/// `RegionOutlineBridge` / `LiveTrailBridge`).
class TripPathBridge extends ConsumerStatefulWidget {
  const TripPathBridge({super.key});

  @override
  ConsumerState<TripPathBridge> createState() => _TripPathBridgeState();
}

class _TripPathBridgeState extends ConsumerState<TripPathBridge> {
  /// Trip id currently drawn on the map (null = none).
  int? _appliedTripId;

  /// Style-load tick sentinel (see `RegionOutlineBridge`).
  int _lastTick = -1;

  @override
  Widget build(BuildContext context) {
    final tick = ref.watch(mapStyleLoadedTickProvider);
    final tickChanged = tick != _lastTick;
    if (tickChanged) _lastTick = tick;

    final id = ref.watch(selectedTripProvider);

    if (id == null) {
      // Deselected — remove whatever was drawn.
      final prev = _appliedTripId;
      if (prev != null) {
        _appliedTripId = null;
        _remove(prev);
      }
      return const SizedBox.shrink();
    }

    // A trip is selected — draw it once its geometry resolves. Re-draw when the
    // trip changes OR a style reload wiped the layers (tick change).
    ref.watch(tripDetailDataProvider(id)).whenData((data) {
      if (_appliedTripId != id || tickChanged) {
        final prev = _appliedTripId;
        if (prev != null && prev != id) _remove(prev);
        _appliedTripId = id;
        _apply(id, data);
      }
    });

    return const SizedBox.shrink();
  }

  void _apply(int tripId, TripDetailData data) {
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(tripOverlayApplierProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? kTripPathColorDark : kTripPathColorLight;
    _dispatch(() async {
      // Remove-then-add so a repeat (style reload) doesn't hit "source exists".
      await applier.removeTripOverlay(controller, tripId);
      await applier.addMatchedIntervalLayers(
        controller,
        tripId: tripId,
        matchedSegments: data.matchedSegments,
        color: color,
      );
    }, 'apply');
  }

  void _remove(int tripId) {
    final controller = ref.read(mapControllerProvider);
    final applier = ref.read(tripOverlayApplierProvider);
    _dispatch(() => applier.removeTripOverlay(controller, tripId), 'remove');
  }

  void _dispatch(Future<void> Function() action, String label) {
    unawaited(action().catchError((Object e, StackTrace st) {
      _log.warning('TripPathBridge: $label threw — map kept stable.', e, st);
    }));
  }
}
