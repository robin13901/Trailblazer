// Trailblazer Phase 7 (07-03), reworked 2026-07-18 (clipped-geometry),
// reworked 2026-08-15 (durable way-geometry cache, schema v10):
// DrivenWayGeometryResolver — builds the coverage overlay by clipping each
// driven OSM way to its driven union interval(s), deduped per wayId.
//
// v10 change: geometry is now read from the durable `driven_way_geometry`
// table (written once at match time) instead of re-fetched from the volatile
// 50 MB LRU Overpass tile cache. This makes the resolver:
//   * INSTANT: one DB read, no tile access, no network
//   * EVICTION-PROOF: geometry is static OSM data, never evicted
//   * INCREMENTAL: new trips add only new way rows; old rows are reused
//
// The clip itself (clipDrivenWays) is unchanged — same topology-aware
// thorn-drop, connector-close, and stitch rules.

import 'package:auto_explore/core/db/daos/driven_way_geometry_dao.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_codec.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

/// Resolves the app-wide coverage overlay from `driven_way_intervals` +
/// durable `driven_way_geometry` rows, clipping each way to its union
/// interval(s) and deduping per wayId across all trips.
///
/// STATELESS — [resolve] reads fresh from each DAO on every call. Reactive
/// invalidation is handled by the coverage overlay provider.
class DrivenWayGeometryResolver {
  DrivenWayGeometryResolver({
    required DrivenWayIntervalsDao intervalsDao,
    required DrivenWayGeometryDao geometryDao,
  }) : _intervalsDao = intervalsDao,
       _geometryDao = geometryDao;

  final DrivenWayIntervalsDao _intervalsDao;
  final DrivenWayGeometryDao _geometryDao;

  static final _log = Logger('DrivenWayGeometryResolver');

  /// Resolves all driven ways and returns their geometry CLIPPED to the
  /// driven union interval(s), one [CoverageWay] per contiguous driven
  /// sub-segment.
  ///
  /// [unionBounds] is kept as a parameter for API compatibility with the
  /// overlay provider — it is no longer used for tile fetching.
  ///
  /// Never throws — degrades to [CoverageOverlayData.empty] on any error.
  Future<CoverageOverlayData> resolve(LatLngBounds unionBounds) async {
    try {
      // 1. Read all driven intervals (way-centric, across all trips) and
      //    group by wayId, merging overlapping passes into disjoint union
      //    intervals.
      final allIntervals = await _intervalsDao.getAllIntervals();
      if (allIntervals.isEmpty) {
        _log.fine('resolve: no driven intervals — returning empty');
        return CoverageOverlayData.empty;
      }

      final unionByWayId = <int, List<(double, double)>>{};
      {
        final rawByWayId = <int, List<Interval>>{};
        for (final row in allIntervals) {
          rawByWayId
              .putIfAbsent(row.wayId, () => [])
              .add(Interval(row.startMeters, row.endMeters));
        }
        for (final entry in rawByWayId.entries) {
          unionByWayId[entry.key] = [
            for (final iv in unionIntervals(entry.value))
              (iv.startMeters, iv.endMeters),
          ];
        }
      }

      // 2. Read geometry from the durable DB table — no tiles, no network.
      //    Ways not yet in the geometry table (e.g. before the backfill
      //    completes) are simply omitted; they will appear after the backfill
      //    writes their rows and re-triggers the provider.
      final geomRows = await _geometryDao.getAllRows();
      if (geomRows.isEmpty) {
        _log.fine('resolve: geometry table empty — backfill not yet done');
        return CoverageOverlayData.empty;
      }

      final geomByWayId = <int, List<LatLng>>{};
      final nodesByWayId = <int, List<int>>{};
      for (final row in geomRows) {
        final geom = decodeWayGeometry(row.geometryJson);
        if (geom.length < 2) continue;
        geomByWayId[row.wayId] = geom;
        nodesByWayId[row.wayId] = decodeNodeIds(row.nodeIdsJson);
      }

      // 3. Clip on a compute() isolate — same pure function as before.
      final payload = _ClipPayload(
        unionByWayId: unionByWayId,
        geomByWayId: geomByWayId,
        nodesByWayId: nodesByWayId,
      );
      final clipped = await compute(_clipCoverageIsolate, payload);

      _log.info('resolve: ${clipped.length} clipped driven segments');
      return CoverageOverlayData(clipped);
    } on DomainError catch (e, st) {
      _log.warning('resolve: DomainError — degrading to empty', e, st);
      return CoverageOverlayData.empty;
    } on Object catch (e, st) {
      _log.warning(
        'resolve: unexpected error — degrading to empty',
        DomainError.wrap(e, st),
        st,
      );
      return CoverageOverlayData.empty;
    }
  }
}

// ---------------------------------------------------------------------------
// Isolate payload
// ---------------------------------------------------------------------------

class _ClipPayload {
  const _ClipPayload({
    required this.unionByWayId,
    required this.geomByWayId,
    required this.nodesByWayId,
  });

  final Map<int, List<(double, double)>> unionByWayId;
  final Map<int, List<LatLng>> geomByWayId;
  final Map<int, List<int>> nodesByWayId;
}

List<CoverageWay> _clipCoverageIsolate(_ClipPayload p) {
  return clipDrivenWays(
    unionByWayId: p.unionByWayId,
    geomByWayId: p.geomByWayId,
    nodesByWayId: p.nodesByWayId,
  );
}

// ---------------------------------------------------------------------------
// Pure render logic (isolate-safe, unit-testable) — unchanged from v9
// ---------------------------------------------------------------------------

const double kThornFloorMeters = 25;
const double kConnectorFullDrawMeters = 80;
const double kStitchToleranceMeters = 25;

List<CoverageWay> clipDrivenWays({
  required Map<int, List<(double, double)>> unionByWayId,
  required Map<int, List<LatLng>> geomByWayId,
  required Map<int, List<int>> nodesByWayId,
}) {
  final nodeToWays = <int, Set<int>>{};
  geomByWayId.forEach((wid, g) {
    final n = nodesByWayId[wid];
    if (n == null || n.length != g.length || n.isEmpty) return;
    (nodeToWays[n.first] ??= <int>{}).add(wid);
    (nodeToWays[n.last] ??= <int>{}).add(wid);
  });
  bool sharedWithOther(int node, int self) {
    final s = nodeToWays[node];
    return s != null && s.any((w) => w != self);
  }

  final out = <CoverageWay>[];
  for (final entry in unionByWayId.entries) {
    final wayId = entry.key;
    final geom = geomByWayId[wayId];
    if (geom == null) continue;
    final intervals = entry.value;
    if (intervals.isEmpty) continue;

    final nodes = nodesByWayId[wayId];
    final hasNodes =
        nodes != null && nodes.length == geom.length && nodes.isNotEmpty;
    final full = polylineLengthMeters(geom);

    var drivenUnionM = 0.0;
    for (final (s, e) in intervals) {
      drivenUnionM += (e - s).abs();
    }

    final firstShared = hasNodes && sharedWithOther(nodes.first, wayId);
    final lastShared = hasNodes && sharedWithOther(nodes.last, wayId);
    final bridges = firstShared && lastShared;

    if (hasNodes &&
        !bridges &&
        drivenUnionM < kThornFloorMeters &&
        (full <= 0 || drivenUnionM / full < 0.5)) {
      continue;
    }

    if (bridges && full <= kConnectorFullDrawMeters) {
      out.add(
        CoverageWay(
          wayId: wayId,
          geometry: List<LatLng>.of(geom),
          datum: const CoverageDatum(fraction: 1, isFull: true),
        ),
      );
      continue;
    }

    final sorted = [...intervals]
      ..sort((a, b) {
        final la = a.$1 < a.$2 ? a.$1 : a.$2;
        final lb = b.$1 < b.$2 ? b.$1 : b.$2;
        return la.compareTo(lb);
      });
    for (var i = 0; i < sorted.length; i++) {
      var lo = sorted[i].$1 < sorted[i].$2 ? sorted[i].$1 : sorted[i].$2;
      var hi = sorted[i].$1 > sorted[i].$2 ? sorted[i].$1 : sorted[i].$2;
      if (i == 0 && firstShared && lo <= kStitchToleranceMeters) lo = 0;
      if (i == sorted.length - 1 &&
          lastShared &&
          hi >= full - kStitchToleranceMeters) {
        hi = full;
      }
      final seg = reconstructWaySubsegment(
        geom,
        lo,
        hi,
        snapMeters: hasNodes ? 0 : kWaySubsegmentSnapMeters,
      );
      if (seg.length < 2) continue;
      out.add(
        CoverageWay(
          wayId: wayId,
          geometry: seg,
          datum: const CoverageDatum(fraction: 1, isFull: true),
        ),
      );
    }
  }
  return out;
}
