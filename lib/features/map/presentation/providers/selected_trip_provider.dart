// Trailblazer trip-path overlay:
// selectedTripProvider — holds the id of the trip currently shown on the shared
// Map tab (turquoise on-road line), or null when none.
//
// Mirrors regionOutlineProvider: the TripDetailSheet's "Auf Karte anzeigen"
// button calls show(tripId); the on-map dismiss chip calls clear(). The
// TripPathBridge (mounted in MapScreen) watches this, loads the trip geometry
// via tripDetailDataProvider, and drives the MapLibre layers.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the trip id whose path is drawn on the map, or null when none.
class SelectedTripNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  /// Show [tripId]'s on-road path on the map. Replaces any current selection.
  // ignore: use_setters_to_change_properties — semantic "show" verb, not a setter
  void show(int tripId) => state = tripId;

  /// Clear the trip overlay (dismiss chip tap). Idempotent.
  void clear() => state = null;
}

final selectedTripProvider =
    NotifierProvider<SelectedTripNotifier, int?>(SelectedTripNotifier.new);
