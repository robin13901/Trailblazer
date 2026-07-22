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

import 'dart:typed_data';

import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_job.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Runs the heavy coverage attribution and returns `regionId → RegionAccum`.
///
/// Injected into [CoverageComputeService] so production can delegate to the
/// long-lived `CoverageComputeIsolate` (off the UI thread) while tests pass a
/// synchronous closure. Takes the raw gzipped tiles + parallel bboxes + the
/// flattened driven intervals per wayId — exactly the sendable payload of a
/// [CoverageComputeJob].
typedef CoverageAttributionRunner = Future<Map<String, RegionAccum>> Function(
  List<Uint8List> gzippedTiles,
  List<LatLonBbox> tileBboxes,
  Map<int, List<double>> intervalsByWayId,
);

/// Admin levels attributed during the recompute pass.
///
/// Level 2 (country) is intentionally excluded: the DE country row would
/// accumulate every driven meter and its total would be the entire German
/// road network — useful only to say "I've driven 0.001% of Germany", which
/// is not a meaningful Phase-8 display (RESEARCH.md Pitfall 2).
/// Level 9 is INCLUDED — Ortsteil-level granularity is in scope per
/// RESEARCH.md line 263.
///
/// NOTE: the full `recompute()` path now attributes inside the compute isolate
/// (see coverage_attribution.dart's own copy of this list). This copy is still
/// used by the incremental `recomputeForTrip()` region-probe below.
const List<int> kComputeAdminLevels = [4, 6, 8, 9, 10];

/// Yield to the event loop every N ways in the (still main-isolate) incremental
/// `recomputeForTrip()` loop so it never starves the UI thread. The full
/// `recompute()` no longer needs this — it runs entirely off the UI isolate.
const int _kYieldEveryWays = 50;

/// Recomputes `coverage_cache` for all admin regions at levels 4/6/8/9/10.
///
/// The heavy attribution (tile parse + point-in-polygon) runs OFF the UI thread
/// via the injected [CoverageAttributionRunner] (wired to a long-lived
/// `CoverageComputeIsolate` in production). This service stays on the main
/// isolate for all Drift reads/writes so the regions-tab `.watch()` reactivity
/// fires (Drift table-write invalidation is per-connection).
///
/// This class is STATELESS — [recompute] reads fresh from each DAO/source on
/// every call. All writes go through [CoverageCacheDao].
class CoverageComputeService {
  CoverageComputeService({
    required DrivenWayIntervalsDao intervalsDao,
    required WayCandidateSource waySource,
    required AdminRegionLookup regionLookup,
    required CoverageCacheDao cacheDao,
    required TripsDao tripsDao,
    required RegionTotalsLookup totalsLookup,
    required CoverageAttributionRunner compute,
    Future<void> Function()? ensureComputeReady,
    Logger? logger,
  })  : _intervalsDao = intervalsDao,
        _waySource = waySource,
        _regionLookup = regionLookup,
        _cacheDao = cacheDao,
        _tripsDao = tripsDao,
        _totalsLookup = totalsLookup,
        _compute = compute,
        _ensureComputeReady = ensureComputeReady,
        _log = logger ?? Logger('CoverageComputeService');

  final DrivenWayIntervalsDao _intervalsDao;
  final WayCandidateSource _waySource;
  final AdminRegionLookup _regionLookup;
  final CoverageCacheDao _cacheDao;
  final TripsDao _tripsDao;
  final RegionTotalsLookup _totalsLookup;

  /// Off-isolate attribution runner (production: the compute isolate's
  /// `computeAttribution`; tests: a synchronous closure).
  final CoverageAttributionRunner _compute;

  /// Optional warm-up hook awaited before the first [recompute] job (production:
  /// `CoverageComputeIsolate.start`, which is idempotent + single-flight). Null
  /// in tests that inject a synchronous [_compute].
  final Future<void> Function()? _ensureComputeReady;

  final Logger _log;

  /// Recompute and upsert coverage statistics for every admin region that
  /// has any matched/confirmed Kfz ways. Returns the number of rows written.
  ///
  /// The heavy attribution runs OFF the UI thread via [_compute]; this method
  /// only does the (cheap) Drift reads/writes on the main isolate so the
  /// regions-tab `.watch()` reactivity fires.
  ///
  /// Error posture: never throws. Non-DomainError exceptions are wrapped via
  /// [DomainError.wrap] and returned as [Err].
  Future<Result<int>> recompute() async {
    try {
      // Warm up the compute backend (idempotent; production: isolate.start()).
      await _ensureComputeReady?.call();

      // One-shot union bbox — null means no trips → empty cache is the correct
      // state (no trips driven = no coverage to display).
      final bounds = await _tripsDao.watchUnionBbox().first;
      if (bounds == null) {
        await _cacheDao.deleteAll();
        _log.fine('recompute: no union bbox (no trips) — cleared cache');
        return const Ok(0);
      }

      // Read all intervals, group by wayId, and FLATTEN to sendable doubles
      // ([s0,e0,s1,e1,…]) for the compute payload.
      final allIntervals = await _intervalsDao.getAllIntervals();
      final intervalsByWayId = <int, List<double>>{};
      for (final row in allIntervals) {
        intervalsByWayId
            .putIfAbsent(row.wayId, () => <double>[])
            .addAll([row.startMeters, row.endMeters]);
      }

      // RAW cached tiles for the union bbox — NOT parsed here. cacheOnly:true →
      // this is a DISPLAY recompute over geometry the matcher already fetched;
      // it must NEVER fire network fetches for off-corridor tiles in the (wide)
      // union bbox (2026-07-21 hang fix). The gunzip + parse + point-in-polygon
      // all happen inside the compute isolate (2026-07-22), so the main thread
      // stays smooth.
      final rawTiles = await _waySource.fetchRawTilesInBbox(
        minLat: bounds.southwest.latitude,
        minLon: bounds.southwest.longitude,
        maxLat: bounds.northeast.latitude,
        maxLon: bounds.northeast.longitude,
        throwOnError: false,
        cacheOnly: true,
      );

      // Heavy attribution off the UI thread.
      final accum = await _compute(
        [for (final t in rawTiles) t.payloadGzip],
        [for (final t in rawTiles) t.bbox],
        intervalsByWayId,
      );

      // Wipe + rebuild coverage_cache in a single transaction so the regions
      // tab's watchAllWithCoverage() stream fires exactly once at commit (and
      // the deleteAll + upserts are atomic). Writes stay on the MAIN Drift
      // connection — Drift table-write invalidation is per-connection.
      final now = DateTime.now();
      await _cacheDao.attachedDatabase.transaction(() async {
        await _cacheDao.deleteAll();
        for (final entry in accum.entries) {
          await _cacheDao.upsert(
            regionId: entry.key,
            drivenLengthM: entry.value.driven,
            totalLengthM: entry.value.total,
            updatedAt: now,
            realTotalLengthM: entry.value.realTotal,
            // extractVersion: null — Phase 10 wires this; null is the default
          );
        }
      });

      _log.info('recompute: ${accum.length} regions written');
      return Ok(accum.length);

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
      // cacheOnly:true for the same reason as recompute() — display pass over
      // already-fetched geometry, never blocks on off-corridor network fetches.
      final ways = await _waySource.fetchWaysInBbox(
        minLat: minLat,
        minLon: minLon,
        maxLat: maxLat,
        maxLon: maxLon,
        throwOnError: false,
        cacheOnly: true,
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
        if (processed % _kYieldEveryWays == 0) {
          await Future<void>.delayed(Duration.zero);
        }
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
