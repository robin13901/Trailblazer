// Trailblazer coverage recompute service.
//
// Phase 8 (Plan 08-02): FIRST production writer of the `coverage_cache` table.
// Phase 10 (Plan 10-04/10-05): bundled real totals + auto seam.
//
// 2026-07-25 DURABLE CLIP-PER-REGION REWORK (#7):
//   The old recompute() re-attributed EVERY driven way on every trip by
//   re-parsing cached Overpass tiles + a centroid point-in-polygon, assigning
//   each whole way to ONE region per level, and depending on the volatile
//   Overpass tile cache (LRU eviction silently dropped ways → coverage
//   regressed) and growing with all-trips-ever.
//
//   recompute() is now TWO STAGES:
//   * STAGE 1 (attribution, once per NEW wayId, OFF the UI isolate): clip each
//     driven way's polyline against the admin polygons and persist the durable
//     per-(way, region, meter-range) rows in `way_region_attribution`. Only
//     ways not already attributed are clipped (a way's geometry never moves).
//   * STAGE 2 (aggregation, every trip, on the MAIN isolate): pure DB read/sum
//     — for each attribution row, driven += overlap(driven-union, range) and
//     total += range length; then deleteAll + upsert coverage_cache. This no
//     longer touches the Overpass tile cache → EVICTION-PROOF, and always sums
//     ALL driven ways → MONOTONIC. realTotal still comes from
//     RegionTotalsLookup.
//
// Never throws — wraps at DomainError boundary and returns Err.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/db/daos/way_region_attribution_dao.dart';
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
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Runs the heavy STAGE-1 clip and returns the durable attribution rows for the
/// NEW ways (those NOT in [alreadyAttributedWayIds]).
///
/// Injected into [CoverageComputeService] so production can delegate to the
/// long-lived `CoverageComputeIsolate` (off the UI thread) while tests pass a
/// synchronous closure. Takes the raw gzipped tiles + parallel bboxes + the set
/// of wayIds already attributed — exactly the sendable payload of a
/// [CoverageComputeJob].
typedef CoverageAttributionRunner
    = Future<List<WayRegionAttributionRow>> Function(
  List<Uint8List> gzippedTiles,
  List<LatLonBbox> tileBboxes,
  Set<int> alreadyAttributedWayIds,
);

/// Admin levels attributed during the recompute pass.
///
/// Level 2 (country) is intentionally excluded (RESEARCH.md Pitfall 2). Level 9
/// is INCLUDED (Ortsteil granularity). NOTE: the STAGE-1 clip attributes inside
/// the compute isolate (see coverage_attribution.dart's own copy of this list).
/// This copy is still used by the incremental `recomputeForTrip()` probe below.
const List<int> kComputeAdminLevels = [4, 6, 8, 9, 10];

/// Yield to the event loop every N ways in the (still main-isolate) incremental
/// `recomputeForTrip()` loop so it never starves the UI thread.
const int _kYieldEveryWays = 50;

/// STAGE-1 tile-chunk size for progress reporting. The clip is dispatched to the
/// compute isolate in chunks of this many tiles so the recompute can report a
/// determinate `done/total` fraction between chunks (per-way progress cannot
/// cross the isolate boundary cheaply, so progress is TILE-COARSE — see
/// `recompute`'s onProgress docstring). Large enough that the per-chunk isolate
/// round-trip overhead stays negligible against the clip cost.
const int _kProgressTilesPerChunk = 8;

/// Progress callback for [CoverageComputeService.recompute]: reports the
/// STAGE-1 clip advancing as `done` of `total` (tile-coarse — see the method
/// docstring). Invoked at least once with `done == total` on completion so the
/// UI can show 100%. Never throws to the callee.
typedef CoverageRecomputeProgress = void Function(int done, int total);


/// Recomputes `coverage_cache` for all admin regions at levels 4/6/8/9/10 via
/// the durable clip-per-region model.
///
/// STAGE 1 (attribution) runs OFF the UI thread via the injected
/// [CoverageAttributionRunner]; STAGE 2 (aggregation) + all Drift reads/writes
/// stay on the main isolate so the regions-tab `.watch()` reactivity fires
/// (Drift table-write invalidation is per-connection).
///
/// This class is STATELESS — [recompute] reads fresh from each DAO/source on
/// every call. All writes go through [CoverageCacheDao] and
/// [WayRegionAttributionDao].
class CoverageComputeService {
  CoverageComputeService({
    required DrivenWayIntervalsDao intervalsDao,
    required WayCandidateSource waySource,
    required AdminRegionLookup regionLookup,
    required CoverageCacheDao cacheDao,
    required TripsDao tripsDao,
    required RegionTotalsLookup totalsLookup,
    required CoverageAttributionRunner compute,
    WayRegionAttributionDao? attributionDao,
    Future<void> Function()? ensureComputeReady,
    Logger? logger,
  })  : _intervalsDao = intervalsDao,
        _waySource = waySource,
        _regionLookup = regionLookup,
        _cacheDao = cacheDao,
        _tripsDao = tripsDao,
        _totalsLookup = totalsLookup,
        _compute = compute,
        _attributionDao = attributionDao,
        _ensureComputeReady = ensureComputeReady,
        _log = logger ?? Logger('CoverageComputeService');

  final DrivenWayIntervalsDao _intervalsDao;
  final WayCandidateSource _waySource;
  final AdminRegionLookup _regionLookup;
  final CoverageCacheDao _cacheDao;
  final TripsDao _tripsDao;
  final RegionTotalsLookup _totalsLookup;

  /// Durable per-way → region attribution cache. Optional so the pre-existing
  /// plumbing tests (which override recompute) need not supply it; when null a
  /// dao is derived from the cache DAO's attached database lazily.
  final WayRegionAttributionDao? _attributionDao;

  WayRegionAttributionDao get _attribution =>
      _attributionDao ??
      WayRegionAttributionDao(_cacheDao.attachedDatabase);

  /// Off-isolate STAGE-1 clip runner (production: the compute isolate's
  /// `computeAttribution`; tests: a synchronous closure).
  final CoverageAttributionRunner _compute;

  /// Optional warm-up hook awaited before the first [recompute] job (production:
  /// `CoverageComputeIsolate.start`, which is idempotent + single-flight). Null
  /// in tests that inject a synchronous [_compute].
  final Future<void> Function()? _ensureComputeReady;

  final Logger _log;

  /// Recompute and upsert coverage statistics for every admin region that has
  /// any driven ways. Returns the number of rows written.
  ///
  /// [onProgress] — when supplied, is invoked as STAGE-1 clips the driven ways,
  /// with a rising `done` up to a fixed `total`. Progress is TILE-COARSE: the
  /// clip runs inside the compute isolate and per-way counts cannot cross the
  /// SendPort cheaply, so the raw tiles are dispatched in chunks of
  /// [_kProgressTilesPerChunk] and `done`/`total` count TILES, not ways. A final
  /// `onProgress(total, total)` is always emitted before STAGE 2 so the banner
  /// can render 100%. When there is nothing to clip (no trips, or no uncached
  /// tiles) a single `onProgress(1, 1)` is emitted so the banner is never left
  /// at 0%. Errors thrown by the callback are swallowed — a progress-UI hiccup
  /// must never abort the recompute.
  ///
  /// Error posture: never throws. Non-DomainError exceptions are wrapped via
  /// [DomainError.wrap] and returned as [Err].
  Future<Result<int>> recompute({CoverageRecomputeProgress? onProgress}) async {
    void reportProgress(int done, int total) {
      if (onProgress == null) return;
      try {
        onProgress(done, total);
        // A progress-UI hiccup must never abort the recompute.
        // ignore: avoid_catches_without_on_clauses
      } catch (e, st) {
        _log.warning('recompute: onProgress threw: $e', e, st);
      }
    }

    try {
      // Warm up the compute backend (idempotent; production: isolate.start()).
      await _ensureComputeReady?.call();

      // One-shot union bbox — null means no trips → empty cache is the correct
      // state (no trips driven = no coverage to display).
      final bounds = await _tripsDao.watchUnionBbox().first;
      if (bounds == null) {
        await _cacheDao.deleteAll();
        reportProgress(1, 1);
        _log.fine('recompute: no union bbox (no trips) — cleared cache');
        return const Ok(0);
      }

      // ---------------------------------------------------------------------
      // STAGE 1: ensure durable attribution for any NEW driven ways.
      // ---------------------------------------------------------------------
      // Only the ways not already clipped need geometry + a polygon pass. We
      // fetch RAW cached tiles for the union bbox (cacheOnly:true → never fires
      // network for off-corridor tiles) and let the worker skip the ways it has
      // already attributed. If the tile cache has been evicted for a new way,
      // that way simply isn't attributed this pass — but every PREVIOUSLY
      // attributed way survives (rows are durable), so coverage never regresses.
      final alreadyAttributed = await _attribution.getAttributedWayIds();

      final rawTiles = await _waySource.fetchRawTilesInBbox(
        minLat: bounds.southwest.latitude,
        minLon: bounds.southwest.longitude,
        maxLat: bounds.northeast.latitude,
        maxLon: bounds.northeast.longitude,
        throwOnError: false,
        cacheOnly: true,
      );

      // Clip the new ways off the UI thread, dispatched in TILE CHUNKS so we can
      // report a determinate done/total between chunks (per-way progress can't
      // cross the isolate boundary cheaply — hence tile-coarse). Empty tiles →
      // no new rows (STAGE 2 still runs over whatever is already attributed —
      // eviction-proof) and a single 1/1 so the banner never sits at 0%.
      final totalTiles = rawTiles.length;
      if (totalTiles == 0) {
        reportProgress(1, 1);
      } else {
        final newRows = <WayRegionAttributionRow>[];
        // Ways already attributed by an EARLIER chunk in THIS pass must also be
        // skipped by later chunks (a way can span tile boundaries), so grow the
        // skip set as rows land.
        final skip = <int>{...alreadyAttributed};
        reportProgress(0, totalTiles);
        for (var start = 0; start < totalTiles; start += _kProgressTilesPerChunk) {
          final end = math.min(start + _kProgressTilesPerChunk, totalTiles);
          final chunk = rawTiles.sublist(start, end);
          final chunkRows = await _compute(
            [for (final t in chunk) t.payloadGzip],
            [for (final t in chunk) t.bbox],
            skip,
          );
          for (final r in chunkRows) {
            newRows.add(r);
            skip.add(r.wayId);
          }
          reportProgress(end, totalTiles);
        }

        if (newRows.isNotEmpty) {
          final now = DateTime.now();
          await _attribution.upsertBatch([
            for (final r in newRows)
              WayRegionAttributionCompanion.insert(
                wayId: r.wayId,
                regionId: r.regionId,
                adminLevel: r.adminLevel,
                rangeStartM: r.rangeStartM,
                rangeEndM: r.rangeEndM,
                computedAt: Value(now),
              ),
          ]);
        }
      }

      // ---------------------------------------------------------------------
      // STAGE 2: pure DB aggregation on the MAIN isolate (eviction-proof +
      // monotonic — sums ALL driven ways from durable attribution rows).
      // ---------------------------------------------------------------------
      final accum = await _aggregate();

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

  /// STAGE 2: aggregate durable attribution rows against the driven union
  /// intervals into `regionId → RegionAccum`. Pure DB read + Dart sum.
  Future<Map<String, RegionAccum>> _aggregate() async {
    await _totalsLookup.ensureLoaded();

    // Driven union intervals per wayId (all trips, ever).
    final allIntervals = await _intervalsDao.getAllIntervals();
    final unionByWayId = <int, List<Interval>>{};
    for (final row in allIntervals) {
      unionByWayId
          .putIfAbsent(row.wayId, () => <Interval>[])
          .add(Interval(row.startMeters, row.endMeters));
    }

    // Sum driven + total per region from the durable attribution rows.
    final driven = <String, double>{};
    final total = <String, double>{};
    for (final row in await _attribution.getAllRows()) {
      final id = row.regionId;
      total[id] = (total[id] ?? 0) + (row.rangeEndM - row.rangeStartM);
      final ivs = unionByWayId[row.wayId];
      if (ivs != null) {
        final overlap =
            overlapLengthMeters(ivs, row.rangeStartM, row.rangeEndM);
        if (overlap > 0) driven[id] = (driven[id] ?? 0) + overlap;
      }
    }

    return {
      for (final id in total.keys)
        id: RegionAccum(
          driven: driven[id] ?? 0,
          total: total[id]!,
          realTotal: _totalsLookup.totalFor(id),
        ),
    };
  }

  /// Incremental recompute for a single trip (Phase 10 Decision 6 / OQ1-PERF).
  ///
  /// DEPRECATED / non-auto path (kept for the manual button-triggered flows and
  /// existing tests). Uses the old CENTROID attribution against the trip bbox —
  /// it is NOT monotonic across trips, which is exactly why the auto seam calls
  /// [recompute] instead (see matching_providers.dart). Prefer [recompute].
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
