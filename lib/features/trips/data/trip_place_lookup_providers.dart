// Trailblazer Phase 6, Plan 06-02 Task 1:
// Riverpod wiring for the trip-place reverse-geocoder.

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_place_lookup.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Singleton [TripPlaceLookup] wrapping the shared `AdminRegionLookup`.
///
/// Plain `Provider<T>` per STATE 01-01 (no Riverpod codegen).
final tripPlaceLookupProvider = Provider<TripPlaceLookup>((ref) {
  return TripPlaceLookup(ref.watch(adminRegionLookupProvider));
});

/// Coordinate tuple passed to [tripPlacesProvider]. Extracted as a named
/// record so widget-tree callers can construct it inline without helpers.
typedef TripPlacesCoords = ({
  double startLat,
  double startLon,
  double endLat,
  double endLon,
});

/// Memoized per-coordinate reverse-geocode lookup. UI reads a trip's
/// coordinates from a `TripListItem` and passes them here; identical
/// coord tuples across cards share the same computation.
///
/// The provider's concrete type (`FutureProviderFamily`) is internal to
/// Riverpod, so the type is left inferred here.
// ignore: specify_nonobvious_property_types
final tripPlacesProvider =
    FutureProvider.family<TripPlaces, TripPlacesCoords>((ref, coords) async {
  final lookup = ref.watch(tripPlaceLookupProvider);
  return lookup.lookup(
    startLat: coords.startLat,
    startLon: coords.startLon,
    endLat: coords.endLat,
    endLon: coords.endLon,
  );
});
