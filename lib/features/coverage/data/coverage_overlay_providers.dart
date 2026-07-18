// Trailblazer coverage overlay providers.
//
// 2026-07-18 (clipped-geometry rework): the persistent coverage overlay is
// rendered from `driven_way_intervals` — each driven OSM way CLIPPED to the
// sub-interval(s) actually driven, deduped per wayId across ALL trips (see
// DrivenWayGeometryResolver). This replaces the per-trip snapped-GPS-chord line
// (`trips.coverage_path_json`), which drew straight chords between snapped fixes
// (triangles/fans/zigzags at junctions) and one polyline PER TRIP (N drives of a
// road = N overlapping lines). The clipped-way model draws the road's true OSM
// shape, once per way — no chord artifacts, natural cross-trip dedup.
//
// Live-refresh chain:
//   match/re-match writes driven_way_intervals
//     → TripsDao.watchUnionBbox() re-emits (readsFrom: {trips, drivenWayIntervals})
//     → coverageOverlayDataProvider re-resolves (parse+clip on a compute isolate)
//     → CoverageOverlayBridge re-applies the GeoJSON overlay
//
// All plain Provider / StreamProvider — no @Riverpod codegen (STATE 01-01).

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLngBounds;

/// Singleton [DrivenWayIntervalsDao] — plain `Provider<T>` per STATE 01-01.
final drivenWayIntervalsDaoProvider = Provider<DrivenWayIntervalsDao>((ref) {
  return DrivenWayIntervalsDao(ref.watch(appDatabaseProvider));
});

/// Singleton [DrivenWayGeometryResolver] — parses cached tiles + clips driven
/// ways to their union intervals on a compute isolate.
final drivenWayGeometryResolverProvider =
    Provider<DrivenWayGeometryResolver>((ref) {
  return DrivenWayGeometryResolver(
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
    waySource: ref.watch(wayCandidateSourceProvider),
  );
});

/// Reactive stream of the union bounding-box of all matched/confirmed trips.
///
/// Emits `null` when no trips with bbox columns exist. Its `readsFrom` set
/// includes `drivenWayIntervals`, so it re-emits whenever intervals are written
/// (a new match / re-match) — the reactive trigger for the overlay.
final tripsUnionBoundsProvider = StreamProvider<LatLngBounds?>((ref) {
  return ref.watch(tripsDaoProvider).watchUnionBbox();
});

/// Reactive coverage overlay data for the map: each driven OSM way clipped to
/// its driven union interval(s), deduped per wayId across all trips.
///
/// Re-resolves whenever [tripsUnionBoundsProvider] emits (interval writes). The
/// resolver parses + clips on a compute isolate, so no heavy work runs on the
/// UI isolate here. Yields [CoverageOverlayData.empty] when there are no trips.
final coverageOverlayDataProvider =
    StreamProvider<CoverageOverlayData>((ref) async* {
  final boundsAsync = ref.watch(tripsUnionBoundsProvider);
  final bounds = boundsAsync.value;
  if (bounds == null) {
    yield CoverageOverlayData.empty;
    return;
  }
  final resolver = ref.watch(drivenWayGeometryResolverProvider);
  yield await resolver.resolve(bounds);
});
