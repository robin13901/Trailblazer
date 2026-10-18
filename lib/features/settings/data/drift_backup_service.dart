import 'dart:io';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/data/backup_service.dart';
import 'package:auto_explore/features/settings/data/restore_staging.dart';
import 'package:auto_explore/features/settings/domain/backup_validation_result.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Current Drift schemaVersion. Must match [AppDatabase.schemaVersion].
/// Updated here whenever the schema version bumps.
const int kCurrentSchemaVersion = 10;

/// Tables required to exist for a Trailblazer backup to be considered valid.
const Set<String> _requiredTables = kRequiredBackupTables;

/// Concrete backup/restore implementation backed by Drift + raw SQLite.
///
/// Uses `VACUUM INTO` to produce a single-file, WAL-free backup.
/// Uses `package:sqlite3` directly for validation to avoid triggering Drift
/// migration machinery on an untrusted file.
///
/// **Restore is deferred to the next launch** ([restore] stages the file; the
/// swap happens in `main()` via `restore_staging.dart`). This avoids closing
/// the live DB while the app holds active Drift watch-streams — an in-place
/// live swap deadlocks on `db.close()`.
class DriftBackupService implements BackupService {
  const DriftBackupService(this._ref);

  final Ref _ref;

  // ---------------------------------------------------------------------------
  // BackupService.createBackup
  // ---------------------------------------------------------------------------

  @override
  Future<Result<String>> createBackup() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final filename = 'trailblazer_backup_${_timestamp()}.trailblazer';
      final destPath = p.join(tempDir.path, filename);

      final db = _ref.read(appDatabaseProvider);
      await db.customStatement('VACUUM INTO ?', [destPath]);

      return Ok(destPath);
    } on DomainError catch (e) {
      return Err(e);
    } on FileSystemException catch (e, st) {
      return Err(
        StorageError('Backup I/O failed: $e', cause: e, stackTrace: st),
      );
    } on Object catch (e, st) {
      return Err(
        DatabaseError('Backup failed: $e', cause: e, stackTrace: st),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // BackupService.validateBackup
  // ---------------------------------------------------------------------------

  @override
  Future<BackupValidationResult> validateBackup(String path) async {
    Database? db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);

      // 1. SQLite file integrity. `quick_check` instead of the exhaustive
      //    `integrity_check`: it catches corruption (bad pages, unreadable
      //    b-trees) but skips the costly index cross-checks, so it stays fast
      //    even on large (tens-of-MB) backups. A full integrity_check could
      //    take minutes on-device for a GPS-point-heavy DB.
      final integrityRows = db.select('PRAGMA quick_check');
      final integrityResult = integrityRows.isNotEmpty
          ? integrityRows.first.values.first! as String
          : '';
      if (integrityResult != 'ok') {
        return BackupInvalid('quick_check: $integrityResult');
      }

      // 2. Schema version check via user_version (Drift's version pragma).
      final uvRows = db.select('PRAGMA user_version');
      final uv = uvRows.isNotEmpty ? uvRows.first.values.first! as int : 0;

      if (uv == 0) {
        return const BackupInvalid('not a Trailblazer backup (user_version=0)');
      }
      if (uv > kCurrentSchemaVersion) {
        return BackupInvalid(
          'backup from a newer app version ($uv > $kCurrentSchemaVersion)',
        );
      }
      // uv < kCurrentSchemaVersion is accepted — Drift migrates on re-open.

      // 3. Required tables present.
      final tableRows = db.select(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final tables = tableRows.map((r) => r['name']! as String).toSet();
      final missing = _requiredTables.difference(tables);
      if (missing.isNotEmpty) {
        return BackupInvalid('missing tables: ${missing.join(', ')}');
      }

      return BackupValid(schemaVersion: uv);
    } on SqliteException catch (e) {
      return BackupInvalid('not a valid SQLite file: $e');
    } finally {
      db?.close();
    }
  }

  // ---------------------------------------------------------------------------
  // BackupService.restore
  // ---------------------------------------------------------------------------

  @override
  Future<Result<void>> restore(String path) async {
    // Step 1: Validate BEFORE staging anything.
    final validation = await validateBackup(path);
    if (validation is BackupInvalid) {
      return Err(StorageError('Invalid backup: ${validation.reason}'));
    }

    try {
      // Step 2: Stage the validated backup for a swap at the NEXT launch.
      //
      // We deliberately do NOT close + swap the live DB here. The app holds
      // many active Drift `.watch()` subscriptions (map, regions, trips); a
      // live `db.close()` blocks until those drain, but they only tear down on
      // provider invalidation AFTER the close — a deadlock that hangs the
      // restore spinner forever. Instead `main()` swaps the staged file in
      // before the DB is ever opened (see restore_staging.dart), where there
      // are no open connections. The live DB is untouched until then.
      final docsDir = await getApplicationDocumentsDirectory();
      await stagePendingRestore(
        backupPath: path,
        documentsDir: docsDir.path,
      );
      return const Ok(null);
    } on DomainError catch (e) {
      return Err(e);
    } on FileSystemException catch (e, st) {
      return Err(
        StorageError('Restore staging I/O failed: $e', cause: e, stackTrace: st),
      );
    } on Object catch (e, st) {
      return Err(DatabaseError('Restore failed: $e', cause: e, stackTrace: st));
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns a `YYYYMMDD_HHmm` timestamp string for backup file naming.
  String _timestamp() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final mo = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final mi = now.minute.toString().padLeft(2, '0');
    return '$y$mo${d}_$h$mi';
  }
}
