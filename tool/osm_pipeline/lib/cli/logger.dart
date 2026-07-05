import 'dart:io';

/// Bare-bones stderr logger for the OSM pipeline CLI.
///
/// v1 intentionally avoids a dependency on the `logging` package — the CLI
/// only needs three severity levels and stderr as the sink. Downstream plans
/// may swap this for a richer implementation if progress reporting demands it.
abstract final class Logger {
  /// Write an informational message.
  static void info(String message) {
    stderr.writeln('[info] $message');
  }

  /// Write a warning message.
  static void warn(String message) {
    stderr.writeln('[warn] $message');
  }

  /// Write an error message.
  static void error(String message) {
    stderr.writeln('[error] $message');
  }
}
