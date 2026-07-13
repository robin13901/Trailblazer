// Trailblazer coverage overlay providers.
//
// 2026-07-13 (coverage-from-trail rework): the persistent coverage line is now
// the trimmed on-road raw-GPS trail stored per trip in `trips.coverage_path_json`
// (written by TripMatchCoordinator). This replaces the previous
// matched-OSM-way geometry source (DrivenWayGeometryResolver), which produced
// intersection gaps and relied on the light-gradient partial-driven shading the
// user asked to remove. Road-matched `driven_way_intervals` remain the source
// for region-km math (CoverageComputeService) — matching is now technical-only,
// not visual.
//
// Live-refresh chain:
//   match/re-match writes coverage_path_json
//     → TripsDao.watchCoveragePaths() re-emits
//     → coveragePathsProvider emits
//     → coverageOverlayDataProvider rebuilds
//     → CoverageOverlayBridge re-applies the GeoJSON overlay
//
// All plain Provider / StreamProvider — no @Riverpod codegen (STATE 01-01).

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/coverage_path_codec.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

/// Singleton [DrivenWayIntervalsDao] — plain `Provider<T>` per STATE 01-01.
///
/// Retained for region-km math and any consumers that still read matched
/// intervals directly. The visible overlay no longer uses it.
final drivenWayIntervalsDaoProvider = Provider<DrivenWayIntervalsDao>((ref) {
  return DrivenWayIntervalsDao(ref.watch(appDatabaseProvider));
});

/// Singleton [DrivenWayGeometryResolver]. Retained for tests / potential reuse;
/// no longer on the visible-overlay path (kept to avoid a wider refactor).
final drivenWayGeometryResolverProvider =
    Provider<DrivenWayGeometryResolver>((ref) {
  return DrivenWayGeometryResolver(
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
    waySource: ref.watch(wayCandidateSourceProvider),
  );
});

/// Reactive stream of every trip's stored coverage-path JSON (non-empty only).
final coveragePathsProvider = StreamProvider<List<String>>((ref) {
  return ref.watch(tripsDaoProvider).watchCoveragePaths();
});

/// Reactive stream of the union bounding-box of all matched/confirmed trips.
///
/// No longer drives the visible overlay (2026-07-13 rework) but retained for
/// consumers that reason about the driven extent. Emits `null` when no trips
/// with bbox columns exist.
final tripsUnionBoundsProvider = StreamProvider<LatLngBounds?>((ref) {
  return ref.watch(tripsDaoProvider).watchUnionBbox();
});

/// Reactive coverage overlay data for the map, built from the trimmed on-road
/// trail segments persisted per trip.
///
/// Each stored polyline segment becomes one [CoverageWay] with a full
/// (`isFull: true`) datum so it renders as a solid line — there is no longer a
/// partial-driven gradient. The `wayId` here is a synthetic running index
/// (the segments are not OSM ways); it exists only to key the GeoJSON feature.
///
/// Yields [CoverageOverlayData.empty] when no trip has a stored path yet.
final coverageOverlayDataProvider =
    StreamProvider<CoverageOverlayData>((ref) async* {
  final pathsAsync = ref.watch(coveragePathsProvider);
  final paths = pathsAsync.value;
  if (paths == null || paths.isEmpty) {
    yield CoverageOverlayData.empty;
    return;
  }

  final ways = <CoverageWay>[];
  var syntheticId = 0;
  for (final json in paths) {
    for (final segment in decodeCoveragePath(json)) {
      if (segment.length < 2) continue;
      ways.add(
        CoverageWay(
          wayId: syntheticId++,
          geometry: [
            for (final p in segment) LatLng(p[0], p[1]),
          ],
          // Solid — full coverage, no partial gradient (2026-07-13).
          datum: const CoverageDatum(fraction: 1, isFull: true),
        ),
      );
    }
  }
  yield CoverageOverlayData(ways);
});
