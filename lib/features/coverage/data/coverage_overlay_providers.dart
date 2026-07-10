// Trailblazer Phase 7, Plan 07-03:
// Riverpod wiring for the coverage data layer:
//   * drivenWayIntervalsDaoProvider — DAO singleton
//   * drivenWayGeometryResolverProvider — resolver singleton
//   * tripsUnionBoundsProvider — reactive Drift stream of union bbox
//   * coverageOverlayDataProvider — reactive StreamProvider that re-resolves
//     whenever the union bbox stream emits (trip confirmed mid-session)
//
// All plain Provider / StreamProvider — no @Riverpod codegen (STATE 01-01).
//
// **Live-refresh chain (07-06 truth #3):**
//   confirmTrip (TripsInboxDao.transitionToConfirmed)
//     → trips table write
//     → TripsDao.watchUnionBbox() re-emits  [readsFrom: {trips, drivenWayIntervals}]
//     → tripsUnionBoundsProvider emits new value
//     → coverageOverlayDataProvider rebuilds (StreamProvider watches tripsUnionBoundsProvider)
//     → DrivenWayGeometryResolver.resolve(bounds) runs fresh
//     → 07-06 bridge sees new CoverageOverlayData and re-applies GeoJSON overlay
//
// Why StreamProvider (not FutureProvider) for coverageOverlayDataProvider:
//   A FutureProvider caches its result and does NOT re-run when upstream
//   providers emit — only StreamProvider re-evaluates on each watch change.
//   Using FutureProvider here would make the overlay stale after a trip
//   confirmation mid-session, breaking 07-06 truth #3.

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLngBounds;

/// Singleton [DrivenWayIntervalsDao] — plain `Provider<T>` per STATE 01-01.
///
/// Backed by `appDatabaseProvider` (the singleton `AppDatabase`).
/// Phase-5 matching providers construct their own instance directly;
/// this provider is the coverage-layer entry point so it doesn't conflict.
final drivenWayIntervalsDaoProvider = Provider<DrivenWayIntervalsDao>((ref) {
  return DrivenWayIntervalsDao(ref.watch(appDatabaseProvider));
});

/// Singleton [DrivenWayGeometryResolver].
///
/// Injects the [DrivenWayIntervalsDao] singleton and the runtime
/// `WayCandidateSource` (cache-first `OverpassWayCandidateSource`).
/// Tests override `wayCandidateSourceProvider` with a fake implementation.
final drivenWayGeometryResolverProvider =
    Provider<DrivenWayGeometryResolver>((ref) {
  return DrivenWayGeometryResolver(
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
    waySource: ref.watch(wayCandidateSourceProvider),
  );
});

/// Reactive stream of the union bounding-box of all matched/confirmed trips.
///
/// Backed by `TripsDao.watchUnionBbox` — see that method's doc-comment for
/// the full reactivity rationale. Emits `null` when no trips with bbox columns
/// exist.
///
/// This is a [StreamProvider], NOT a [FutureProvider], so it re-evaluates
/// on every new Drift emission.
final tripsUnionBoundsProvider = StreamProvider<LatLngBounds?>((ref) {
  return ref.watch(tripsDaoProvider).watchUnionBbox();
});

/// Reactive coverage overlay data for the map.
///
/// Re-resolves whenever [tripsUnionBoundsProvider] emits — i.e. whenever a
/// trip is confirmed, matched, or its bbox/intervals change. See the
/// live-refresh chain at the top of this file.
///
/// Yields [CoverageOverlayData.empty] when:
///   * No trips with bbox data exist (`bounds == null`).
///   * All geometries are cache-misses (offline with empty cache).
///   * An unexpected error occurs in the resolver (degrades gracefully).
///
/// **This must be a [StreamProvider].** A FutureProvider caches and will NOT
/// re-run when tripsUnionBoundsProvider emits new values mid-session,
/// breaking the live-refresh requirement of 07-06 truth #3.
final coverageOverlayDataProvider =
    StreamProvider<CoverageOverlayData>((ref) async* {
  final boundsAsync = ref.watch(tripsUnionBoundsProvider);
  final bounds = boundsAsync.value;
  if (bounds == null) {
    yield CoverageOverlayData.empty;
    return;
  }
  yield await ref.watch(drivenWayGeometryResolverProvider).resolve(bounds);
});
