import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Configure the root logger. Call ONCE from `main()` before `runApp`.
///
/// * Debug builds: `Level.ALL` (everything).
/// * Release builds: `Level.WARNING` (warnings + severe only).
///
/// Sink is `dart:developer` `log()` in debug (structured DevTools output)
/// and `debugPrint` in release for CI-visible logs. No remote sink —
/// diagnostics screen (Phase 10) will surface these locally.
void setupLogging() {
  Logger.root.level = kDebugMode ? Level.ALL : Level.WARNING;
  Logger.root.onRecord.listen(_emit);
}

void _emit(LogRecord r) {
  final line =
      '${r.level.name}: [${r.loggerName}] ${r.time.toIso8601String()} ${r.message}';
  if (kDebugMode) {
    developer.log(
      r.message,
      name: r.loggerName,
      level: r.level.value,
      time: r.time,
      error: r.error,
      stackTrace: r.stackTrace,
    );
  } else {
    debugPrint(line);
    if (r.error != null) {
      debugPrint('  ERROR: ${r.error}');
    }
    if (r.stackTrace != null) {
      debugPrint('  STACK: ${r.stackTrace}');
    }
  }
}
