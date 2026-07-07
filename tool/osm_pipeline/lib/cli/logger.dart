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
///
/// **Synchronous durable file (added 2026-07-07, Wave 5 crash telemetry).**
/// [Logger.openLogFile] opens a [RandomAccessFile] and every log line is
/// written via `writeStringSync` + `flushSync`. This is the CRITICAL path for
/// post-mortem analysis of silent crashes — an IOSink is stream-buffered and
/// its tail can be lost if the process dies. The RandomAccessFile path bypasses
/// buffering entirely; every log line is on disk before the next Dart statement
/// executes. The [IOSink]-based [setFileSink] API is retained (unchanged) for
/// tests and callers that want a stream sink.
abstract final class Logger {
  static IOSink? _fileSink;
  static RandomAccessFile? _durableFile;

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

  /// Opens a synchronous durable log file at [path]. Every subsequent
  /// `info` / `warn` / `error` call writes the line to the file and calls
  /// `flushSync` — guaranteeing the byte hits disk before the caller returns.
  ///
  /// This is the API `bin/osm_pipeline.dart` uses for `--log-file=<path>`.
  /// Prefer this over [setFileSink] for long-running runs where a silent
  /// crash would otherwise lose the tail of the log.
  ///
  /// Overwrites any previously-opened durable file (which is closed first).
  static void openLogFile(String path) {
    closeLogFile();
    final f = File(path);
    f.parent.createSync(recursive: true);
    _durableFile = f.openSync(mode: FileMode.writeOnly);
  }

  /// Flushes + closes the synchronous durable log file, if one is open.
  /// Idempotent — safe to call in a `finally` block.
  static void closeLogFile() {
    final raf = _durableFile;
    _durableFile = null;
    if (raf != null) {
      try {
        raf.flushSync();
      } on Object {
        // ignore flush errors during close — file is going away anyway.
      }
      try {
        raf.closeSync();
      } on Object {
        // ignore close errors during teardown — nothing we can do.
      }
    }
  }

  /// Whether a synchronous durable log file is currently open.
  /// Exposed for tests / diagnostics.
  static bool get hasDurableLogFile => _durableFile != null;

  static void _writeDurable(String line) {
    final raf = _durableFile;
    if (raf == null) return;
    try {
      raf
        ..writeStringSync('$line\n')
        ..flushSync();
    } on Object {
      // Best-effort — a write failure to the durable file must not mask the
      // primary work. The user still has stderr.
    }
  }

  /// Write an informational message.
  static void info(String message) {
    final line = '[info] $message';
    stderr.writeln(line);
    _fileSink?.writeln(line);
    _writeDurable(line);
  }

  /// Write a warning message.
  static void warn(String message) {
    final line = '[warn] $message';
    stderr.writeln(line);
    _fileSink?.writeln(line);
    _writeDurable(line);
  }

  /// Write an error message.
  static void error(String message) {
    final line = '[error] $message';
    stderr.writeln(line);
    _fileSink?.writeln(line);
    _writeDurable(line);
  }
}
