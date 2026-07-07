import 'dart:io';

import 'package:args/args.dart';
import 'package:osm_pipeline/cli/args.dart';
import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/output/pipeline_orchestrator.dart';
import 'package:osm_pipeline/schema.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) async {
  final code = await run(argv);
  exit(code);
}

/// Testable entry — returns the intended exit code instead of calling
/// [exit], so unit tests can invoke it directly.
Future<int> run(List<String> argv) async {
  IOSink? logFileSink;
  try {
    // Peel off orchestrator-specific flags before delegating to ParsedArgs so
    // its `unrecognized argument` guard doesn't reject them.
    final extraParser = ArgParser()
      ..addFlag(
        'allow-unverified-measurement',
        negatable: false,
        help: 'Bypass the 04-05 measurement gate (records risk in SUMMARY).',
      )
      ..addFlag(
        'no-pmtiles',
        negatable: false,
        help: 'Skip Stage F (tippecanoe / pmtiles emit).',
      )
      ..addOption(
        'out-dir',
        help: 'Output directory (default: ./out).',
      )
      ..addOption(
        'pbf',
        help: 'Path to the input .osm.pbf file (required).',
      )
      ..addOption(
        'bbox',
        help: 'Optional bbox minLng,minLat,maxLng,maxLat',
      )
      ..addOption(
        'measurement',
        help: 'Path to 04-05-BERLIN-MEASUREMENT.md (default: auto-detected '
            'by walking up from CWD to find .planning/phases/04-osm-pipeline).',
      )
      ..addOption(
        'rtree-granularity',
        help: 'Override R-Tree granularity: perSegment | perWay. '
            'Default when omitted is perWay (Plan 04-10-1-03).',
      )
      ..addOption(
        'workers',
        help: 'Stage D worker isolate count [1, 16]. Default: '
            'Platform.numberOfProcessors - 2 (Plan 04-10-1-04). '
            'workers=1 runs the serial fast-path.',
      )
      ..addOption(
        'log-file',
        help: 'Duplicate every Logger info/warn/error line into <path>. '
            'Survives regardless of what the invoking shell does — use for '
            'long-running Germany runs launched from a bash pipe that the '
            'harness may kill (Wave 1 corrective fix, 2026-07-07).',
      );
    final flags = extraParser.parse(argv);
    final allowUnverified = flags['allow-unverified-measurement'] as bool;
    final skipPmtiles = flags['no-pmtiles'] as bool;
    final outDirPath = (flags['out-dir'] as String?) ??
        p.join(Directory.current.path, 'out');
    final measurementPath = flags['measurement'] as String?;
    final measurementFile = measurementPath != null
        ? File(measurementPath)
        : _autoDetectMeasurement();

    // Attach the durable log sink BEFORE the first Logger.* call so the
    // banner lines land in the file too.
    final logFilePath = flags['log-file'] as String?;
    if (logFilePath != null && logFilePath.isNotEmpty) {
      final logFile = File(logFilePath);
      logFile.parent.createSync(recursive: true);
      logFileSink = logFile.openWrite(mode: FileMode.writeOnly);
      Logger.setFileSink(logFileSink);
    }

    // Reuse the existing ParsedArgs for --pbf / --bbox / --rtree-granularity
    // validation. It only reads its own options; unknown ones would fail, so
    // we hand it a synthetic argv containing just those.
    final synthetic = <String>[
      '--pbf=${flags['pbf'] ?? ''}',
      if (flags['bbox'] != null) '--bbox=${flags['bbox']}',
      if (flags['rtree-granularity'] != null)
        '--rtree-granularity=${flags['rtree-granularity']}',
      if (flags['workers'] != null) '--workers=${flags['workers']}',
    ];
    final args = ParsedArgs.parse(synthetic);

    Logger.info('$pipelineName v$pipelineSchemaVersion');
    Logger.info('  pbf: ${args.pbfPath}');
    Logger.info('  bbox: ${args.bbox ?? "(none — full extract)"}');
    Logger.info('  out: $outDirPath');
    if (allowUnverified) {
      Logger.warn('--allow-unverified-measurement: SC4 risk unrecorded.');
    }

    final result = await runPipeline(
      pbf: File(args.pbfPath),
      outDir: Directory(outDirPath),
      bbox: args.bbox?.toString(),
      allowUnverifiedMeasurement: allowUnverified,
      runPmtiles: !skipPmtiles,
      measurementFile: measurementFile,
      granularityOverride: args.rtreeGranularity,
      workers: args.workers,
    );

    Logger.info('Pipeline OK.');
    Logger.info('  osm.sqlite: ${result.osmSqlitePath}');
    Logger.info('  bytes: ${result.osmSqliteBytes}');
    if (result.pmtilesResult != null) {
      Logger.info('  pmtiles: ${result.pmtilesResult!.pmtilesFile.path}');
      Logger.info('  pmtiles bytes: ${result.pmtilesResult!.pmtilesBytes}');
    }
    return 0;
  } on PipelineError catch (e) {
    Logger.error(e.message);
    if (e.cause != null) {
      Logger.error('  cause: ${e.cause}');
    }
    return 2;
  } finally {
    // Detach + flush + close the durable log sink. Runs on both the happy
    // path and the PipelineError catch — losing the tail of a log because
    // the process exited without flushing is exactly what --log-file was
    // added to prevent.
    if (logFileSink != null) {
      Logger.setFileSink(null);
      try {
        await logFileSink.flush();
      } on Object catch (_) {
        // Best-effort — a failed flush must not mask a real exit code.
      }
      await logFileSink.close();
    }
  }
}

/// Locates `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md` by
/// walking up from CWD until a `.planning` directory is found. Falls back to
/// the CWD-relative default (which fails loudly at the writer's preflight
/// gate with an actionable message) if no repo root is discovered.
File _autoDetectMeasurement() {
  const relPath =
      '.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md';
  Directory? dir = Directory.current;
  while (dir != null) {
    final probe = Directory(p.join(dir.path, '.planning'));
    if (probe.existsSync()) {
      return File(p.join(dir.path, relPath));
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return File(p.join(Directory.current.path, relPath));
}
