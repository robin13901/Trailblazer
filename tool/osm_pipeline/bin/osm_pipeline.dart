import 'dart:io';

import 'package:osm_pipeline/admin/admin_pipeline.dart';
import 'package:osm_pipeline/cli/args.dart';
import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/filter/way_pipeline.dart';
import 'package:osm_pipeline/schema.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:osm_pipeline/scratch/scratch_db_admin_ext.dart';

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

    // Stage C — admin boundary extraction.
    final adminWriter = ScratchDbAdminWriter(scratch);
    try {
      final adminSummary = await extractAdminRegions(
        pbf: File(args.pbfPath),
        writer: adminWriter,
      );
      Logger.info(
        'Stage C (admin extraction): '
        '${adminSummary.relationsAccepted}/${adminSummary.relationsSeen} '
        'admin relations accepted, ${adminSummary.regionsWritten} rows '
        'written (${adminSummary.dualWrites} city-state dual-writes), '
        '${adminSummary.rejected} rejected.',
      );
    } finally {
      adminWriter.dispose();
    }

    Logger.info(
      'Stages D/E not implemented yet — plans 04-05..04-10 fill this in.',
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
