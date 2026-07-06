/// Final osm.sqlite writer — Stage E of the pipeline.
///
/// Reads the scratch tables (04-03 ways_raw + nodes_raw, 04-04
/// admin_regions_raw, 04-05 way_admin_raw) and produces the on-disk
/// `osm.sqlite` per `osm_sqlite_schema.dart`. Ways are materialized with
/// inline LineString-WKB geometry so the Phase 5 matcher can read
/// candidate ways with a single indexed lookup — no N+1 across a nodes
/// table.
///
/// Denormalization strategy: L2..L8 wholly-contained ways roll up into
/// `admin_region_id_l{level}` columns; cross-border ways stay as rows in
/// `way_admin`. L9/L10 are dropped from denormalization per the
/// 04-05 Berlin measurement recommendation (see
/// `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md`).
///
/// The measurement gate:
///   * The measurement file MUST exist and MUST NOT contain "not empirically
///     verified", OR the caller must set `allowUnverifiedMeasurement=true`.
///     This is the hard gate declared in 04-06-PLAN.md Task 1.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:osm_pipeline/output/osm_sqlite_schema.dart';
import 'package:osm_pipeline/output/rtree_builder.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// Result of a single [OsmSqliteWriter.write] invocation.
class OsmSqliteWriteResult {
  /// Create a result record.
  const OsmSqliteWriteResult({
    required this.waysWritten,
    required this.adminRegionsWritten,
    required this.wayAdminRowsWritten,
    required this.rtreeRowsWritten,
    required this.granularity,
    required this.outputBytes,
  });

  /// Number of rows inserted into `ways`.
  final int waysWritten;

  /// Number of rows inserted into `admin_regions`.
  final int adminRegionsWritten;

  /// Number of rows inserted into `way_admin` (post-denormalization
  /// roll-up — only cross-border rows survive).
  final int wayAdminRowsWritten;

  /// Number of rows inserted into `ways_rtree`.
  final int rtreeRowsWritten;

  /// Chosen R-Tree granularity (see [RtreeGranularity]).
  final RtreeGranularity granularity;

  /// Final on-disk byte size of the output file (after close + WAL
  /// checkpoint).
  final int outputBytes;
}

/// Copies scratch tables into a fresh osm.sqlite artifact.
class OsmSqliteWriter {
  /// Path (relative to repo) of the Berlin measurement artifact that the
  /// preflight gate checks.
  static const String kDefaultMeasurementPath =
      '.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md';

  /// Sentinel phrase the preflight gate looks for in the measurement file
  /// to detect an un-run / stub measurement.
  static const String kStubSentinel = 'not empirically verified';

  /// Preflight-gate check.
  ///
  /// Throws [PipelineIoError] if the measurement file is absent, and
  /// [PipelineArgsError] if the file contains the [kStubSentinel] and
  /// [allowUnverifiedMeasurement] is false.
  static void preflight({
    required File measurementFile,
    required bool allowUnverifiedMeasurement,
  }) {
    if (!measurementFile.existsSync()) {
      throw PipelineIoError(
        '04-06 blocked: ${measurementFile.path} missing. '
        'Run tool/osm_pipeline/bin/measure_berlin_row_count.dart with a '
        'real Berlin PBF first (see 04-05 Task 3).',
      );
    }
    final txt = measurementFile.readAsStringSync();
    if (txt.contains(kStubSentinel) && !allowUnverifiedMeasurement) {
      throw const PipelineArgsError(
        '04-06 blocked: measurement is a stub, not empirically verified. '
        'Rerun 04-05 Task 3 with a real Berlin PBF, OR pass '
        '--allow-unverified-measurement to explicitly override (records '
        'the risk in the SUMMARY).',
      );
    }
  }

  /// Performs the copy-and-rollup. Returns a summary of what was written.
  ///
  /// [scratch] must contain (populated by 04-03/04/05):
  ///   * `ways_raw` (Kfz + Feldweg rows with node_ids BLOB)
  ///   * `nodes_raw` (lat/lng per referenced node)
  ///   * `admin_regions_raw` (WKB + bbox per region)
  ///   * `way_admin_raw` (per-segment cross-border join rows)
  ///
  /// [outFile] is truncated if it exists.
  ///
  /// [granularity] selects per-segment (default) or per-way R-Tree rows.
  static OsmSqliteWriteResult write({
    required ScratchDb scratch,
    required File outFile,
    RtreeGranularity granularity = RtreeGranularity.perSegment,
  }) {
    if (outFile.existsSync()) {
      outFile.deleteSync();
    }
    // Make sure the parent directory exists.
    outFile.parent.createSync(recursive: true);

    final db = sqlite3.open(outFile.path);
    try {
      for (final pragma in kOsmSqlitePragmas) {
        db.execute(pragma);
      }
      for (final ddl in kOsmSqliteDdl) {
        db.execute(ddl);
      }

      // ---- 1. admin_regions bulk copy + rtree seed. ----
      final adminWritten = _copyAdminRegions(scratch.raw, db);

      // ---- 2. ways: resolve nodes → WKB, roll up denormalized columns. ----
      final rtreeBuilder = RtreeBuilder(db, granularity);
      final _WayCopyStats ways;
      try {
        ways = _copyWays(scratch, db, rtreeBuilder);
      } finally {
        rtreeBuilder.dispose();
      }

      // ---- 3. way_admin: only the rows NOT rolled up to denormalized
      //         columns survive. Rolled-up rows are DELETEd from _raw.
      final surviving = _copyWayAdmin(scratch.raw, db);

      // Force a WAL checkpoint so the on-disk size is accurate before we
      // sample it. Without this, most of the payload can still be in the
      // -wal sidecar file.
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');

      final finalBytes = outFile.lengthSync();
      Logger.info(
        'osm.sqlite written: ${ways.waysWritten} ways, '
        '$adminWritten admin regions, $surviving way_admin rows, '
        '${ways.rtreeRowsWritten} rtree rows '
        '(granularity: ${granularity.name}), '
        '$finalBytes bytes.',
      );
      return OsmSqliteWriteResult(
        waysWritten: ways.waysWritten,
        adminRegionsWritten: adminWritten,
        wayAdminRowsWritten: surviving,
        rtreeRowsWritten: ways.rtreeRowsWritten,
        granularity: granularity,
        outputBytes: finalBytes,
      );
    } finally {
      db.dispose();
    }
  }

  static int _copyAdminRegions(Database scratch, Database out) {
    final rows = scratch.select('''
SELECT region_id, osm_relation_id, admin_level, name, geometry_wkb,
       bbox_minlat, bbox_maxlat, bbox_minlng, bbox_maxlng
FROM admin_regions_raw;
''');
    if (rows.isEmpty) return 0;

    final insertRegion = out.prepare('''
INSERT INTO admin_regions
  (region_id, osm_relation_id, admin_level, name, geometry_wkb,
   bbox_minlat, bbox_maxlat, bbox_minlng, bbox_maxlng)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
''');
    final insertRtree = out.prepare('''
INSERT INTO admin_regions_rtree (id, min_lat, max_lat, min_lng, max_lng)
VALUES (?, ?, ?, ?, ?);
''');
    out.execute('BEGIN;');
    var written = 0;
    try {
      for (final row in rows) {
        final regionId = row['region_id'] as int;
        insertRegion.execute([
          regionId,
          row['osm_relation_id'],
          row['admin_level'],
          row['name'],
          row['geometry_wkb'],
          row['bbox_minlat'],
          row['bbox_maxlat'],
          row['bbox_minlng'],
          row['bbox_maxlng'],
        ]);
        insertRtree.execute([
          regionId,
          row['bbox_minlat'],
          row['bbox_maxlat'],
          row['bbox_minlng'],
          row['bbox_maxlng'],
        ]);
        written++;
      }
      out.execute('COMMIT;');
    } catch (e) {
      out.execute('ROLLBACK;');
      rethrow;
    } finally {
      insertRegion.dispose();
      insertRtree.dispose();
    }
    return written;
  }

  static _WayCopyStats _copyWays(
    ScratchDb scratch,
    Database out,
    RtreeBuilder rtree,
  ) {
    final scratchDb = scratch.raw;
    final wayRows = scratchDb.select('''
SELECT id, source, is_counting, is_directional, oneway_tag, highway,
       name, ref, maxspeed, surface, node_ids
FROM ways_raw;
''');
    if (wayRows.isEmpty) {
      return const _WayCopyStats(waysWritten: 0, rtreeRowsWritten: 0);
    }

    final nodeSelect = scratchDb.prepare(
      'SELECT lat, lng FROM nodes_raw WHERE id = ?;',
    );

    final insertWay = out.prepare('''
INSERT INTO ways
  (way_id, source, is_counting, is_directional, oneway_tag, highway,
   name, ref, maxspeed, surface, length_m, geometry_wkb,
   admin_region_id_l2, admin_region_id_l4, admin_region_id_l6,
   admin_region_id_l8)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
''');

    // Read all way_admin_raw rows into an in-memory grouped map so we can
    // decide roll-up per (way_id, level) in O(1) without an N x M query.
    final rollUpTargets = <int, List<int>>{}; // way_id → levels rolled up
    final adminByWay = _loadAdminByWay(scratchDb);

    var waysWritten = 0;
    var rtreeRowsWritten = 0;

    out.execute('BEGIN;');
    try {
      for (final row in wayRows) {
        final wayId = row['id'] as int;
        final blob = row['node_ids'] as Uint8List;
        final nodeIds = decodeNodeIds(blob);

        // Resolve lat/lng for each node id. Missing nodes are impossible
        // after 04-03's integrity check but we defend anyway.
        final points = <Vec2>[];
        for (final nid in nodeIds) {
          final rs = nodeSelect.select([nid]);
          if (rs.isEmpty) continue;
          points.add(
            Vec2(rs.first['lng'] as double, rs.first['lat'] as double),
          );
        }
        if (points.length < 2) {
          continue; // degenerate — skip silently.
        }

        // Denormalization roll-up: for each L2..L8, if the way has exactly
        // one join row for that level with fraction covering [0,1], we roll
        // it up into the admin_region_id_l{level} column and remember to
        // strip it from way_admin_raw.
        final levelHits = adminByWay[wayId] ?? const <int, List<_JoinRow>>{};
        int? l2;
        int? l4;
        int? l6;
        int? l8;
        final rolledLevels = <int>[];
        for (final level in kDenormAdminLevels) {
          final hits = levelHits[level];
          if (hits == null || hits.length != 1) continue;
          final only = hits.first;
          if (only.fractionStart <= 1e-9 && only.fractionEnd >= 1.0 - 1e-9) {
            switch (level) {
              case 2:
                l2 = only.regionId;
              case 4:
                l4 = only.regionId;
              case 6:
                l6 = only.regionId;
              case 8:
                l8 = only.regionId;
              default:
                break;
            }
            rolledLevels.add(level);
          }
        }
        if (rolledLevels.isNotEmpty) {
          rollUpTargets[wayId] = rolledLevels;
        }

        final wkb = _encodeLineStringWkb(points);
        final length = _haversineLength(points);

        insertWay.execute([
          wayId,
          row['source'],
          row['is_counting'],
          row['is_directional'],
          row['oneway_tag'],
          row['highway'],
          row['name'],
          row['ref'],
          row['maxspeed'],
          row['surface'],
          length,
          wkb,
          l2,
          l4,
          l6,
          l8,
        ]);
        waysWritten++;

        rtreeRowsWritten += rtree.buildForWay(wayId, points);
      }
      out.execute('COMMIT;');
    } catch (e) {
      out.execute('ROLLBACK;');
      rethrow;
    } finally {
      insertWay.dispose();
      nodeSelect.dispose();
    }

    // Strip rolled-up rows from scratch's way_admin_raw so the way_admin
    // final table only receives cross-border rows in the next stage.
    if (rollUpTargets.isNotEmpty) {
      final del = scratchDb.prepare(
        'DELETE FROM way_admin_raw WHERE way_id = ? AND admin_level = ?;',
      );
      scratchDb.execute('BEGIN;');
      try {
        for (final entry in rollUpTargets.entries) {
          for (final lvl in entry.value) {
            del.execute([entry.key, lvl]);
          }
        }
        scratchDb.execute('COMMIT;');
      } catch (e) {
        scratchDb.execute('ROLLBACK;');
        rethrow;
      } finally {
        del.dispose();
      }
    }

    return _WayCopyStats(
      waysWritten: waysWritten,
      rtreeRowsWritten: rtreeRowsWritten,
    );
  }

  static Map<int, Map<int, List<_JoinRow>>> _loadAdminByWay(Database scratch) {
    final rows = scratch.select('''
SELECT way_id, region_id, admin_level, fraction_start, fraction_end
FROM way_admin_raw;
''');
    final out = <int, Map<int, List<_JoinRow>>>{};
    for (final r in rows) {
      final wayId = r['way_id'] as int;
      final lvl = r['admin_level'] as int;
      final map = out.putIfAbsent(wayId, () => <int, List<_JoinRow>>{});
      map.putIfAbsent(lvl, () => <_JoinRow>[]).add(
            _JoinRow(
              regionId: r['region_id'] as int,
              fractionStart: r['fraction_start'] as double,
              fractionEnd: r['fraction_end'] as double,
            ),
          );
    }
    return out;
  }

  static int _copyWayAdmin(Database scratch, Database out) {
    final rows = scratch.select('''
SELECT way_id, region_id, admin_level, fraction_start, fraction_end
FROM way_admin_raw;
''');
    if (rows.isEmpty) return 0;

    final insert = out.prepare('''
INSERT INTO way_admin
  (way_id, region_id, admin_level, fraction_start, fraction_end)
VALUES (?, ?, ?, ?, ?);
''');
    var written = 0;
    out.execute('BEGIN;');
    try {
      for (final r in rows) {
        insert.execute([
          r['way_id'],
          r['region_id'],
          r['admin_level'],
          r['fraction_start'],
          r['fraction_end'],
        ]);
        written++;
      }
      out.execute('COMMIT;');
    } catch (e) {
      out.execute('ROLLBACK;');
      rethrow;
    } finally {
      insert.dispose();
    }
    return written;
  }
}

class _WayCopyStats {
  const _WayCopyStats({
    required this.waysWritten,
    required this.rtreeRowsWritten,
  });
  final int waysWritten;
  final int rtreeRowsWritten;
}

class _JoinRow {
  const _JoinRow({
    required this.regionId,
    required this.fractionStart,
    required this.fractionEnd,
  });
  final int regionId;
  final double fractionStart;
  final double fractionEnd;
}

/// Encodes [points] as OGC WKB LineString (little-endian, type=2).
///
/// Layout:
///   byte 1     : byte order = 1 (little-endian)
///   uint32 2   : type = LineString
///   uint32 N   : point count
///   for each point:
///     float64 lng
///     float64 lat
Uint8List _encodeLineStringWkb(List<Vec2> points) {
  final byteCount = 1 + 4 + 4 + points.length * 16;
  final buf = ByteData(byteCount);
  var offset = 0;
  buf.setUint8(offset, 1);
  offset += 1;
  buf.setUint32(offset, 2, Endian.little); // LineString
  offset += 4;
  buf.setUint32(offset, points.length, Endian.little);
  offset += 4;
  for (final p in points) {
    buf.setFloat64(offset, p.lng, Endian.little);
    offset += 8;
    buf.setFloat64(offset, p.lat, Endian.little);
    offset += 8;
  }
  return buf.buffer.asUint8List();
}

/// Sum of segment haversine distances along [points], in metres.
double _haversineLength(List<Vec2> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += haversineMeters(points[i - 1], points[i]);
  }
  return total;
}

/// Decode an OGC WKB LineString blob to a list of [Vec2].
///
/// Inverse of the private encoder in this file — exposed for tests that
/// want to round-trip through [OsmSqliteWriter.write] without duplicating
/// byte-level parsing.
List<Vec2> decodeLineStringWkb(Uint8List blob) {
  final buf = ByteData.sublistView(blob);
  var offset = 0;
  final order = buf.getUint8(offset);
  offset += 1;
  final endian = order == 1 ? Endian.little : Endian.big;
  final type = buf.getUint32(offset, endian);
  offset += 4;
  if (type != 2) {
    throw ArgumentError('Not a LineString WKB (type=$type)');
  }
  final count = buf.getUint32(offset, endian);
  offset += 4;
  final out = <Vec2>[];
  for (var i = 0; i < count; i++) {
    final lng = buf.getFloat64(offset, endian);
    offset += 8;
    final lat = buf.getFloat64(offset, endian);
    offset += 8;
    out.add(Vec2(lng, lat));
  }
  return out;
}
