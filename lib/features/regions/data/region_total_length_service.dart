// Trailblazer 2026-07-13 (real per-region total road km):
// RegionTotalLengthService — computes the REAL total road length of an entire
// admin region and caches it once, forever.
//
// The bug this fixes: the old CoverageComputeService only summed the lengths
// of ways near the user's *trips*, so a Bundesland like Bayern showed ~30 km
// total instead of its true tens of thousands of km — making the coverage %
// meaningless. Here we ask Overpass for the true total, road-network-wide.
//
// Why tiled: a single whole-region area query OOMs the public Overpass server
// (validated 2026-07-13 — a Bayern-wide `sum(length())` hit the 2 GB per-query
// ceiling). So we split the region's bbox into cells and sum each cell's
// road length CLIPPED to the region polygon (Overpass `(area:...)` filter),
// then add them up. No geometry is transferred — the server returns one number
// per cell. Cells that still OOM are subdivided and retried.
//
// Runs in the background, once per region; the result is persisted to
// `coverage_cache.real_total_length_m` and never recomputed. Best-effort and
// never throws — a failed region is simply left un-computed (its spinner stays)
// and retried on the next launch.

import 'dart:convert';

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:logging/logging.dart';

/// Overpass area ids are `3600000000 + osmRelationId`.
const int kOverpassAreaIdBase = 3600000000;

/// Target cell size (degrees) for tiling a region's bbox. ~0.1° ≈ 11 km N–S;
/// small enough that a single cell's `sum(length())` stays well under the
/// Overpass per-query memory ceiling for typical road densities.
const double kRegionTileDegrees = 0.1;

/// Hard floor on cell size when subdividing after an OOM remark — below this
/// we give up on the cell rather than recurse forever.
const double kMinRegionTileDegrees = 0.0125;

/// How many region cells to fetch concurrently. Kept small (matches the
/// way-tile fetch concurrency) to stay gentle on the shared public Overpass
/// endpoint while still cutting a ~1600-cell Bundesland pass to a fraction of
/// the fully-sequential wall-clock.
const int kRegionCellConcurrency = 2;

/// Schema version of the persisted progress accumulator blob. Bumped if the
/// cell-key scheme or tiling constant changes so stale blobs are discarded.
const int kRegionProgressBlobVersion = 1;

/// After this many freshly-resolved cells, flush the progress blob to the DB.
/// Bounds the work lost on an app-kill without incurring ~1600 tiny writes.
const int kRegionProgressFlushEvery = 25;

/// Computes and caches the real total road length of admin regions.
class RegionTotalLengthService {
  RegionTotalLengthService({
    required AdminRegionLookup regionLookup,
    required OverpassClient overpassClient,
    required CoverageCacheDao cacheDao,
    Logger? logger,
  })  : _regionLookup = regionLookup,
        _overpass = overpassClient,
        _cacheDao = cacheDao,
        _log = logger ?? Logger('RegionTotalLengthService');

  final AdminRegionLookup _regionLookup;
  final OverpassClient _overpass;
  final CoverageCacheDao _cacheDao;
  final Logger _log;

  /// Computes the real total for every region that has driven coverage but no
  /// real total yet, sequentially (to be gentle on the shared Overpass
  /// endpoint). Best-effort: a per-region failure is logged and skipped.
  ///
  /// Returns the number of regions successfully computed.
  Future<int> computeMissingTotals() async {
    // Check for pending work BEFORE loading the admin bundle: on an empty DB
    // (fresh install, or a widget test with an in-memory DB) there is nothing
    // to do, and parsing the ~12 MB admin bundle would be wasted work — and in
    // headless tests would never settle. Only load the bundle when a region
    // actually needs its real total computed.
    final pending = await _cacheDao.getRegionsNeedingRealTotal();
    if (pending.isEmpty) return 0;
    await _regionLookup.ensureLoaded();
    _log.info('computeMissingTotals: ${pending.length} regions pending');
    var done = 0;
    for (final row in pending) {
      final osmId = int.tryParse(row.regionId);
      if (osmId == null) continue;
      final region = _regionLookup.regionByOsmId(osmId);
      if (region == null) continue;
      try {
        final total = await computeForRegion(region, regionId: row.regionId);
        if (total != null) {
          await _cacheDao.writeRealTotalLength(
            regionId: row.regionId,
            realTotalLengthM: total,
            computedAt: DateTime.now(),
          );
          done++;
          _log.info(
            'region ${region.name} (${region.osmId}) real total = '
            '${(total / 1000).toStringAsFixed(1)} km',
          );
        }
      } on Object catch (e, st) {
        _log.warning(
          'computeForRegion failed for ${region.name} — will retry: $e',
          e,
          st,
        );
      }
    }
    _log.info('computeMissingTotals: $done/${pending.length} computed');
    return done;
  }

  /// Computes the real total road length (meters) for a single [region] by
  /// tiling its bbox and summing area-clipped `sum(length())` per cell.
  ///
  /// Resumable + monotonic: per-cell sums are persisted to
  /// `coverage_cache.real_total_progress_json` under [regionId] as they land,
  /// so a run interrupted by an app-kill or a flaky-server failure resumes
  /// where it left off instead of restarting the whole (up to ~1600-cell)
  /// pass. Cells are fetched with bounded concurrency
  /// ([kRegionCellConcurrency]).
  ///
  /// Returns the summed total ONLY when every cell resolved (so the caller can
  /// write the final real total, which clears the accumulator); returns `null`
  /// when any cell is still outstanding — the partial progress is persisted and
  /// the region stays pending for a later resume.
  Future<double?> computeForRegion(
    AdminRegion region, {
    required String regionId,
  }) async {
    final areaId = kOverpassAreaIdBase + region.osmId;
    final cells = _tileBbox(
      region.bboxMinLat,
      region.bboxMinLon,
      region.bboxMaxLat,
      region.bboxMaxLon,
    );

    // Load any prior progress so a resumed run skips already-summed cells.
    final done = await _loadProgress(regionId);
    final missing = [
      for (final c in cells)
        if (!done.containsKey(_cellKey(c))) c,
    ];
    _log.fine(
      'computeForRegion ${region.name}: ${cells.length} cells, '
      '${done.length} already done, ${missing.length} to fetch (area $areaId)',
    );

    if (missing.isEmpty) {
      // Everything was already summed on a prior run.
      return done.values.fold<double>(0, (a, b) => a + b);
    }

    var sinceFlush = 0;
    var anyFailed = false;

    // Bounded-concurrency workers pull from a shared iterator (single isolate,
    // cooperative async — no lock needed around the shared maps).
    final iter = missing.iterator;
    Future<void> worker() async {
      while (true) {
        if (!iter.moveNext()) return;
        final cell = iter.current;
        final meters = await _sumCell(areaId, cell);
        if (meters == null) {
          anyFailed = true;
          continue;
        }
        done[_cellKey(cell)] = meters;
        if (++sinceFlush >= kRegionProgressFlushEvery) {
          sinceFlush = 0;
          await _saveProgress(regionId, done);
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < kRegionCellConcurrency.clamp(1, missing.length); i++)
        worker(),
    ]);

    if (anyFailed) {
      // Persist partial progress and leave the region pending to resume later.
      await _saveProgress(regionId, done);
      return null;
    }
    // All cells resolved — return the full sum. The caller writes the real
    // total, which clears the accumulator.
    return done.values.fold<double>(0, (a, b) => a + b);
  }

  /// Loads the persisted per-cell accumulator for [regionId]. Returns an empty
  /// map when no blob exists, or when the blob's version / tiling constant no
  /// longer matches (a schema change invalidates old cell keys).
  Future<Map<String, double>> _loadProgress(String regionId) async {
    final raw = await _cacheDao.readRealTotalProgress(regionId);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      if (decoded['v'] != kRegionProgressBlobVersion) return {};
      if ((decoded['tiles'] as num?)?.toDouble() != kRegionTileDegrees) {
        return {};
      }
      final cells = decoded['cells'];
      if (cells is! Map<String, dynamic>) return {};
      return {
        for (final e in cells.entries)
          if (e.value is num) e.key: (e.value as num).toDouble(),
      };
      // Corrupt blob: start fresh rather than crash the pass.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return {};
    }
  }

  /// Persists the per-cell accumulator for [regionId] with a version + tiling
  /// header so a future constant change can invalidate it on load.
  Future<void> _saveProgress(String regionId, Map<String, double> done) {
    final blob = jsonEncode({
      'v': kRegionProgressBlobVersion,
      'tiles': kRegionTileDegrees,
      'cells': done,
    });
    return _cacheDao.writeRealTotalProgress(
      regionId: regionId,
      progressJson: blob,
    );
  }

  /// Stable per-cell key (4 dp ≈ 11 m — finer than any cell edge) so a resumed
  /// run recognises the same cells for a fixed [kRegionTileDegrees].
  String _cellKey(_Cell c) =>
      '${c.minLat.toStringAsFixed(4)},${c.minLon.toStringAsFixed(4)}';

  /// Sums one cell's road length, subdividing on an OOM remark down to
  /// [kMinRegionTileDegrees]. Returns null when the cell (and its subdivisions)
  /// all failed — for ANY reason (network error, malformed body, unexpected
  /// throwable) — so a single bad cell can never abort the whole region.
  Future<double?> _sumCell(int areaId, _Cell cell) async {
    try {
      return await _overpass.fetchRegionLengthInBbox(
        regionAreaId: areaId,
        minLat: cell.minLat,
        minLon: cell.minLon,
        maxLat: cell.maxLat,
        maxLon: cell.maxLon,
      );
    } on NetworkError catch (e) {
      // Server-side OOM ("out of memory") → subdivide if we still can,
      // otherwise give up on this cell.
      final message = e.toString().toLowerCase();
      final isOom = message.contains('memory') || message.contains('remark');
      final canSplit =
          (cell.maxLat - cell.minLat) > kMinRegionTileDegrees * 2 ||
              (cell.maxLon - cell.minLon) > kMinRegionTileDegrees * 2;
      if (isOom && canSplit) {
        var sub = 0.0;
        var anyOk = false;
        for (final q in cell.quadrants()) {
          final m = await _sumCell(areaId, q);
          if (m != null) {
            sub += m;
            anyOk = true;
          }
        }
        return anyOk ? sub : null;
      }
      return null;
    } on DomainError {
      return null;
    } on Object catch (e, st) {
      // Any other throwable (e.g. a FormatException from a malformed body that
      // slipped the client's classify gate) must NOT bubble up and abandon the
      // whole region — swallow it and treat the cell as failed-for-now.
      _log.warning('region cell sum failed (treated as pending): $e', e, st);
      return null;
    }
  }

  /// Splits a bbox into ~[kRegionTileDegrees] cells.
  List<_Cell> _tileBbox(
    double minLat,
    double minLon,
    double maxLat,
    double maxLon,
  ) {
    final cells = <_Cell>[];
    var lat = minLat;
    while (lat < maxLat) {
      final nextLat = (lat + kRegionTileDegrees).clamp(minLat, maxLat);
      var lon = minLon;
      while (lon < maxLon) {
        final nextLon = (lon + kRegionTileDegrees).clamp(minLon, maxLon);
        cells.add(_Cell(lat, lon, nextLat, nextLon));
        if (nextLon >= maxLon) break;
        lon = nextLon;
      }
      if (nextLat >= maxLat) break;
      lat = nextLat;
    }
    return cells;
  }
}

/// A bbox tile in `(south, west, north, east)` order.
class _Cell {
  const _Cell(this.minLat, this.minLon, this.maxLat, this.maxLon);
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  /// Four equal sub-cells for adaptive subdivision after an OOM.
  List<_Cell> quadrants() {
    final midLat = (minLat + maxLat) / 2;
    final midLon = (minLon + maxLon) / 2;
    return [
      _Cell(minLat, minLon, midLat, midLon),
      _Cell(minLat, midLon, midLat, maxLon),
      _Cell(midLat, minLon, maxLat, midLon),
      _Cell(midLat, midLon, maxLat, maxLon),
    ];
  }
}
