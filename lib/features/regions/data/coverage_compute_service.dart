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
// Phase 10 (Plan 10-05): recomputeForTrip() — incremental auto path.
//   Targeted upsert for only the regions a single new trip's bbox touches.
//   No deleteAll (other regions preserved). Used by the auto-recompute seam
//   wired in matching_providers.dart after intervals land.
//
// Never throws — wraps at DomainError boundary and returns Err.

import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
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
    required RegionTotalsLookup totalsLookup,
    Logger? logger,
  })  : _intervalsDao = intervalsDao,
        _waySource = waySource,
        _regionLookup = regionLookup,
        _cacheDao = cacheDao,
        _tripsDao = tripsDao,
        _totalsLookup = totalsLookup,
        _log = logger ?? Logger('CoverageComputeService');

  final DrivenWayIntervalsDao _intervalsDao;
  final WayCandidateSource _waySource;
  final AdminRegionLookup _regionLookup;
  final CoverageCacheDao _cacheDao;
  final TripsDao _tripsDao;
  final RegionTotalsLookup _totalsLookup;
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

      // Step 1b: Ensure the bundled totals table is loaded. Also runs on the
      // main isolate (same asset-bundle constraint). If the asset is absent
      // (deferred PBF checkpoint not yet run), ensureLoaded() is a no-op and
      // totalFor() will return null for every region — real_total_length_m is
      // then written as null, which the UI renders as "—". No error is raised.
      await _totalsLookup.ensureLoaded();

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
        // real_total_length_m is the BUNDLED per-region Kfz total from
        // region_totals.json.gz (Plan 10-04 Decision 8). This is the
        // authoritative denominator for the region browser % and km stats —
        // it fixes the Bayern==Miltenberg denominator because it covers the
        // full road network of the region, not just the ways near the user's
        // trips. If the bundled asset is absent (PBF checkpoint not yet run),
        // totalFor() returns null and the UI renders "—" rather than a spinner.
        await _cacheDao.upsert(
          regionId: id,
          drivenLengthM: driven[id] ?? 0,
          totalLengthM: total[id]!,
          updatedAt: now,
          realTotalLengthM: _totalsLookup.totalFor(id),
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

  /// Incremental recompute for the AUTO path (Phase 10 Decision 6 / OQ1-PERF).
  ///
  /// Instead of deleting all cache rows and rebuilding from the full union bbox,
  /// this targeted variant:
  ///   1. Loads the trip's bbox (5-point probe — same as CoverageInvalidator).
  ///   2. Finds the admin regions that bbox touches.
  ///   3. Fetches ways ONLY in that bbox (much cheaper than union bbox for a
  ///      single short drive).
  ///   4. Upserts ONLY the affected region rows — no deleteAll, so other
  ///      regions are untouched.
  ///
  /// Correctness guarantee: all existing intervals (not just the new trip's)
  /// are used when computing drivenLengthM for the affected regions, so the
  /// numbers are always the cumulative total. The only correctness hole vs. a
  /// full recompute is that stale rows from deleted trips are not cleaned up
  /// — that is acceptable because explicit deletion goes through the button's
  /// full recompute path (deleteAll + upsert-all).
  ///
  /// Returns the number of region rows upserted. Returns Ok(0) when the trip
  /// has no bbox or touches no regions.
  Future<Result<int>> recomputeForTrip(int tripId) async {
    try {
      await _regionLookup.ensureLoaded();
      await _totalsLookup.ensureLoaded();

      // Load trip bbox.
      final db = _tripsDao.attachedDatabase;
      final tripRow = await (db.select(db.trips)
            ..where((t) => t.id.equals(tripId)))
          .getSingleOrNull();
      if (tripRow == null) {
        _log.fine('recomputeForTrip $tripId: trip not found — skipping');
        return const Ok(0);
      }
      final minLat = tripRow.bboxMinLat;
      final minLon = tripRow.bboxMinLon;
      final maxLat = tripRow.bboxMaxLat;
      final maxLon = tripRow.bboxMaxLon;
      if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
        _log.fine('recomputeForTrip $tripId: no bbox — skipping');
        return const Ok(0);
      }

      // 5-point probe → set of affected region IDs (same as CoverageInvalidator).
      final centreLat = (minLat + maxLat) / 2;
      final centreLon = (minLon + maxLon) / 2;
      final probePoints = [
        [minLat, minLon],
        [minLat, maxLon],
        [maxLat, minLon],
        [maxLat, maxLon],
        [centreLat, centreLon],
      ];
      final affectedIds = <String>{};
      for (final p in probePoints) {
        for (final level in kComputeAdminLevels) {
          final region = await _regionLookup.regionAt(p[0], p[1], level);
          if (region != null) affectedIds.add(region.osmId.toString());
        }
      }
      if (affectedIds.isEmpty) {
        _log.fine('recomputeForTrip $tripId: no regions probed — skipping');
        return const Ok(0);
      }

      // Read ALL intervals (cumulative totals across all trips).
      final allIntervals = await _intervalsDao.getAllIntervals();
      final byWayId = <int, List<Interval>>{};
      for (final row in allIntervals) {
        byWayId
            .putIfAbsent(row.wayId, () => [])
            .add(Interval(row.startMeters, row.endMeters));
      }

      // Fetch ways only in the trip bbox (much cheaper than full union bbox).
      final ways = await _waySource.fetchWaysInBbox(
        minLat: minLat,
        minLon: minLon,
        maxLat: maxLat,
        maxLon: maxLon,
        throwOnError: false,
      );

      // Accumulate totals for affected regions only.
      final total = <String, double>{};
      final driven = <String, double>{};
      var processed = 0;

      for (final way in ways) {
        final c = _centroid(way.geometry);
        if (c == null) continue;
        final wayLen = _polylineLengthMeters(way.geometry);
        final unionLen = byWayId.containsKey(way.wayId)
            ? drivenLengthMeters(byWayId[way.wayId]!)
            : 0.0;

        for (final level in kComputeAdminLevels) {
          final region = await _regionLookup.regionAt(
            c.latitude,
            c.longitude,
            level,
          );
          if (region == null) continue;
          final id = region.osmId.toString();
          if (!affectedIds.contains(id)) continue; // only upsert affected rows
          total[id] = (total[id] ?? 0) + wayLen;
          if (unionLen > 0) driven[id] = (driven[id] ?? 0) + unionLen;
        }

        processed++;
        if (processed % 250 == 0) await Future<void>.delayed(Duration.zero);
      }

      // Upsert only the affected regions — no deleteAll.
      final now = DateTime.now();
      var written = 0;
      for (final id in total.keys) {
        await _cacheDao.upsert(
          regionId: id,
          drivenLengthM: driven[id] ?? 0,
          totalLengthM: total[id]!,
          updatedAt: now,
          realTotalLengthM: _totalsLookup.totalFor(id),
        );
        written++;
      }

      _log.info(
        'recomputeForTrip $tripId: ${ways.length} ways, $written regions upserted',
      );
      return Ok(written);

      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('recomputeForTrip $tripId: unexpected error', e, st);
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
