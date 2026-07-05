import 'dart:io';

import 'package:osm_pipeline/cli/args.dart';
import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/filter/way_pipeline.dart';
import 'package:osm_pipeline/schema.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';

Future<void> main(List<String> argv) async {
  final code = await run(argv);
  exit(code);
}

/// Testable entry — returns the intended exit code instead of calling
/// [exit], so unit tests can invoke it directly.
Future<int> run(List<String> argv) async {
  ScratchDb? scratch;
  try {
    final args = ParsedArgs.parse(argv);
    Logger.info('$pipelineName v$pipelineSchemaVersion');
    Logger.info('  pbf : ${args.pbfPath}');
    Logger.info('  bbox: ${args.bbox ?? "(none — full extract)"}');

    scratch = ScratchDb.openTempFile();
    Logger.info('  scratch: ${scratch.file.path}');

    // Stage B — highway filter + directionality normalization.
    final wayStats = await const WayPipeline().run(
      pbf: File(args.pbfPath),
      scratch: scratch,
    );
    Logger.info(
      'Stage B (highway filter): '
      '${wayStats.kfzWays} Kfz, ${wayStats.feldwegWays} Feldweg, '
      '${wayStats.nodes} nodes, ${wayStats.rejected} rejected '
      '(highway=road: ${wayStats.highwayRoad}, '
      'deleted-node-refs: ${wayStats.deletedNodeRefs}).',
    );
    Logger.info(
      'Stages C/D/E not implemented yet — plans 04-04..04-10 fill this in.',
    );
    return 0;
  } on PipelineError catch (e) {
    Logger.error(e.message);
    if (e.cause != null) {
      Logger.error('  cause: ${e.cause}');
    }
    return 2;
  } finally {
    scratch?.close(deleteFile: true);
  }
}
