import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/domain/backup_validation_result.dart';

/// Abstract seam for App DB backup and restore operations.
///
/// All failures are surfaced via [Result] — no raw throwables leak from
/// implementations. Callers should match on [Ok]/[Err] and map errors to
/// user-visible messages.
///
/// ### Restore contract
///
/// [restore] performs the full wipe-and-swap sequence internally:
///
/// 1. Validates the incoming file (rejects corrupt/foreign/newer-schema files
///    **before** the live DB is touched).
/// 2. Takes a safety snapshot of the current DB (`VACUUM INTO` to temp dir).
/// 3. Closes the live Drift database (`db.close()`).
/// 4. Deletes `app_db.sqlite`, `app_db.sqlite-wal`, `app_db.sqlite-shm`.
/// 5. Copies the backup file to the DB location.
/// 6. Calls `ref.invalidate(appDatabaseProvider)` — Riverpod schedules the
///    rebuild for the **next frame** (not synchronously). Any code that reads
///    `appDatabaseProvider` immediately after this call in the same frame will
///    see a closed/stale provider.
///
/// **Callers must navigate away or show a "Restoring…" loading state after
/// calling [restore] — do NOT read the database synchronously in the same
/// frame.**
abstract interface class BackupService {
  /// Creates a single-file backup in a temp directory and returns its path.
  ///
  /// The output is a self-contained `.trailblazer` SQLite file produced via
  /// `VACUUM INTO` — guaranteed no `-wal`/`-shm` sidecars on the output.
  /// The caller is responsible for sharing or persisting the file.
  Future<Result<String>> createBackup();

  /// Validates [path] without touching the live database.
  ///
  /// Returns [BackupValid] (with the detected schema version) when the file
  /// is safe to restore, or [BackupInvalid] (with a reason) when it should be
  /// rejected. Never throws; SQLite exceptions are caught and wrapped.
  Future<BackupValidationResult> validateBackup(String path);

  /// Performs a full wipe-and-swap restore from [path].
  ///
  /// The live database is closed, replaced by the backup, and the provider is
  /// invalidated. See the class-level restore contract for timing details.
  ///
  /// Returns [Err] if [path] fails validation or if any I/O step fails. The
  /// live DB is **never modified** if validation fails.
  Future<Result<void>> restore(String path);
}
