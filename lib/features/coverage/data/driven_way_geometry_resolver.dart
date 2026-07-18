// Trailblazer Phase 7 (07-03), reworked 2026-07-18 (clipped-geometry rework):
// DrivenWayGeometryResolver — builds the app-wide coverage overlay by rendering
// each driven OSM way CLIPPED to the sub-interval(s) actually driven, deduped
// per wayId across ALL trips.
//
// This replaces two earlier approaches:
//   * The original whole-way render (drew a way's ENTIRE geometry the moment it
//     counted as "driven") — caused junction under-draw gaps AND exit-triangle
//     over-draw, patched with a fragile topology heuristic.
//   * The per-trip snapped-GPS-chord line (coverage_path_json) — drew straight
//     chords between snapped fixes (triangles/fans/zigzags at junctions) and one
//     polyline PER TRIP (N drives of a road = N overlapping lines).
//
// The clipped model fixes all of that: the drawn line IS the road's true OSM
// shape (no chord artifacts), clipped to `[start..end]` driven metres (no
// over-draw), unioned per wayId across every trip (drawn ONCE — natural dedup).
//
// Memory (06-05 / trips-tab-oom lesson): the parse + clip runs on a compute()
// isolate over the RAW cached tiles, filtered to just the driven wayId set —
// never the full-bbox way-set on the UI isolate.

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

/// Resolves the app-wide coverage overlay from `driven_way_intervals` + cached
/// OSM way geometry, rendering each way clipped to its driven union interval(s)
/// and deduped per wayId across all trips.
///
/// STATELESS — `resolve` reads fresh on every call. Reactive invalidation is
/// handled by the coverage overlay provider, which re-calls resolve() whenever
/// the Drift `watchUnionBbox()` stream emits (fires on interval writes).
class DrivenWayGeometryResolver {
  DrivenWayGeometryResolver({
    required DrivenWayIntervalsDao intervalsDao,
    required WayCandidateSource waySource,
  })  : _intervalsDao = intervalsDao,
        _waySource = waySource;

  final DrivenWayIntervalsDao _intervalsDao;
  final WayCandidateSource _waySource;

  static final _log = Logger('DrivenWayGeometryResolver');

  /// Resolves all driven ways within [unionBounds] and returns their geometry
  /// CLIPPED to the driven union interval(s), one [CoverageWay] per contiguous
  /// driven sub-segment.
  ///
  /// Never throws — degrades to [CoverageOverlayData.empty] on any error.
  Future<CoverageOverlayData> resolve(LatLngBounds unionBounds) async {
    try {
      // 1. Read all driven intervals (way-centric, across all trips) and group
      //    by wayId, merging overlapping passes into disjoint union intervals.
      //    Unioning across ALL trips is what dedupes a road driven N times into
      //    one drawn line.
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

      // 2. Fetch RAW gzipped tiles for the union bbox (no parse on this
      //    isolate). throwOnError:false → offline gap yields cached tiles.
      final rawTiles = await _waySource.fetchRawTilesInBbox(
        minLat: unionBounds.southwest.latitude,
        minLon: unionBounds.southwest.longitude,
        maxLat: unionBounds.northeast.latitude,
        maxLon: unionBounds.northeast.longitude,
        throwOnError: false,
      );
      if (rawTiles.isEmpty) {
        _log.fine('resolve: no cached tiles for bbox — returning empty');
        return CoverageOverlayData.empty;
      }

      // 3. Parse + filter-to-driven-set + clip on a compute() isolate. Peak
      //    memory is bounded to the driven wayId set, never the full bbox.
      final payload = _ClipPayload(
        gzippedTiles: [for (final t in rawTiles) t.payloadGzip],
        unionByWayId: unionByWayId,
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

/// Serializable argument bundle for [_clipCoverageIsolate].
class _ClipPayload {
  const _ClipPayload({
    required this.gzippedTiles,
    required this.unionByWayId,
  });

  /// Raw `gzip(utf8(overpassJson))` tile payloads (cross the isolate untouched).
  final List<List<int>> gzippedTiles;

  /// wayId → its disjoint driven union intervals as `(startMeters, endMeters)`.
  final Map<int, List<(double, double)>> unionByWayId;
}

/// Runs on a compute() isolate: gunzip + parse the tiles, keep ONLY the driven
/// wayIds, and clip each way's geometry to its union interval(s). Returns one
/// [CoverageWay] per contiguous driven sub-segment (solid — every drawn metre
/// was driven, so `isFull:true` / `fraction:1`).
List<CoverageWay> _clipCoverageIsolate(_ClipPayload p) {
  final wanted = p.unionByWayId.keys.toSet();

  // Parse tiles, keeping only geometry for driven ways (dedupe across tiles).
  final geomByWayId = <int, List<LatLng>>{};
  final seen = <int>{};
  const parser = OverpassResponseParser();
  for (final gz in p.gzippedTiles) {
    final rawJson = utf8.decode(gzip.decode(gz));
    for (final w in parser.parseWays(rawJson)) {
      if (!wanted.contains(w.wayId)) continue;
      if (!seen.add(w.wayId)) continue;
      geomByWayId[w.wayId] = w.geometry;
    }
  }

  final out = <CoverageWay>[];
  for (final entry in p.unionByWayId.entries) {
    final geom = geomByWayId[entry.key];
    if (geom == null) continue; // geometry not cached (offline gap) — skip
    for (final (start, end) in entry.value) {
      final seg = reconstructWaySubsegment(
        geom,
        start,
        end,
        snapMeters: kWaySubsegmentSnapMeters,
      );
      if (seg.length < 2) continue; // degenerate / empty overlap
      out.add(
        CoverageWay(
          wayId: entry.key,
          geometry: seg,
          datum: const CoverageDatum(fraction: 1, isFull: true),
        ),
      );
    }
  }
  return out;
}
