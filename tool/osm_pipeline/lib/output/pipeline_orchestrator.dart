/// Top-level pipeline orchestrator — wires the four stages the CLI runs
/// end-to-end into a single `runPipeline({...})` entrypoint.
///
/// Stage boundaries (mirrors 04-CONTEXT.md pipeline structure):
///   * Stage B — highway filter + directionality (04-03 WayPipeline).
///   * Stage C — admin extraction (04-04 extractAdminRegions).
///   * Stage D — segmented intersection way_admin join (04-05
///     buildWayAdminJoin).
///   * Stage E — osm.sqlite write + R-Tree + version stamp (this plan).
///   * Stage F — GeoJSONSeq + tippecanoe → germany-base.pmtiles (04-07).
///   * Stage G — pmtiles metadata + style rewrite (04-08).
///
/// F and G land in wave 6 (after this plan); they are logged as stubs here.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:osm_pipeline/admin/admin_pipeline.dart';
import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/filter/way_pipeline.dart';
import 'package:osm_pipeline/intersect/way_admin_join.dart';
import 'package:osm_pipeline/output/osm_sqlite_writer.dart';
import 'package:osm_pipeline/output/rtree_builder.dart';
import 'package:osm_pipeline/output/version_stamp.dart';
import 'package:osm_pipeline/pbf/pbf_reader.dart';
import 'package:osm_pipeline/pmtiles/pmtiles_pipeline.dart';
import 'package:osm_pipeline/schema.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:osm_pipeline/scratch/scratch_db_admin_ext.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Summary emitted at the end of a successful [runPipeline].
class PipelineRunResult {
  /// Create a result record.
  const PipelineRunResult({
    required this.osmSqlitePath,
    required this.osmSqliteBytes,
    required this.wayStats,
    required this.adminSummary,
    required this.joinStats,
    required this.writeResult,
    this.pmtilesResult,
  });

  /// Absolute path to the produced osm.sqlite artifact.
  final String osmSqlitePath;

  /// Final byte size of the artifact.
  final int osmSqliteBytes;

  /// Stage B summary.
  final WayPipelineStats wayStats;

  /// Stage C summary.
  final AdminExtractionSummary adminSummary;

  /// Stage D summary.
  final WayAdminJoinStats joinStats;

  /// Stage E write summary.
  final OsmSqliteWriteResult writeResult;

  /// Stage F (pmtiles) summary. `null` when the pmtiles stage was skipped
  /// (e.g. `runPmtiles=false` in tests where tippecanoe is unavailable).
  final PmtilesStageResult? pmtilesResult;
}

/// Runs the full pipeline against [pbf] and writes artifacts under [outDir].
///
/// [bbox] is stamped into the version metadata as-is (or '*' when null).
///
/// [allowUnverifiedMeasurement] forwards to [OsmSqliteWriter.preflight];
/// leave false unless the caller explicitly wants to bypass the 04-05 gate.
///
/// The default [measurementFile] points at
/// `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md` relative
/// to the current working directory.
///
/// [runPmtiles] toggles Stage F (GeoJSONSeq + tippecanoe → pmtiles). Defaults
/// to `true`. Set to `false` on hosts where tippecanoe is unavailable — the
/// osm.sqlite artifact is still produced.
Future<PipelineRunResult> runPipeline({
  required File pbf,
  required Directory outDir,
  String? bbox,
  bool allowUnverifiedMeasurement = false,
  bool runPmtiles = true,
  File? measurementFile,
  RtreeGranularity? granularityOverride,
  int? workers,
  GitShaResolver gitShaResolver = defaultGitShaResolver,
  DateTime? nowUtc,
}) async {
  outDir.createSync(recursive: true);

  final measurement = measurementFile ??
      File(
        p.join(
          Directory.current.path,
          OsmSqliteWriter.kDefaultMeasurementPath,
        ),
      );
  OsmSqliteWriter.preflight(
    measurementFile: measurement,
    allowUnverifiedMeasurement: allowUnverifiedMeasurement,
  );

  final start = nowUtc ?? DateTime.now().toUtc();
  final scratch = ScratchDb.openTempFile();
  final adminWriter = ScratchDbAdminWriter(scratch);
  try {
    Logger.info('Stage B: highway filter + directionality...');
    final wayStats = await const WayPipeline().run(
      pbf: pbf,
      scratch: scratch,
    );
    Logger.info(
      '  ${wayStats.kfzWays} Kfz, ${wayStats.feldwegWays} Feldweg, '
      '${wayStats.nodes} nodes, ${wayStats.rejected} rejected, '
      '${wayStats.deletedNodeRefs} deleted-node-refs.',
    );

    Logger.info('Stage C: admin extraction...');
    final adminSummary = await extractAdminRegions(
      pbf: pbf,
      writer: adminWriter,
    );
    Logger.info(
      '  ${adminSummary.relationsAccepted}/${adminSummary.relationsSeen} '
      'admin relations accepted; ${adminSummary.regionsWritten} rows '
      '(${adminSummary.dualWrites} dual-writes); '
      '${adminSummary.rejected} rejected.',
    );

    Logger.info('Stage D: segmented-intersection way_admin join...');
    final effectiveWorkers = _resolveWorkers(workers);
    if (effectiveWorkers > 1) {
      Logger.info('Stage D: N=$effectiveWorkers workers');
    }
    final joinStats =
        await buildWayAdminJoin(scratch, workers: effectiveWorkers);
    Logger.info(
      '  ${joinStats.waysProcessed} ways probed, '
      '${joinStats.candidatePairsProbed} candidate pairs, '
      '${joinStats.rowsWritten} way_admin_raw rows.',
    );

    // R-Tree granularity selection order (Plan 04-10-1-03):
    //   1. Explicit CLI override (`--rtree-granularity=...`) wins.
    //   2. Otherwise, if the measurement file exists, ask it.
    //      `loadFromMeasurement` now defaults to perWay and only returns
    //      perSegment when the file explicitly says so.
    //   3. Otherwise, hard-default to perWay.
    final RtreeGranularity granularity;
    if (granularityOverride != null) {
      granularity = granularityOverride;
    } else if (measurement.existsSync()) {
      granularity = await RtreeBuilder.loadFromMeasurement(measurement);
    } else {
      granularity = RtreeGranularity.perWay;
    }
    Logger.info('R-Tree granularity: ${granularity.name}');

    Logger.info('Stage E: write osm.sqlite...');
    final osmSqlite = File(p.join(outDir.path, 'osm.sqlite'));
    final writeResult = OsmSqliteWriter.write(
      scratch: scratch,
      outFile: osmSqlite,
      granularity: granularity,
    );

    // Version stamp: read PBF sha + header, then write metadata.
    final pbfSha = await _sha256OfFile(pbf);
    final headerDate = await _readHeaderDate(pbf);

    final stamp = VersionStamp(
      pbfDate: headerDate ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      pbfSource: VersionStamp.basenameOf(pbf.path),
      pbfSha256: pbfSha,
      bbox: bbox,
      schemaVersion: pipelineSchemaVersion,
      gitSha: gitShaResolver(),
      generatedAt: start,
    );
    final db = sqlite3.open(osmSqlite.path);
    try {
      stamp.writeTo(db);
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } finally {
      db.dispose();
    }

    // Re-measure after version stamp write.
    final finalBytes = osmSqlite.lengthSync();

    // Stage F: GeoJSONSeq + tippecanoe → germany-base.pmtiles.
    PmtilesStageResult? pmtilesResult;
    if (runPmtiles) {
      Logger.info('Stage F: GeoJSONSeq + tippecanoe...');
      pmtilesResult = await runPmtilesStage(
        scratch: scratch,
        pbf: pbf,
        outDir: outDir,
        versionStamp: stamp,
      );
    } else {
      Logger.info('Stage F: GeoJSONSeq + tippecanoe... (skipped)');
    }
    Logger.info('Stage G: pmtiles metadata + style rewrite... (04-08 wired)');
    Logger.info('Done. Artifacts:');
    Logger.info('  ${osmSqlite.path}  ($finalBytes bytes)');
    if (pmtilesResult != null) {
      Logger.info(
        '  ${pmtilesResult.pmtilesFile.path}  '
        '(${pmtilesResult.pmtilesBytes} bytes)',
      );
    }

    return PipelineRunResult(
      osmSqlitePath: osmSqlite.path,
      osmSqliteBytes: finalBytes,
      wayStats: wayStats,
      adminSummary: adminSummary,
      joinStats: joinStats,
      writeResult: writeResult,
      pmtilesResult: pmtilesResult,
    );
  } finally {
    adminWriter.dispose();
    scratch.close(deleteFile: true);
  }
}

// ---------------------------------------------------------------------------
// Local helpers.
// ---------------------------------------------------------------------------

Future<String> _sha256OfFile(File file) async {
  final digest = await file.openRead().transform(crypto.sha256).single;
  return digest.toString();
}

/// Resolve the effective Stage D worker count.
///
///   * Explicit [workers] wins, clamped to `[1, 16]`.
///   * Otherwise: `min(Platform.numberOfProcessors - 2, 16)` clamped to
///     `>= 1`. Two-core reserve keeps room for the coordinator + OS.
int _resolveWorkers(int? workers) {
  if (workers != null) {
    return workers.clamp(1, 16);
  }
  final cpus = Platform.numberOfProcessors;
  final auto = math.min(cpus - 2, 16);
  return auto < 1 ? 1 : auto;
}

Future<DateTime?> _readHeaderDate(File pbf) async {
  // Ask the reader for a single entity so its header populates. If the
  // stream throws (empty/malformed PBF) we surface as a parse error via the
  // reader's own PipelineParseError.
  final reader = PbfReader();
  final subscription = reader.stream(pbf).listen(null);
  try {
    // Wait for the first entity (or end-of-stream) to give the header a
    // chance to populate. Using a Completer keeps the stream drain minimal.
    final completer = Completer<void>();
    subscription
      ..onData((_) {
        if (!completer.isCompleted) completer.complete();
      })
      ..onDone(() {
        if (!completer.isCompleted) completer.complete();
      })
      ..onError((Object err, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(err, st);
      });
    await completer.future;
  } finally {
    await subscription.cancel();
  }
  final h = reader.header;
  if (h == null) return null;
  final ts = h.osmosisReplicationTimestamp;
  if (ts == null || ts == 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
}
