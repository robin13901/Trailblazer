import 'dart:io';

/// Bare-bones stderr logger for the OSM pipeline CLI.
///
/// v1 intentionally avoids a dependency on the `logging` package — the CLI
/// only needs three severity levels and stderr as the sink. Downstream plans
/// may swap this for a richer implementation if progress reporting demands it.
///
/// **Durable log capture (added 2026-07-07, Wave 1 corrective fix).** When a
/// long-running pipeline invocation is spawned from a bash shell that later
/// dies (e.g. the harness kills the parent shell), a stdout/stderr pipe
/// attached to the invoking shell becomes defunct and subsequent writes go
/// into the void. To survive this, [Logger.setFileSink] duplicates every
/// `info` / `warn` / `error` line into an [IOSink] opened inside the Dart
/// process itself. See `bin/osm_pipeline.dart`'s `--log-file=<path>` flag.
abstract final class Logger {
  static IOSink? _fileSink;

  /// Registers an additional sink that receives a copy of every log line.
  ///
  /// Pass `null` to detach (mostly for tests). The sink is written to
  /// synchronously via [IOSink.writeln]; the caller owns its lifecycle
  /// (open + close). No implicit flush — long-running runs should invoke
  /// `sink.flush()` periodically or rely on OS write buffering.
  ///
  /// A method (not a setter) because the intent — "attach a durable log
  /// sink" — reads as an imperative action at the caller site and pairs
  /// naturally with the CLI wiring in `bin/osm_pipeline.dart` (`--log-file`).
  // ignore: use_setters_to_change_properties
  static void setFileSink(IOSink? sink) {
    _fileSink = sink;
  }

  /// Currently registered file sink, if any. Exposed for tests.
  static IOSink? get fileSink => _fileSink;

  /// Write an informational message.
  static void info(String message) {
    final line = '[info] $message';
    stderr.writeln(line);
    _fileSink?.writeln(line);
  }

  /// Write a warning message.
  static void warn(String message) {
    final line = '[warn] $message';
    stderr.writeln(line);
    _fileSink?.writeln(line);
  }

  /// Write an error message.
  static void error(String message) {
    final line = '[error] $message';
    stderr.writeln(line);
    _fileSink?.writeln(line);
  }
}
