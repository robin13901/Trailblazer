/// CLI wrapper for the Berlin-bbox row-count probe (04-05 Task 2).
///
/// Reads the target PBF path from `TRAILBLAZER_BERLIN_PBF`. If unset, prints
/// download instructions and exits non-zero — Task 3 (checkpoint) is where
/// the real Berlin run happens.
///
/// Writes the markdown report to
/// `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md`.
///
/// Usage:
///   dart run tool/osm_pipeline/bin/measure_berlin_row_count.dart
library;

import 'dart:io';

import 'package:osm_pipeline/measure/berlin_row_count_probe.dart';
import 'package:path/path.dart' as p;

const String _envVarName = 'TRAILBLAZER_BERLIN_PBF';
const String _reportRelativePath =
    '.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md';

Future<void> main(List<String> argv) async {
  exit(await run(argv));
}

/// Testable entry — returns the exit code.
Future<int> run(List<String> argv) async {
  final pbfPath = Platform.environment[_envVarName];
  if (pbfPath == null || pbfPath.isEmpty) {
    _printDownloadInstructions();
    return 1;
  }
  final pbfFile = File(pbfPath);
  if (!pbfFile.existsSync()) {
    stderr.writeln(
      'Path in $_envVarName does not exist:\n  $pbfPath',
    );
    return 1;
  }

  stdout.writeln('Running Berlin row-count probe on ${pbfFile.path}...');
  final result = await runBerlinRowCountProbe(pbf: pbfFile);
  final report = renderBerlinMeasurementReport(result);

  // Locate the .planning directory relative to the repo root — the CLI is
  // expected to run from the repo root (that's how `dart run
  // tool/osm_pipeline/bin/...` invokes it).
  final reportFile = File(_reportRelativePath);
  await reportFile.parent.create(recursive: true);
  await reportFile.writeAsString(report);

  stdout
    ..writeln()
    ..writeln('--- Measurement report ---')
    ..writeln(report)
    ..writeln(
      'Wrote report to ${p.normalize(reportFile.absolute.path)}',
    );
  return 0;
}

void _printDownloadInstructions() {
  stdout.writeln('''
Berlin PBF not provided. Download from
  https://download.geofabrik.de/europe/germany/berlin.html
then set $_envVarName=/absolute/path/to/berlin-latest.osm.pbf
and rerun:
  dart run tool/osm_pipeline/bin/measure_berlin_row_count.dart

Windows PowerShell:
  \$env:$_envVarName = "C:\\path\\to\\berlin-latest.osm.pbf"
  dart run tool/osm_pipeline/bin/measure_berlin_row_count.dart
''');
}
