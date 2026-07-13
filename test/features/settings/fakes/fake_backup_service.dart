import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/data/backup_service.dart';
import 'package:auto_explore/features/settings/domain/backup_validation_result.dart';

/// In-memory test double for [BackupService].
///
/// No filesystem access, no Drift — pure in-memory state.
/// Inject via `ProviderScope.overrides` in widget/unit tests.
///
/// Toggle [validateShouldFail] and [restoreShouldFail] to exercise failure
/// paths without any real I/O.
class FakeBackupService implements BackupService {
  /// Path returned by [createBackup]. Null until the first call.
  String? lastExportedPath;

  /// When true, [createBackup] returns [Err] instead of [Ok].
  bool createShouldFail = false;

  /// When true, [validateBackup] returns [BackupInvalid('fake')].
  /// When false, returns [BackupValid(schemaVersion: 4)].
  bool validateShouldFail = false;

  /// When true, [restore] returns [Err(StorageError('fake'))].
  /// When false, returns [Ok(null)] and records the path in [restoredPaths].
  bool restoreShouldFail = false;

  /// Accumulates every path passed to [restore] (in order).
  final List<String> restoredPaths = [];

  @override
  Future<Result<String>> createBackup() async {
    if (createShouldFail) {
      return const Err(StorageError('fake create failure'));
    }
    lastExportedPath = '/fake/backup.trailblazer';
    return Ok(lastExportedPath!);
  }

  @override
  Future<BackupValidationResult> validateBackup(String path) async {
    if (validateShouldFail) {
      return const BackupInvalid('fake');
    }
    return const BackupValid(schemaVersion: 4);
  }

  @override
  Future<Result<void>> restore(String path) async {
    if (restoreShouldFail) {
      return const Err(StorageError('fake restore failure'));
    }
    restoredPaths.add(path);
    return const Ok(null);
  }
}
