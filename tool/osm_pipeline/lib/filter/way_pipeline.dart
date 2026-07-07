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
    // Runs as a single set-difference query: for every way in ways_raw,
    // scan its node_ids BLOB and check each id against nodes_raw. Missing
    // nodes → drop the way. Log per dropped way.
    //
    // O(ways_raw * avg_nodes_per_way) — fine for the tiny fixture. Berlin
    // smoke (04-09) may reveal we need a temporary index; deferred.
    final wayRows = scratch.raw
        .select('SELECT id, node_ids FROM ways_raw;');
    final droppedIds = <int>[];
    final nodeCheck = scratch.raw
        .prepare('SELECT 1 FROM nodes_raw WHERE id = ? LIMIT 1;');
    try {
      for (final row in wayRows) {
        final wayId = row['id'] as int;
        final blob = row['node_ids'] as Uint8List;
        final ids = decodeNodeIds(blob);
        var missing = false;
        for (final nid in ids) {
          if (nodeCheck.select([nid]).isEmpty) {
            missing = true;
            break;
          }
        }
        if (missing) {
          droppedIds.add(wayId);
          scratch.bumpStat('deleted_node_ref');
          logSkip('deleted_node_ref', wayId);
        }
      }
    } finally {
      nodeCheck.dispose();
    }
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
