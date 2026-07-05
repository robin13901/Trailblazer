import 'dart:io';

import 'package:osm_pipeline/cli/args.dart';
import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/schema.dart';

Future<void> main(List<String> argv) async {
  final code = await run(argv);
  exit(code);
}

/// Testable entry — returns the intended exit code instead of calling
/// [exit], so unit tests can invoke it directly.
Future<int> run(List<String> argv) async {
  try {
    final args = ParsedArgs.parse(argv);
    Logger.info('$pipelineName v$pipelineSchemaVersion');
    Logger.info('  pbf : ${args.pbfPath}');
    Logger.info('  bbox: ${args.bbox ?? "(none — full extract)"}');
    Logger.info(
      'Stages not implemented yet — plans 04-02..04-10 fill this in.',
    );
    return 0;
  } on PipelineError catch (e) {
    Logger.error(e.message);
    if (e.cause != null) {
      Logger.error('  cause: ${e.cause}');
    }
    return 2;
  }
}
