// Trailblazer: backup-restore staging + launch-time swap.
//
// Restoring a backup by closing the LIVE Drift database and swapping the file
// in-place deadlocks: the whole app (map, regions, trips) still holds active
// `.watch()` stream subscriptions, so `db.close()` never completes while those
// subscribers are alive — and they are only torn down on provider invalidation,
// which would come AFTER the close. The spinner spins forever.
//
// This module implements the robust alternative:
//   1. `stagePendingRestore` copies the validated backup to a *pending* file in
//      the documents directory. The live DB is never touched.
//   2. On the next launch — BEFORE Drift opens the database — `main()` calls
//      `applyPendingRestoreIfAny`, which swaps the pending file into place with
//      NO open connections. That is instant and deadlock-free.
//
// Pure dart:io + sqlite3 (no Flutter, no Riverpod) so it is unit-testable with
// a plain temp directory and runs safely in `main()` before `runApp`.

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

final _log = Logger('restore_staging');

/// File name of the live Drift database.
///
/// drift_flutter's `driftDatabase(name: 'app_db')` stores
/// `app_db.sqlite` in `getApplicationDocumentsDirectory()` (verified against
/// drift_flutter 0.3.0 `src/native.dart`). The swap below targets that exact
/// file plus its `-wal`/`-shm` sidecars.
const String kAppDbFileName = 'app_db.sqlite';

/// File name of a restore that has been staged and is awaiting the next launch.
const String kPendingRestoreFileName = 'app_db.restore-pending';

/// Temp name used WHILE copying the backup. Renamed to [kPendingRestoreFileName]
/// only after the copy fully completes, so a crash mid-copy can never leave a
/// truncated file that the launch swap would trust.
const String kPendingRestoreTmpFileName = 'app_db.restore-pending.tmp';

/// Tables a staged file must contain to be swapped in at launch. A superset of
/// this is validated (schema version + integrity) at stage time; this is the
/// cheap belt-and-suspenders metadata check before we delete the live DB.
const Set<String> kRequiredBackupTables = {
  'trips',
  'trip_points',
  'driven_way_intervals',
};

/// Stages [backupPath] as a pending restore inside [documentsDir].
///
/// Copies to a `.tmp` file first, then atomically renames it to the pending
/// file. Does NOT touch the live database. Overwrites any previously staged
/// restore. Returns the pending file path.
Future<String> stagePendingRestore({
  required String backupPath,
  required String documentsDir,
}) async {
  final tmpPath = p.join(documentsDir, kPendingRestoreTmpFileName);
  final pendingPath = p.join(documentsDir, kPendingRestoreFileName);

  final tmpFile = File(tmpPath);
  if (tmpFile.existsSync()) tmpFile.deleteSync();
  final existingPending = File(pendingPath);
  if (existingPending.existsSync()) existingPending.deleteSync();

  await File(backupPath).copy(tmpPath);
  await tmpFile.rename(pendingPath);
  _log.info('Staged pending restore at $pendingPath');
  return pendingPath;
}

/// Whether a pending restore is currently staged in [documentsDir].
bool hasPendingRestore(String documentsDir) =>
    File(p.join(documentsDir, kPendingRestoreFileName)).existsSync();

/// Applies a staged restore if one is present, swapping it into the live DB
/// location. MUST run before the database is opened (no connections open).
///
/// Steps when a pending file exists AND looks like a Trailblazer DB:
///   1. Delete `app_db.sqlite` + `-wal` + `-shm`.
///   2. Rename the pending file to `app_db.sqlite`.
///
/// Best-effort and idempotent:
///   * A stray `.tmp` (crash mid-staging) is always discarded.
///   * A pending file that does NOT look like a valid Trailblazer DB is
///     discarded WITHOUT touching the live DB (never wipe good data for a bad
///     staged file).
///
/// Returns `true` only when a restore was actually applied.
Future<bool> applyPendingRestoreIfAny(String documentsDir) async {
  final tmpFile = File(p.join(documentsDir, kPendingRestoreTmpFileName));
  if (tmpFile.existsSync()) {
    _deleteQuietly(tmpFile);
  }

  final pendingFile = File(p.join(documentsDir, kPendingRestoreFileName));
  if (!pendingFile.existsSync()) return false;

  if (!isPlausibleTrailblazerDb(pendingFile.path)) {
    _log.warning(
      'Discarding staged restore — not a valid Trailblazer DB; live DB kept.',
    );
    _deleteQuietly(pendingFile);
    return false;
  }

  final mainPath = p.join(documentsDir, kAppDbFileName);
  for (final path in [mainPath, '$mainPath-wal', '$mainPath-shm']) {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }
  await pendingFile.rename(mainPath);
  _log.info('Applied pending restore → $mainPath');
  return true;
}

/// Cheap metadata check: opens [path] read-only and confirms it is an SQLite
/// file with a non-zero Drift `user_version` and all [kRequiredBackupTables].
/// No `integrity_check` (that ran at stage time). Never throws.
bool isPlausibleTrailblazerDb(String path) {
  Database? db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    final uvRows = db.select('PRAGMA user_version');
    final uv = uvRows.isNotEmpty ? uvRows.first.values.first! as int : 0;
    if (uv <= 0) return false;
    final tableRows = db.select(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final tables = tableRows.map((r) => r['name']! as String).toSet();
    return kRequiredBackupTables.difference(tables).isEmpty;
  } on SqliteException catch (e) {
    _log.warning('Staged file is not valid SQLite: $e');
    return false;
  } on Object catch (e) {
    _log.warning('Staged file plausibility check failed: $e');
    return false;
  } finally {
    db?.close();
  }
}

void _deleteQuietly(File f) {
  try {
    f.deleteSync();
  } on FileSystemException catch (e) {
    _log.warning('Could not delete ${f.path}: $e');
  }
}
