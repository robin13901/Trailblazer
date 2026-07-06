/// Version stamp writer for the final `osm.sqlite` artifact.
///
/// Encodes the seven canonical metadata keys locked in 04-RESEARCH §9:
///   * `pbf_date` — ISO-8601 date of the source PBF (from the PBF header's
///     `osmosis_replication_timestamp` if present, otherwise a fallback).
///   * `pbf_source` — basename of the source PBF file.
///   * `pbf_sha256` — SHA-256 of the source PBF (empty string permitted for
///     synthetic fixtures).
///   * `bbox` — the `--bbox` argument as `minLng,minLat,maxLng,maxLat`, or
///     `'*'` for full-extract runs.
///   * `pipeline_schema_version` — matches [PRAGMA user_version].
///   * `pipeline_git_sha` — output of `git rev-parse HEAD`, or `'unknown'`
///     when git is unavailable / outside a checkout.
///   * `generated_at` — pipeline run start, ISO-8601 UTC.
///
/// The version stamp also writes `PRAGMA user_version = <schemaVersion>`
/// to the target DB. Phase 5's integrity check reads that PRAGMA.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Runs `git rev-parse HEAD` and returns the short SHA on success, or
/// `'unknown'` on any failure.
typedef GitShaResolver = String Function();

/// Default [GitShaResolver] implementation using `Process.runSync`.
String defaultGitShaResolver() {
  try {
    final r = Process.runSync(
      'git',
      ['rev-parse', 'HEAD'],
      runInShell: true,
    );
    if (r.exitCode != 0) return 'unknown';
    final stdout = (r.stdout as String).trim();
    return stdout.isEmpty ? 'unknown' : stdout;
  } on Object {
    return 'unknown';
  }
}

/// The seven-row metadata blob written into `osm.sqlite`.
class VersionStamp {
  /// Create a version stamp.
  VersionStamp({
    required this.pbfDate,
    required this.pbfSource,
    required this.pbfSha256,
    required this.bbox,
    required this.schemaVersion,
    required this.gitSha,
    required this.generatedAt,
  });

  /// ISO-8601 date of the source PBF (typically from
  /// `osmosis_replication_timestamp` in the OSM header).
  final DateTime pbfDate;

  /// Basename of the source PBF file (never the full path — the sha covers
  /// content identity).
  final String pbfSource;

  /// Hex-encoded SHA-256 of the source PBF bytes.
  final String pbfSha256;

  /// Optional bbox in `minLng,minLat,maxLng,maxLat` form. `null` → `'*'`.
  final String? bbox;

  /// Schema version integer, mirrored to `PRAGMA user_version`.
  final int schemaVersion;

  /// `git rev-parse HEAD` result or `'unknown'`.
  final String gitSha;

  /// Pipeline run start (UTC).
  final DateTime generatedAt;

  /// Writes all seven metadata rows and stamps `PRAGMA user_version`.
  ///
  /// Uses `INSERT OR REPLACE` so a re-run against the same DB is idempotent
  /// (see Task 3 acceptance notes — REPLACE is the executor's choice, cited
  /// in the plan's "idempotent write" bullet).
  void writeTo(Database db) {
    db.execute('PRAGMA user_version = $schemaVersion;');
    final stmt = db.prepare(
      'INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?);',
    );
    try {
      stmt
        ..execute(['pbf_date', pbfDate.toUtc().toIso8601String()])
        ..execute(['pbf_source', pbfSource])
        ..execute(['pbf_sha256', pbfSha256])
        ..execute(['bbox', bbox ?? '*'])
        ..execute(['pipeline_schema_version', '$schemaVersion'])
        ..execute(['pipeline_git_sha', gitSha])
        ..execute(['generated_at', generatedAt.toUtc().toIso8601String()]);
    } finally {
      stmt.dispose();
    }
  }

  /// Convenience: derive `pbfSource` = basename of [pbfPath].
  static String basenameOf(String pbfPath) => p.basename(pbfPath);
}
