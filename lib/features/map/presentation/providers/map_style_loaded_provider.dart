// Trailblazer Phase 7, Plan 07-06:
// mapStyleLoadedTickProvider — style-load signal for CoverageOverlayBridge.
//
// Incremented by MapWidget._onStyleLoaded on EVERY onStyleLoaded callback:
//   * Initial map creation
//   * After each setStyle() brightness swap (light ↔ dark)
//
// Watchers (CoverageOverlayBridge) treat any state change as:
//   "The map style has (re)loaded — programmatic sources and layers were wiped
//    by setStyle(); re-add them now."  (RESEARCH Pitfall 1)
//
// Plain NotifierProvider — no @Riverpod codegen (STATE 01-01).

import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// StyleTickNotifier
// ---------------------------------------------------------------------------

/// Increments a monotonic counter each time the map style (re)loads.
///
/// `bump()` is called by `MapWidget._onStyleLoaded` on every style-loaded event.
/// Consumers watch the tick value and treat any increase as a signal to re-add
/// programmatic map sources and layers (MapLibre wipes them on `setStyle()`).
class StyleTickNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Increment the tick by 1 to signal that the map style has (re)loaded.
  void bump() => state = state + 1;
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Monotonic style-load counter.
///
/// Incremented by `MapWidget` on every `onStyleLoadedCallback` event
/// (initial load AND after each `setStyle()` brightness swap).
///
/// `CoverageOverlayBridge` watches this provider and re-adds the coverage
/// source + layer on every increment, because `setStyle()` wipes all
/// programmatic sources (RESEARCH Pitfall 1).
///
/// Plain [NotifierProvider] — no `@Riverpod` codegen per STATE 01-01.
final mapStyleLoadedTickProvider =
    NotifierProvider<StyleTickNotifier, int>(StyleTickNotifier.new);
