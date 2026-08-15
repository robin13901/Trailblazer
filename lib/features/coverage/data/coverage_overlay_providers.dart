// Trailblazer coverage overlay providers.
//
// 2026-07-18 (clipped-geometry rework): rendered from driven_way_intervals.
// 2026-08-15 (v10 durable geometry): resolver reads from driven_way_geometry
// table instead of the volatile Overpass tile cache — no network on render.
//
// Live-refresh chain:
//   match writes driven_way_intervals + driven_way_geometry rows
//     → drivenWayIntervalsRevisionProvider advances
//     → drivenWayGeometryRevisionProvider advances (new way rows added)
//     → coverageOverlayDataProvider re-resolves (clip on compute isolate)
//     → CoverageOverlayBridge re-applies the GeoJSON overlay
//
// All plain Provider / StreamProvider — no @Riverpod codegen (STATE 01-01).

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/coverage_line_cache_dao.dart';
import 'package:auto_explore/core/db/daos/driven_way_geometry_dao.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLngBounds;

/// Singleton [DrivenWayIntervalsDao].
final drivenWayIntervalsDaoProvider = Provider<DrivenWayIntervalsDao>((ref) {
  return DrivenWayIntervalsDao(ref.watch(appDatabaseProvider));
});

/// Singleton [CoverageLineCacheDao] — kept for schema v9 compatibility;
/// no longer actively written by the resolver in v10.
final coverageLineCacheDaoProvider = Provider<CoverageLineCacheDao>((ref) {
  return CoverageLineCacheDao(ref.watch(appDatabaseProvider));
});

/// Singleton [DrivenWayGeometryDao] — durable per-way OSM geometry (v10).
final drivenWayGeometryDaoProvider = Provider<DrivenWayGeometryDao>((ref) {
  return DrivenWayGeometryDao(ref.watch(appDatabaseProvider));
});

/// Singleton [DrivenWayGeometryResolver] — clips driven ways to their union
/// intervals using geometry from the durable DB table (no network).
final drivenWayGeometryResolverProvider = Provider<DrivenWayGeometryResolver>((
  ref,
) {
  return DrivenWayGeometryResolver(
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
    geometryDao: ref.watch(drivenWayGeometryDaoProvider),
  );
});

/// Reactive stream of the union bounding-box of all matched/confirmed trips.
final tripsUnionBoundsProvider = StreamProvider<LatLngBounds?>((ref) {
  return ref.watch(tripsDaoProvider).watchUnionBbox();
});

/// Strictly-monotonic revision of `driven_way_intervals`.
/// Re-runs coverageOverlayDataProvider on every interval write.
final drivenWayIntervalsRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(drivenWayIntervalsDaoProvider).watchRevision();
});

/// Row count of `driven_way_geometry` — advances whenever new way geometry
/// is added (e.g. after a match or backfill). Triggers overlay re-resolve
/// so newly cached ways appear live without an app restart.
final drivenWayGeometryRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(drivenWayGeometryDaoProvider).watchRevision();
});

/// Reactive coverage overlay data for the map.
///
/// Re-resolves on interval writes ([drivenWayIntervalsRevisionProvider]) OR
/// geometry additions ([drivenWayGeometryRevisionProvider]). The resolver
/// reads geometry from the durable DB table — instant, no network.
final coverageOverlayDataProvider = StreamProvider<CoverageOverlayData>((
  ref,
) async* {
  final boundsAsync = ref.watch(tripsUnionBoundsProvider);
  ref
    ..watch(drivenWayIntervalsRevisionProvider)
    ..watch(drivenWayGeometryRevisionProvider);
  final bounds = boundsAsync.value;
  if (bounds == null) {
    yield CoverageOverlayData.empty;
    return;
  }
  final resolver = ref.watch(drivenWayGeometryResolverProvider);
  yield await resolver.resolve(bounds);
});
