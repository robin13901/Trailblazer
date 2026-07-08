// Phase 5 (Plan 05-08): Coverage-gate script for QUA-02.
//
// Reads coverage/lcov.info (post-`remove_from_coverage`), computes line
// coverage for the matcher module, prints the percentage, exits 1 when
// < 90%.
//
// Usage:
//   dart run tool/check_matcher_coverage.dart
//
// Prerequisite:
//   flutter test --coverage
//   dart pub run remove_from_coverage -f coverage/lcov.info \
//     -r '\.g\.dart$' -r '\.freezed\.dart$' -r '\.drift\.dart$' \
//     -r 'test/generated_migrations'

import 'dart:io';

const List<String> kIncludePatterns = [
  'lib/features/matching/domain/',
  'lib/core/db/daos/driven_way_intervals_dao.dart',
];
const kMinCoveragePct = 90;

Future<void> main() async {
  final lcov = File('coverage/lcov.info');
  if (!lcov.existsSync()) {
    stderr.writeln(
      'coverage/lcov.info not found — run flutter test --coverage first',
    );
    exit(2);
  }
  final lines = lcov.readAsLinesSync();
  var currentFile = '';
  var include = false;
  var totalLF = 0;
  var totalLH = 0;
  var fileLF = 0;
  var fileLH = 0;

  for (final l in lines) {
    if (l.startsWith('SF:')) {
      currentFile = l.substring(3);
      include = kIncludePatterns.any(currentFile.contains);
      fileLF = 0;
      fileLH = 0;
      continue;
    }
    if (!include) continue;
    if (l.startsWith('LF:')) {
      fileLF = int.parse(l.substring(3));
    } else if (l.startsWith('LH:')) {
      fileLH = int.parse(l.substring(3));
    } else if (l == 'end_of_record') {
      if (fileLF > 0) {
        stdout.writeln('  $currentFile: $fileLH/$fileLF');
      }
      totalLF += fileLF;
      totalLH += fileLH;
    }
  }
  if (totalLF == 0) {
    stderr.writeln('No matcher files found in coverage output');
    exit(2);
  }
  final pct = totalLH * 100.0 / totalLF;
  stdout.writeln(
    'Matcher coverage: ${pct.toStringAsFixed(1)}%'
    ' ($totalLH/$totalLF lines)',
  );
  if (pct < kMinCoveragePct) {
    stderr.writeln(
      'FAIL: coverage ${pct.toStringAsFixed(1)}%'
      ' < required $kMinCoveragePct%',
    );
    exit(1);
  }
  stdout.writeln('PASS: coverage >= $kMinCoveragePct%');
}
