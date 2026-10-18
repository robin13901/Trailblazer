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
/// [restore] does NOT swap the live database in-place. Doing so would require
/// closing the running Drift DB while the app still holds active `.watch()`
/// subscriptions, which deadlocks. Instead [restore]:
///
/// 1. Validates the incoming file (rejects corrupt/foreign/newer-schema files
///    **before** anything is written).
/// 2. **Stages** the validated file as a pending restore in the documents
///    directory. The live DB is left completely untouched.
///
/// The actual swap happens on the **next app launch**, before the database is
/// opened, via `applyPendingRestoreIfAny` in `main()` (see
/// `restore_staging.dart`). With no open connections the swap is instant and
/// cannot deadlock.
///
/// **Callers must tell the user to restart the app** after a successful
/// [restore] — the restored data only becomes active on the next launch.
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

  /// Validates [path] and stages it as a pending restore for the next launch.
  ///
  /// The live database is **not** modified. On success the caller must prompt
  /// the user to restart the app; the staged file is swapped in at launch (see
  /// the class-level restore contract).
  ///
  /// Returns [Err] if [path] fails validation or if staging I/O fails. The
  /// live DB is **never modified** in any case.
  Future<Result<void>> restore(String path);
}
