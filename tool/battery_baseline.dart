#!/usr/bin/env dart
// battery_baseline.dart — Trailblazer battery drain measurement CLI.
//
// Measures per-app battery drain for `de.autoexplore.auto_explore` using
// `adb shell dumpsys batterystats`.
//
// Sub-commands:
//   start   — reset batterystats + record start snapshot in docs/.battery-baseline.tmp.json
//   stop    — read end state, compute drain, write docs/battery-baseline.{md,json}
//   status  — print elapsed time + current battery % (mid-drive sanity check)
//
// Usage:
//   dart run tool/battery_baseline.dart start [--device <serial>] [--app-id <id>]
//   dart run tool/battery_baseline.dart stop  [--device <serial>] [--app-id <id>] [--duration-min <int>] [--commit <sha>]
//   dart run tool/battery_baseline.dart status [--device <serial>]
//
// Requirements:
//   adb (Android SDK Platform Tools) must be on PATH.
//   See https://developer.android.com/tools/releases/platform-tools

// Rationale: this is a standalone CLI tool, not a library — print is the
// correct output mechanism and every occurrence is intentional.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(1);
  }

  final subcommand = args[0];
  final rest = args.sublist(1);

  switch (subcommand) {
    case 'start':
      await _runStart(rest);
    case 'stop':
      await _runStop(rest);
    case 'status':
      await _runStatus(rest);
    default:
      stderr.writeln('Unknown sub-command: $subcommand');
      _usage();
      exit(1);
  }
}

// ---------------------------------------------------------------------------
// Sub-command: start
// ---------------------------------------------------------------------------

Future<void> _runStart(List<String> args) async {
  final opts = _parseFlags(args);
  final device = opts['device'] as String?;
  final appId = (opts['app-id'] as String?) ?? _defaultAppId;

  _log('Resetting batterystats on device...');
  await _adb(['shell', 'dumpsys', 'batterystats', '--reset'], device: device);
  _log('batterystats reset.');

  final batteryPct = await _readBatteryPct(device: device);
  _log('Start battery: $batteryPct%');

  final commit = (opts['commit'] as String?) ?? await _gitSha();
  final now = DateTime.now().toUtc().toIso8601String();

  final snapshot = {
    'started_at': now,
    'start_battery_pct': batteryPct,
    'commit': commit,
    'app_id': appId,
    'device_serial': device,
  };

  final tmpFile = File(_tmpSnapshotPath);
  tmpFile.parent.createSync(recursive: true);
  tmpFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(snapshot),
  );

  _log('Snapshot saved to $_tmpSnapshotPath');
  _log('Drive now. Run `dart run tool/battery_baseline.dart stop` when done.');
}

// ---------------------------------------------------------------------------
// Sub-command: stop
// ---------------------------------------------------------------------------

Future<void> _runStop(List<String> args) async {
  final opts = _parseFlags(args);
  final device = opts['device'] as String?;
  final appId = (opts['app-id'] as String?) ?? _defaultAppId;

  // Read start snapshot
  final tmpFile = File(_tmpSnapshotPath);
  if (!tmpFile.existsSync()) {
    stderr.writeln(
      'ERROR: No start snapshot found at $_tmpSnapshotPath\n'
      'Did you run `dart run tool/battery_baseline.dart start` before the drive?',
    );
    exit(1);
  }

  final snapshot =
      jsonDecode(tmpFile.readAsStringSync()) as Map<String, dynamic>;

  final startedAt = DateTime.parse(snapshot['started_at'] as String);
  final startBatteryPct = (snapshot['start_battery_pct'] as num).toInt();
  final commit = (opts['commit'] as String?) ??
      (snapshot['commit'] as String?) ??
      await _gitSha();

  // Current state
  final endBatteryPct = await _readBatteryPct(device: device);
  final endedAt = DateTime.now().toUtc();
  final elapsedMin = endedAt.difference(startedAt).inSeconds / 60.0;

  // Read the explicit duration override if provided (for metadata; defaults
  // to actual elapsed time rounded to nearest minute).
  final rawDuration = opts['duration-min'];
  final durationMin = (rawDuration != null)
      ? int.parse(rawDuration as String)
      : elapsedMin.round();

  // Derived metrics
  final drainPct = startBatteryPct - endBatteryPct;
  final drainRatePctPerHour =
      elapsedMin > 0 ? drainPct / (elapsedMin / 60.0) : 0.0;

  // mAh estimate: drain_pct / 100 * nominal_mAh (S24 = 4000 mAh)
  // Prefer batterystats mAh parse; fall back to estimate.
  var mahEst = await _readMahFromBatterystats(appId, device: device);
  mahEst ??= drainPct / 100.0 * 4000.0;

  final recorded = endedAt.toIso8601String().substring(0, 10); // YYYY-MM-DD

  _log('');
  _log('=== Battery Baseline Results ===');
  _log('Device:         Samsung Galaxy S24 (SM-S921B)');
  _log('OS:             Android 14');
  _log('Commit:         $commit');
  _log('Recorded:       $recorded');
  _log('Duration:       $durationMin min (actual: ${elapsedMin.toStringAsFixed(1)} min)');
  _log('Start battery:  $startBatteryPct%');
  _log('End battery:    $endBatteryPct%');
  _log('Drain:          $drainPct%');
  _log('Drain rate:     ${drainRatePctPerHour.toStringAsFixed(1)} %/hour');
  _log('mAh estimate:   ${mahEst.toStringAsFixed(0)} mAh');
  _log('');

  // Write JSON artifact
  final jsonArtifact = {
    'reference': {
      'device': 'Samsung Galaxy S24 (SM-S921B)',
      'os': 'Android 14',
      'app_version': '0.1.0+1',
      'commit': commit,
      'recorded': recorded,
      'duration_min': durationMin,
      'start_battery_pct': startBatteryPct,
      'end_battery_pct': endBatteryPct,
      'drain_pct': drainPct,
      'drain_rate_pct_per_hour':
          double.parse(drainRatePctPerHour.toStringAsFixed(1)),
      'mah_est': double.parse(mahEst.toStringAsFixed(0)),
      'build_mode': 'debug',
      'screen_state': 'off',
      'notification': 'live-stats',
      'profile': '20 min urban + 20 min Landstraße + 20 min Autobahn',
    },
    'regression_threshold_relative_pct': 20,
    'history': <Object>[],
  };

  final jsonFile = File(_jsonArtifactPath);
  jsonFile.parent.createSync(recursive: true);
  jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(jsonArtifact));
  _log('Written: $_jsonArtifactPath');

  // Update Markdown artifact — replace TBD markers
  await _updateMarkdown(
    commit: commit,
    recorded: recorded,
    durationMin: durationMin,
    startBatteryPct: startBatteryPct,
    endBatteryPct: endBatteryPct,
    drainPct: drainPct,
    drainRatePctPerHour: drainRatePctPerHour,
    mahEst: mahEst,
  );
  _log('Updated: $_mdArtifactPath');
  _log('');
  _log('Next: review both files, then commit:');
  _log('  git add $_mdArtifactPath $_jsonArtifactPath');
  _log('  git commit -m "docs(03-07): battery baseline $recorded"');
}

// ---------------------------------------------------------------------------
// Sub-command: status
// ---------------------------------------------------------------------------

Future<void> _runStatus(List<String> args) async {
  final opts = _parseFlags(args);
  final device = opts['device'] as String?;

  // Read start snapshot if available
  final tmpFile = File(_tmpSnapshotPath);
  if (!tmpFile.existsSync()) {
    _log('No active baseline session (no $_tmpSnapshotPath found).');
    _log('Run `dart run tool/battery_baseline.dart start` to begin.');
  } else {
    final snapshot =
        jsonDecode(tmpFile.readAsStringSync()) as Map<String, dynamic>;
    final startedAt = DateTime.parse(snapshot['started_at'] as String);
    final startBatteryPct = (snapshot['start_battery_pct'] as num).toInt();
    final elapsed = DateTime.now().toUtc().difference(startedAt);
    final elapsedMin = elapsed.inSeconds ~/ 60;
    final elapsedSec = elapsed.inSeconds % 60;

    final currentPct = await _readBatteryPct(device: device);
    final drainSoFar = startBatteryPct - currentPct;

    _log('=== Baseline status ===');
    _log(
      'Elapsed:  ${elapsedMin}m ${elapsedSec}s',
    );
    _log('Battery:  $currentPct% (started at $startBatteryPct%, drained $drainSoFar% so far)');
  }
}

// ---------------------------------------------------------------------------
// adb helpers
// ---------------------------------------------------------------------------

/// Run an adb command. Throws a helpful error if adb is not found.
Future<ProcessResult> _adb(
  List<String> adbArgs, {
  String? device,
}) async {
  final baseArgs = device != null ? ['-s', device, ...adbArgs] : adbArgs;
  try {
    final result = await Process.run('adb', baseArgs);
    if (result.exitCode != 0) {
      // Non-zero is not always fatal (e.g. reset returns non-zero on some
      // Android versions but still works). Callers decide.
      _debug('adb ${baseArgs.join(' ')} → exit ${result.exitCode}');
      _debug(result.stderr.toString().trim());
    }
    return result;
  } on ProcessException catch (e) {
    stderr.writeln(
      'ERROR: adb not found or failed to run.\n'
      '  ${e.message}\n\n'
      'Install Android SDK Platform Tools and add to PATH:\n'
      '  https://developer.android.com/tools/releases/platform-tools\n'
      'Then verify with: adb devices',
    );
    exit(2);
  }
}

/// Read current battery percentage from `adb shell dumpsys battery`.
Future<int> _readBatteryPct({String? device}) async {
  final result = await _adb(['shell', 'dumpsys', 'battery'], device: device);
  final output = result.stdout.toString();
  // Look for "level: <int>"
  final match = RegExp(r'level:\s*(\d+)').firstMatch(output);
  if (match == null) {
    stderr.writeln(
      'WARNING: Could not parse battery level from dumpsys battery output.\n'
      'Output snippet: ${output.substring(0, output.length.clamp(0, 200))}',
    );
    return -1;
  }
  return int.parse(match.group(1)!);
}

/// Attempt to extract the mAh drain estimate for [appId] from batterystats.
/// Returns null if the line cannot be parsed (callers fall back to estimate).
Future<double?> _readMahFromBatterystats(
  String appId, {
  String? device,
}) async {
  _log('Reading batterystats (may take a few seconds)...');
  final result = await _adb(
    ['shell', 'dumpsys', 'batterystats', '--charged'],
    device: device,
  );
  final output = result.stdout.toString();

  // batterystats output format (Android 10+):
  // Uid u0a<N> (de.autoexplore.auto_explore):
  //   ...
  //   Estimated power use (mAh): X.XX
  //
  // Strategy: find the UID block for our app ID, then grab the mAh line
  // within the next ~20 lines.
  final lines = output.split('\n');
  var inBlock = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    if (!inBlock) {
      // Match any line that contains the app ID (package name in parens or bare).
      if (line.contains(appId)) {
        inBlock = true;
      }
      continue;
    }

    // We're inside the UID block. Look for "Estimated power use".
    if (line.contains('Estimated power use (mAh)')) {
      final match = RegExp(r'Estimated power use \(mAh\):\s*([\d.]+)')
          .firstMatch(line);
      if (match != null) {
        final mah = double.tryParse(match.group(1)!);
        if (mah != null) {
          _log('mAh from batterystats: $mah');
          return mah;
        }
      }
    }

    // A new Uid line signals we've left the block.
    if (inBlock && line.trimLeft().startsWith('Uid') && !line.contains(appId)) {
      break;
    }
  }

  _log(
    'Could not extract mAh from batterystats for $appId — using estimate.',
  );
  return null;
}

// ---------------------------------------------------------------------------
// Markdown update
// ---------------------------------------------------------------------------

Future<void> _updateMarkdown({
  required String commit,
  required String recorded,
  required int durationMin,
  required int startBatteryPct,
  required int endBatteryPct,
  required int drainPct,
  required double drainRatePctPerHour,
  required double mahEst,
}) async {
  final file = File(_mdArtifactPath);
  if (!file.existsSync()) {
    stderr.writeln(
      'WARNING: $_mdArtifactPath not found — cannot update Markdown artifact.',
    );
    return;
  }

  var content = file.readAsStringSync();

  // Replace TBD values in the table.  Each row has a fixed prefix that
  // uniquely identifies it, so we replace the "| TBD |" or "| TBD" suffix.
  content = _replaceTbd(content, '| OS |', '| Android 14 (see `adb shell getprop ro.build.display.id` for exact build string) |');
  content = _replaceTbd(content, '| Commit |', '| $commit |');
  content = _replaceTbd(content, '| Recorded |', '| $recorded |');
  content = _replaceTbd(content, '| Start battery % |', '| $startBatteryPct% |');
  content = _replaceTbd(content, '| End battery % |', '| $endBatteryPct% |');
  content = _replaceTbd(content, '| Drain % |', '| $drainPct% |');
  content = _replaceTbd(
    content,
    '| Drain rate |',
    '| ${drainRatePctPerHour.toStringAsFixed(1)} %/hour |',
  );
  content = _replaceTbd(
    content,
    '| Est. mAh',
    '| ${mahEst.toStringAsFixed(0)} mAh (S24 4000 mAh nominal) |',
  );

  file.writeAsStringSync(content);
}

/// Replace the "TBD" value in the Markdown row whose line starts with [rowPrefix].
String _replaceTbd(String content, String rowPrefix, String newRow) {
  final lines = content.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith(rowPrefix)) {
      lines[i] = newRow;
      return lines.join('\n');
    }
  }
  // If prefix not found, return content unchanged.
  _debug('_replaceTbd: could not find row with prefix: $rowPrefix');
  return content;
}

// ---------------------------------------------------------------------------
// git helper
// ---------------------------------------------------------------------------

Future<String> _gitSha() async {
  try {
    final result =
        await Process.run('git', ['rev-parse', '--short', 'HEAD']);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
  } on Exception catch (_) {
    // ignore — git may not be available in all environments
  }
  return 'unknown';
}

// ---------------------------------------------------------------------------
// Argument parsing (simple flag parser — no dependency on args package)
// ---------------------------------------------------------------------------

Map<String, Object?> _parseFlags(List<String> args) {
  final result = <String, Object?>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--')) {
      final key = arg.substring(2);
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        result[key] = args[i + 1];
        i++;
      } else {
        // Boolean flag
        result[key] = true;
      }
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

void _log(String message) {
  // Only use color/emojis when connected to a real terminal.
  final hasTerminal =
      stdout.hasTerminal && !Platform.environment.containsKey('CI');
  if (hasTerminal) {
    print(message);
  } else {
    // Shell-diffable: plain text.
    print(message);
  }
}

void _debug(String message) {
  if (Platform.environment['BATTERY_BASELINE_DEBUG'] == '1') {
    stderr.writeln('[debug] $message');
  }
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const _defaultAppId = 'de.autoexplore.auto_explore';
const _tmpSnapshotPath = 'docs/.battery-baseline.tmp.json';
const _jsonArtifactPath = 'docs/battery-baseline.json';
const _mdArtifactPath = 'docs/battery-baseline.md';

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

void _usage() {
  print('''
battery_baseline.dart — Trailblazer per-app battery drain measurement

Usage:
  dart run tool/battery_baseline.dart <sub-command> [options]

Sub-commands:
  start    Reset batterystats and record start snapshot.
           Run this at the START of the drive.

  stop     Read end state, compute drain metrics, write artifacts.
           Run this at the END of the drive.

  status   Print elapsed time + current battery % (mid-drive check).

Options (all sub-commands):
  --device <serial>      adb device serial (default: adb default device)

Options (start, stop):
  --app-id <id>          Android application ID (default: de.autoexplore.auto_explore)

Options (stop):
  --duration-min <int>   Nominal drive duration in minutes (default: actual elapsed)
  --commit <sha>         Git commit SHA to embed (default: current HEAD)

Requirements:
  adb must be on PATH — https://developer.android.com/tools/releases/platform-tools

Examples:
  # Before the drive (laptop connected to phone via USB):
  adb devices
  dart run tool/battery_baseline.dart start

  # After ~60 minutes of driving:
  dart run tool/battery_baseline.dart stop

  # Mid-drive check:
  dart run tool/battery_baseline.dart status
''');
}
