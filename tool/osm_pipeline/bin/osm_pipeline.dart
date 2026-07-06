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
      );
    final flags = extraParser.parse(argv);
    final allowUnverified = flags['allow-unverified-measurement'] as bool;
    final skipPmtiles = flags['no-pmtiles'] as bool;
    final outDirPath = (flags['out-dir'] as String?) ??
        p.join(Directory.current.path, 'out');

    // Reuse the existing ParsedArgs for --pbf / --bbox validation. It only
    // reads its own options; unknown ones would fail, so we hand it a
    // synthetic argv containing just those.
    final synthetic = <String>[
      '--pbf=${flags['pbf'] ?? ''}',
      if (flags['bbox'] != null) '--bbox=${flags['bbox']}',
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
  }
}
