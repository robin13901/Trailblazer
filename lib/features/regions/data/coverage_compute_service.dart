// Trailblazer Phase 8, Plan 08-02 (Wave 1):
// CoverageComputeService — FIRST production writer of the `coverage_cache`
// table. Iterates all driven intervals + all cached Kfz way geometry,
// attributes each way to its containing admin region at levels 4/6/8/9/10,
// and upserts `driven_length_m` + `total_length_m` per region.
//
// Algorithm mirrors RESEARCH.md §Pattern 1 (lines 124-145):
//   1. Ensure admin bundle loaded (MAIN isolate — asset bundle not
//      reachable off-isolate, Pitfall 1).
//   2. One-shot union bbox from TripsDao.watchUnionBbox().first.
//   3. Sweep-line driven length via drivenLengthMeters (interval_union.dart).
//   4. Haversine total length (same helper as DrivenWayGeometryResolver).
//   5. Region attribution via AdminRegionLookup.regionAt — 5 levels,
//      level 2 EXCLUDED (Pitfall 2).
//   6. deleteAll then upsert every region that has any total length.
//
// Never throws — wraps at DomainError boundary and returns Err.

import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Admin levels attributed during the recompute pass.
///
/// Level 2 (country) is intentionally excluded: the DE country row would
/// accumulate every driven meter and its total would be the entire German
/// road network — useful only to say "I've driven 0.001% of Germany", which
/// is not a meaningful Phase-8 display (RESEARCH.md Pitfall 2).
/// Level 9 is INCLUDED — Ortsteil-level granularity is in scope per
/// RESEARCH.md line 263.
const List<int> kComputeAdminLevels = [4, 6, 8, 9, 10];

/// Recomputes `coverage_cache` for all admin regions at levels 4/6/8/9/10.
///
/// Injected with the same set of collaborators as `DrivenWayGeometryResolver`
/// plus an [AdminRegionLookup] and [CoverageCacheDao].
///
/// This class is STATELESS — [recompute] reads fresh from each DAO/source on
/// every call. All writes go through [CoverageCacheDao.upsert].
class CoverageComputeService {
  CoverageComputeService({
    required DrivenWayIntervalsDao intervalsDao,
    required WayCandidateSource waySource,
    required AdminRegionLookup regionLookup,
    required CoverageCacheDao cacheDao,
    required TripsDao tripsDao,
    Logger? logger,
  })  : _intervalsDao = intervalsDao,
        _waySource = waySource,
        _regionLookup = regionLookup,
        _cacheDao = cacheDao,
        _tripsDao = tripsDao,
        _log = logger ?? Logger('CoverageComputeService');

  final DrivenWayIntervalsDao _intervalsDao;
  final WayCandidateSource _waySource;
  final AdminRegionLookup _regionLookup;
  final CoverageCacheDao _cacheDao;
  final TripsDao _tripsDao;
  final Logger _log;

  /// Recompute and upsert coverage statistics for every admin region that
  /// has any matched/confirmed Kfz ways. Returns the number of rows written.
  ///
  /// Error posture: never throws. Non-DomainError exceptions are wrapped via
  /// [DomainError.wrap] and returned as [Err].
  Future<Result<int>> recompute() async {
    try {
      // Step 1: Ensure admin bundle is loaded on the MAIN isolate.
      // Asset bundle is not reachable off-isolate (Pitfall 1).
      await _regionLookup.ensureLoaded();

      // Step 2: One-shot union bbox — null means no trips → empty cache is
      // the correct state (no trips driven = no coverage to display).
      final bounds = await _tripsDao.watchUnionBbox().first;
      if (bounds == null) {
        await _cacheDao.deleteAll();
        _log.fine('recompute: no union bbox (no trips) — cleared cache');
        return const Ok(0);
      }

      // Step 3: Read all intervals, group by wayId in Dart.
      // (Avoids fragile SQL GROUP_CONCAT — mirrors resolver lines 83-88.)
      final allIntervals = await _intervalsDao.getAllIntervals();
      final byWayId = <int, List<Interval>>{};
      for (final row in allIntervals) {
        byWayId
            .putIfAbsent(row.wayId, () => [])
            .add(Interval(row.startMeters, row.endMeters));
      }

      // Step 4: Cache-first geometry for the union bbox.
      // throwOnError:false → offline gap returns whatever is cached.
      final ways = await _waySource.fetchWaysInBbox(
        minLat: bounds.southwest.latitude,
        minLon: bounds.southwest.longitude,
        maxLat: bounds.northeast.latitude,
        maxLon: bounds.northeast.longitude,
        throwOnError: false,
      );

      // Step 5: Accumulate total + driven lengths per region_id.
      // Keys are OSM relation IDs as strings — globally unique across
      // levels (RESEARCH.md line 491 — do NOT prefix with "$level:").
      final total = <String, double>{};
      final driven = <String, double>{};
      var processed = 0;

      for (final way in ways) {
        final c = _centroid(way.geometry);
        if (c == null) continue; // degenerate empty geometry — skip
        final wayLen = _polylineLengthMeters(way.geometry);
        final unionLen = byWayId.containsKey(way.wayId)
            ? drivenLengthMeters(byWayId[way.wayId]!)
            : 0.0;

        for (final level in kComputeAdminLevels) {
          final region = await _regionLookup.regionAt(c.latitude, c.longitude, level);
          if (region == null) continue;
          final id = region.osmId.toString();
          total[id] = (total[id] ?? 0) + wayLen;
          if (unionLen > 0) driven[id] = (driven[id] ?? 0) + unionLen;
        }

        // Pitfall 3: regionAt is sync-fast after load but yield periodically
        // so a large way set never starves the UI thread.
        processed++;
        if (processed % 250 == 0) await Future<void>.delayed(Duration.zero);
      }

      // Step 6: Wipe stale rows, then upsert every region with total length.
      // deleteAll first so a region that dropped to 0 coverage disappears.
      await _cacheDao.deleteAll();
      final now = DateTime.now();
      var written = 0;
      for (final id in total.keys) {
        await _cacheDao.upsert(
          regionId: id,
          drivenLengthM: driven[id] ?? 0,
          totalLengthM: total[id]!,
          updatedAt: now,
          // extractVersion: null — Phase 10 wires this; null is the default
        );
        written++;
      }

      _log.info(
        'recompute: ${ways.length} ways processed, $written regions written',
      );
      return Ok(written);

      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('recompute: unexpected error', e, st);
      return Err(DomainError.wrap(e, st));
    }
  }
}

/// Mean lat/lon of [geometry]. Returns null for empty geometry.
LatLng? _centroid(List<LatLng> geometry) {
  if (geometry.isEmpty) return null;
  var sumLat = 0.0;
  var sumLon = 0.0;
  for (final p in geometry) {
    sumLat += p.latitude;
    sumLon += p.longitude;
  }
  return LatLng(sumLat / geometry.length, sumLon / geometry.length);
}

/// Haversine sum of consecutive point distances along [geometry].
///
/// Mirrors `_polylineLengthMeters` from `driven_way_geometry_resolver.dart`
/// (lines 156-167). Duplicated here to avoid importing a data-layer private
/// function across package boundaries.
double _polylineLengthMeters(List<LatLng> geometry) {
  var total = 0.0;
  for (var i = 0; i < geometry.length - 1; i++) {
    total += haversineMeters(
      geometry[i].latitude,
      geometry[i].longitude,
      geometry[i + 1].latitude,
      geometry[i + 1].longitude,
    );
  }
  return total;
}
