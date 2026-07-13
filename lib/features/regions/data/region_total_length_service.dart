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
        final total = await computeForRegion(region);
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
  /// Returns `null` if every cell failed (total network outage) so the caller
  /// leaves the region un-cached and retries later; returns a number (possibly
  /// 0) when at least some cells resolved.
  Future<double?> computeForRegion(AdminRegion region) async {
    final areaId = kOverpassAreaIdBase + region.osmId;
    final cells = _tileBbox(
      region.bboxMinLat,
      region.bboxMinLon,
      region.bboxMaxLat,
      region.bboxMaxLon,
    );
    _log.fine(
      'computeForRegion ${region.name}: ${cells.length} cells '
      '(area $areaId)',
    );

    var total = 0.0;
    var anyOk = false;
    for (final cell in cells) {
      final cellMeters = await _sumCell(areaId, cell);
      if (cellMeters != null) {
        total += cellMeters;
        anyOk = true;
      }
    }
    return anyOk ? total : null;
  }

  /// Sums one cell's road length, subdividing on an OOM remark down to
  /// [kMinRegionTileDegrees]. Returns null when the cell (and its subdivisions)
  /// all failed with a network error.
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
      // Server-side OOM ("runtime error … out of memory") → subdivide if we
      // still can, otherwise give up on this cell.
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
