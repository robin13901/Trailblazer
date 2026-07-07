/// Cross-platform tippecanoe subprocess runner.
///
/// tippecanoe has no first-party Windows binary — the Windows dev-box path
/// shells out via `wsl.exe` to a WSL2-installed tippecanoe. macOS/Linux
/// invokes the binary directly.
///
/// Path translation: tippecanoe running under WSL sees Linux paths, so
/// Windows paths must be rewritten to `/mnt/{drive}/{path}` before being
/// passed as arguments. See [wslifyPath].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/cli/logger.dart';

/// Executes tippecanoe subprocess invocations, streaming stdout/stderr to
/// the pipeline logger.
abstract final class TippecanoeRunner {
  /// Runs tippecanoe with the given [args].
  ///
  /// On Windows shells out via `wsl.exe tippecanoe …`; on macOS/Linux
  /// invokes `tippecanoe` directly. Stdout is streamed to [Logger.info],
  /// stderr to [Logger.warn].
  ///
  /// Throws [PipelineError] with the non-zero exit code and the failing
  /// argument list on failure.
  static Future<void> run(
    List<String> args, {
    Directory? workingDirectory,
  }) async {
    final resolved = _resolveExecutable();
    final combinedArgs = <String>[...resolved.prefixArgs, ...args];
    final proc = await Process.start(
      resolved.executable,
      combinedArgs,
      workingDirectory: workingDirectory?.path,
    );

    final stdoutDone = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => Logger.info('[Stage F.2] $line'))
        .asFuture<void>();
    final stderrDone = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => Logger.warn('[Stage F.2] $line'))
        .asFuture<void>();

    final code = await proc.exitCode;
    await Future.wait([stdoutDone, stderrDone]);

    if (code != 0) {
      throw PipelineIoError(
        'tippecanoe exited $code',
        cause: combinedArgs,
      );
    }
  }

  /// Preflight — confirms tippecanoe is on PATH (or reachable via WSL on
  /// Windows) and returns its version banner.
  ///
  /// Throws [PipelineIoError] with actionable install instructions when
  /// the binary is missing.
  static Future<String> preflightCheck() async {
    final resolved = _resolveExecutable();
    try {
      final result = await Process.run(
        resolved.executable,
        [...resolved.prefixArgs, '--version'],
      );
      // tippecanoe prints its version banner on stderr (matches upstream
      // behaviour); we accept either stream.
      final banner = (result.stdout as String).trim().isNotEmpty
          ? result.stdout as String
          : result.stderr as String;
      if (result.exitCode != 0 && banner.trim().isEmpty) {
        throw PipelineIoError(
          _installHint('tippecanoe --version exited '
              '${result.exitCode} with no banner'),
        );
      }
      return banner.trim();
    } on ProcessException catch (err) {
      throw PipelineIoError(
        _installHint('tippecanoe not found: ${err.message}'),
        cause: err,
      );
    }
  }

  /// Resolves the executable + prefix arguments for the current platform.
  ///
  /// Exposed for testing — the return value is a record so unit tests can
  /// assert both fields without reflection.
  static ({String executable, List<String> prefixArgs}) _resolveExecutable() {
    if (Platform.isWindows) {
      return (executable: 'wsl.exe', prefixArgs: ['tippecanoe']);
    }
    return (executable: 'tippecanoe', prefixArgs: <String>[]);
  }

  /// Public wrapper of [_resolveExecutable] for test coverage.
  static ({String executable, List<String> prefixArgs})
      resolveExecutableForTests() => _resolveExecutable();

  static String _installHint(String reason) {
    return '$reason. See tool/osm_pipeline/README.md for install '
        'instructions (Windows: wsl --install then build from '
        'https://github.com/felt/tippecanoe).';
  }
}

/// Converts a Windows absolute path to its WSL2 mount equivalent.
///
/// `C:\Users\me\out\file.geojsonl` → `/mnt/c/Users/me/out/file.geojsonl`.
/// Paths that don't start with a drive letter (i.e. already POSIX-shaped)
/// are returned unchanged, with `\` normalised to `/`.
///
/// Pure — the transformation is applied unconditionally so unit tests are
/// deterministic across host platforms. Callers on macOS/Linux should not
/// need to invoke this at all; the path-mapper in `pmtiles_pipeline.dart`
/// gates the call on `Platform.isWindows`.
String wslifyPath(String path) {
  final match = RegExp(r'^([A-Za-z]):[\\/](.*)$').firstMatch(path);
  if (match == null) return path;
  final drive = match.group(1)!.toLowerCase();
  final rest = match.group(2)!.replaceAll(r'\', '/');
  return '/mnt/$drive/$rest';
}
