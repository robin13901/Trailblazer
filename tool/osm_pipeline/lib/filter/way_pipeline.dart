/// Stage B — highway filter + directionality normalization.
///
/// Consumes a PBF via `PbfReader.stream()` (04-02) in TWO passes:
///   * Pass A collects Kfz + Feldweg ways into `ways_raw`, tracking the
///     node ids each retained way references.
///   * Pass B re-streams the PBF and writes only the referenced nodes into
///     `nodes_raw`.
///
/// Rejected ways are logged to `skipped.log` alongside the scratch DB. The
/// pipeline never dies on a malformed or unreferenced way (04-CONTEXT
/// "skip-log-continue error handling").
///
/// Post-pass integrity check: any way that references a node ID absent from
/// `nodes_raw` is dropped and logged as `deleted_node_ref` (04-RESEARCH §12
/// pitfall #4).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/cli/progress_logger.dart';
import 'package:osm_pipeline/filter/directionality.dart';
import 'package:osm_pipeline/filter/feldweg_filter.dart';
import 'package:osm_pipeline/filter/kfz_filter.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:osm_pipeline/pbf/pbf_reader.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:path/path.dart' as p;

/// Summary of a way_pipeline run.
class WayPipelineStats {
  /// Create a stats record.
  const WayPipelineStats({
    required this.kfzWays,
    required this.feldwegWays,
    required this.nodes,
    required this.rejected,
    required this.highwayRoad,
    required this.deletedNodeRefs,
    required this.skippedLog,
  });

  /// Number of Kfz ways written to `ways_raw`.
  final int kfzWays;

  /// Number of Feldweg ways written to `ways_raw`.
  final int feldwegWays;

  /// Number of distinct referenced nodes written to `nodes_raw`.
  final int nodes;

  /// Number of ways rejected (any reason).
  final int rejected;

  /// Number of accepted Kfz ways with `highway=road` (04-RESEARCH §12 #9).
  final int highwayRoad;

  /// Number of ways dropped in the post-pass integrity check.
  final int deletedNodeRefs;

  /// Absolute path to the `skipped.log` file (may be empty).
  final File skippedLog;
}

/// The Stage B pipeline stage.
///
/// [readerFactory] is injectable so tests can swap in a fake stream if
/// needed. Default: a fresh `PbfReader` per pass (each pass streams the PBF
/// from scratch; the reader is stateless per instance).
class WayPipeline {
  /// Create a pipeline stage.
  const WayPipeline({this.readerFactory = _defaultReader});

  /// Factory used to obtain a `PbfReader` for each of the two passes.
  final PbfReader Function() readerFactory;

  static PbfReader _defaultReader() => PbfReader();

  /// Runs both passes over [pbf] and writes results into [scratch].
  Future<WayPipelineStats> run({
    required File pbf,
    required ScratchDb scratch,
  }) async {
    final skippedLogPath = p.join(scratch.directory.path, 'skipped.log');
    final skippedLog = File(skippedLogPath);
    final logSink = skippedLog.openWrite(mode: FileMode.writeOnly);

    void logSkip(String reason, int id) {
      logSink.writeln('$reason\tway/$id');
    }

    var kfzCount = 0;
    var rejectedCount = 0;
    var highwayRoad = 0;

    // --- Pass A: select Kfz + Feldweg ways.
    final passA = ProgressLogger(
      'Stage B pass A (ways)',
      total: 0,
      unit: 'ways',
    );
    final relevantNodeIds = <int>{};
    await for (final e in readerFactory().stream(pbf)) {
      if (e is! OsmWay) continue;
      passA.tick();
      final hw = e.tags['highway'];
      if (hw == null) {
        rejectedCount++;
        logSkip('no_highway_tag', e.id);
        continue;
      }
      if (isKfzWay(e)) {
        final nd = normalizeDirectionality(e);
        final kept = retainKfzTags(e);
        scratch.insertWayKfz(
          id: e.id,
          nodeIds: nd.nodeIds,
          isDirectional: nd.isDirectional,
          onewayTag: e.tags['oneway'],
          highway: kept['highway']!,
          name: kept['name'],
          ref: kept['ref'],
          maxspeed: kept['maxspeed'],
        );
        kfzCount++;
        if (hw == 'road') {
          scratch.bumpStat('highway_road');
          highwayRoad++;
        }
        relevantNodeIds.addAll(nd.nodeIds);
        continue;
      }
      final fTags = feldwegTagsOrNull(e);
      if (fTags != null) {
        scratch.insertWayFeldweg(
          id: e.id,
          nodeIds: e.nodeRefs,
          highway: fTags['highway']!,
          name: fTags['name'],
          surface: fTags['surface'],
          motorVehicle: fTags['motor_vehicle'],
          service: fTags['service'],
        );
        relevantNodeIds.addAll(e.nodeRefs);
        continue;
      }
      // Rejected: reason depends on the failing predicate.
      rejectedCount++;
      final reason = _rejectionReason(hw, e);
      logSkip(reason, e.id);
    }
    scratch.flush();
    passA.finish();

    // --- Pass B: ingest only referenced nodes.
    if (relevantNodeIds.isNotEmpty) {
      final passB = ProgressLogger(
        'Stage B pass B (nodes)',
        total: relevantNodeIds.length,
        unit: 'nodes',
      );
      await for (final e in readerFactory().stream(pbf)) {
        if (e is! OsmNode) continue;
        if (!relevantNodeIds.contains(e.id)) continue;
        scratch.insertNode(id: e.id, lat: e.lat, lng: e.lng);
        passB.tick();
      }
      scratch.flush();
      passB.finish();
    }

    // --- Post-pass integrity check: drop ways whose nodes went missing.
    //
    // Rewritten 2026-07-07 as a Wave-1 corrective patch (see 04-10-1-01
    // SUMMARY §Post-close corrective fix). The prior implementation loaded
    // every row of ways_raw eagerly via db.select() then did per-node SELECT
    // lookups against nodes_raw (O(N ways × M nodes/way) — ~40M prepared-
    // statement calls on the full-Germany extract, silently running for
    // 30-60+ min with no ProgressLogger tick).
    final droppedIds = runWayIntegrityCheck(
      scratch: scratch,
      onDrop: (wayId) => logSkip('deleted_node_ref', wayId),
    );

    // --- highway=road ratio warning per 04-RESEARCH §12 pitfall #9.
    final totalKfz = kfzCount;
    if (totalKfz > 0 && highwayRoad / totalKfz > 0.001) {
      Logger.warn(
        'highway=road count $highwayRoad exceeds 0.1% of $totalKfz Kfz '
        'ways — consider fixing upstream OSM tagging.',
      );
    }

    await logSink.flush();
    await logSink.close();

    // Adjust final counts to reflect post-pass drops.
    final finalKfz = scratch
        .raw
        .select("SELECT COUNT(*) AS n FROM ways_raw WHERE source = 'kfz';")
        .first['n'] as int;
    final finalFeldweg = scratch.raw
        .select("SELECT COUNT(*) AS n FROM ways_raw WHERE source = 'feldweg';")
        .first['n'] as int;
    final finalNodes = scratch.countRows('nodes_raw');

    return WayPipelineStats(
      kfzWays: finalKfz,
      feldwegWays: finalFeldweg,
      nodes: finalNodes,
      rejected: rejectedCount,
      highwayRoad: highwayRoad,
      deletedNodeRefs: droppedIds.length,
      skippedLog: skippedLog,
    );
  }

  String _rejectionReason(String hw, OsmWay w) {
    if (kExplicitFeldwegHighwayValues.contains(hw)) {
      // A candidate Feldweg highway class that failed the sub-tag test.
      switch (hw) {
        case 'path':
          return 'feldweg_missing_motor_vehicle';
        case 'service':
          return 'feldweg_service_not_driveway_or_alley';
      }
    }
    return 'highway_class_not_allowlisted';
  }
}

/// Highway values considered for the Feldweg branch — used to disambiguate
/// rejection reasons in [WayPipeline._rejectionReason].
const Set<String> kExplicitFeldwegHighwayValues = {
  'track',
  'path',
  'service',
};

/// Runs Stage B's post-pass integrity check: for every way in `ways_raw`,
/// confirm every referenced node id exists in `nodes_raw`. Any way with a
/// missing reference is DELETEd, `filter_stats.deleted_node_ref` is
/// incremented once per dropped way, and [onDrop] is invoked (production
/// wires it to the `skipped.log` sink).
///
/// Rewritten 2026-07-07 as a Wave-1 corrective patch (see 04-10-1-01
/// SUMMARY §Post-close corrective fix). The prior implementation loaded
/// every row of ways_raw eagerly via `db.select()` then did per-node
/// point-lookup `SELECT 1 FROM nodes_raw WHERE id=?` calls (O(N ways × M
/// nodes/way) — ~40M prepared-statement calls on the full-Germany extract,
/// silently running for 30-60+ min with no ProgressLogger tick).
///
/// The rewrite:
///   1. Streams `ways_raw` via `selectCursor()` — bounded memory.
///   2. Inserts each `(way_id, node_id)` pair into a TEMP table inside a
///      committed-every-100k-ways transaction.
///   3. Runs a single `LEFT JOIN nodes_raw` to find ways referencing any
///      missing node — replaces N×M point-lookups with one set-based query.
///   4. Ticks a [ProgressLogger] on the streaming pass (`total = COUNT(*)
///      FROM ways_raw`) so long runs emit 5% / 5s progress lines.
///
/// Returns the list of dropped way ids for downstream reporting.
List<int> runWayIntegrityCheck({
  required ScratchDb scratch,
  required void Function(int wayId) onDrop,
}) {
  final integrityTotal = scratch.raw
      .select('SELECT COUNT(*) AS n FROM ways_raw;')
      .first['n'] as int;
  final integrity = ProgressLogger(
    'Stage B integrity',
    total: integrityTotal,
    unit: 'ways',
  );
  final droppedIds = <int>[];

  scratch.raw.execute(
    'CREATE TEMP TABLE way_node_refs '
    '(way_id INTEGER NOT NULL, node_id INTEGER NOT NULL);',
  );
  final wayCursor =
      scratch.raw.prepare('SELECT id, node_ids FROM ways_raw;');
  final insertRef = scratch.raw
      .prepare('INSERT INTO way_node_refs (way_id, node_id) VALUES (?, ?);');
  try {
    scratch.raw.execute('BEGIN;');
    var sinceCommit = 0;
    final cursor = wayCursor.selectCursor();
    while (cursor.moveNext()) {
      final row = cursor.current;
      final wayId = row['id'] as int;
      final blob = row['node_ids'] as Uint8List;
      final ids = decodeNodeIds(blob);
      for (final nid in ids) {
        insertRef.execute([wayId, nid]);
      }
      integrity.tick();
      sinceCommit++;
      // Amortise transaction size — commit every 100k ways so a mid-loop
      // failure doesn't roll back the entire pass.
      if (sinceCommit >= 100000) {
        scratch.raw
          ..execute('COMMIT;')
          ..execute('BEGIN;');
        sinceCommit = 0;
      }
    }
    scratch.raw.execute('COMMIT;');
  } finally {
    insertRef.dispose();
    wayCursor.dispose();
  }
  integrity.finish();

  // Single LEFT JOIN — find ways referencing any node absent from
  // nodes_raw. `DISTINCT` collapses ways with multiple missing refs to
  // one row so the emitted log has one entry per dropped way.
  Logger.info('Stage B integrity: JOIN against nodes_raw…');
  final missing = scratch.raw.select(
    'SELECT DISTINCT wn.way_id AS way_id '
    'FROM way_node_refs wn '
    'LEFT JOIN nodes_raw n ON n.id = wn.node_id '
    'WHERE n.id IS NULL;',
  );
  for (final row in missing) {
    final wayId = row['way_id'] as int;
    droppedIds.add(wayId);
    scratch.bumpStat('deleted_node_ref');
    onDrop(wayId);
  }
  scratch.raw.execute('DROP TABLE way_node_refs;');

  if (droppedIds.isNotEmpty) {
    final del = scratch.raw.prepare('DELETE FROM ways_raw WHERE id = ?;');
    try {
      for (final id in droppedIds) {
        del.execute([id]);
      }
    } finally {
      del.dispose();
    }
  }

  return droppedIds;
}
