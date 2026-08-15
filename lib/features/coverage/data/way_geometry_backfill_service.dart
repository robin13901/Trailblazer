// Trailblazer 2026-08-15 (durable way-geometry cache, schema v10):
// One-shot startup backfill that populates driven_way_geometry for all
// existing trips that were matched before schema v10.
//
// Flow:
//   1. Find all driven wayIds that have no cached geometry yet.
//   2. Fetch the Overpass tile cache for the union bbox (cacheOnly:false —
//      missing tiles are fetched from the network, tile by tile via the
//      existing Overpass client which handles rate-limiting).
//   3. Parse each tile, extract geometry + nodeIds for the needed ways.
//   4. Persist in batches to driven_way_geometry.
//
// Progress is reported tile-coarse via [onProgress] so the startup banner
// can show a determinate bar.
//
// Never throws — wraps at DomainError boundary and returns Err.

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_geometry_dao.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_codec.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';

/// Reports tile-coarse progress: [done] of [total] tiles scanned.
typedef WayGeometryBackfillProgress = void Function(int done, int total);

/// One-shot startup service that populates [DrivenWayGeometryDao] for all
/// driven ways that were matched before schema v10 introduced the table.
class WayGeometryBackfillService {
  WayGeometryBackfillService({
    required DrivenWayIntervalsDao intervalsDao,
    required DrivenWayGeometryDao geometryDao,
    required WayCandidateSource waySource,
    required TripsDao tripsDao,
    Logger? logger,
  }) : _intervalsDao = intervalsDao,
       _geometryDao = geometryDao,
       _waySource = waySource,
       _tripsDao = tripsDao,
       _log = logger ?? Logger('WayGeometryBackfillService');

  final DrivenWayIntervalsDao _intervalsDao;
  final DrivenWayGeometryDao _geometryDao;
  final WayCandidateSource _waySource;
  final TripsDao _tripsDao;
  final Logger _log;

  /// Run the backfill. Returns the number of new geometry rows written.
  /// [onProgress] is called tile-coarse (done/total tiles).
  Future<Result<int>> run({
    WayGeometryBackfillProgress? onProgress,
  }) async {
    void reportProgress(int done, int total) {
      try {
        onProgress?.call(done, total);
        // A progress-UI hiccup must never abort the backfill.
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        _log.warning('backfill: onProgress threw: $e');
      }
    }

    try {
      // Which wayIds need geometry?
      final allWayIds =
          (await _intervalsDao.getAllIntervals())
              .map((r) => r.wayId)
              .toSet();
      if (allWayIds.isEmpty) {
        reportProgress(1, 1);
        _log.fine('backfill: no intervals — nothing to do');
        return const Ok(0);
      }

      final already = await _geometryDao.getCachedWayIds();
      final needed = allWayIds.difference(already);
      if (needed.isEmpty) {
        reportProgress(1, 1);
        _log.info('backfill: all ${allWayIds.length} ways already cached');
        return const Ok(0);
      }

      _log.info(
        'backfill: ${needed.length} ways need geometry '
        '(${allWayIds.length} total)',
      );

      // Fetch the union bbox tiles (cacheOnly:false — network for misses).
      final bounds = await _tripsDao.watchUnionBbox().first;
      if (bounds == null) {
        reportProgress(1, 1);
        return const Ok(0);
      }

      final rawTiles = await _waySource.fetchRawTilesInBbox(
        minLat: bounds.southwest.latitude,
        minLon: bounds.southwest.longitude,
        maxLat: bounds.northeast.latitude,
        maxLon: bounds.northeast.longitude,
        throwOnError: false,
        onTileProgress: reportProgress,
      );

      if (rawTiles.isEmpty) {
        reportProgress(1, 1);
        _log.warning('backfill: no tiles fetched — will retry next launch');
        return const Ok(0);
      }

      // Parse tiles, keeping only needed wayIds. Process tile-by-tile so
      // memory peak is bounded (each tile's JSON is GC-eligible after parsing).
      const parser = OverpassResponseParser();
      final rows = <DrivenWayGeometryCompanion>[];
      final seen = <int>{};

      for (final t in rawTiles) {
        final rawJson = utf8.decode(gzip.decode(t.payloadGzip));
        for (final w in parser.parseWays(rawJson)) {
          if (!needed.contains(w.wayId)) continue;
          if (!seen.add(w.wayId)) continue;
          rows.add(
            DrivenWayGeometryCompanion.insert(
              wayId: Value(w.wayId),
              geometryJson: encodeWayGeometry(w.geometry),
              nodeIdsJson: Value(encodeNodeIds(w.nodeIds)),
            ),
          );
        }
      }

      if (rows.isNotEmpty) {
        await _geometryDao.upsertBatch(rows);
      }
      reportProgress(rawTiles.length, rawTiles.length);
      _log.info(
        'backfill: ${rows.length}/${needed.length} way geometries written '
        '(${needed.length - rows.length} not found in tiles — '
        'may be deleted OSM ways)',
      );
      return Ok(rows.length);

      // Wraps all throwables for DomainError boundary.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('backfill: unexpected error', e, st);
      return Err(DomainError.wrap(e, st));
    }
  }
}
