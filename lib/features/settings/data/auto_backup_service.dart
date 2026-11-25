import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/settings/data/backup_service.dart';
import 'package:auto_explore/features/settings/data/cloud_backup_folder.dart';

/// Orchestrates automatic DB backups into the user-chosen cloud folder.
///
/// Reuses [BackupService.createBackup] (VACUUM INTO `.trailblazer` in temp)
/// and [CloudBackupFolder.writeBackup] (persistent native folder write). Pure
/// Dart, fully unit-testable: the clock is injected and all collaborators are
/// behind seams.
///
/// Never throws — every outcome is a [Result]. The last-backup timestamp is
/// stamped ONLY on a successful write, so a failed or not-yet-due run retries
/// on the next qualifying launch (mirrors the startup-migration pattern).
class AutoBackupService {
  AutoBackupService(
    this._backupService,
    this._cloudFolder,
    this._prefs, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BackupService _backupService;
  final CloudBackupFolder _cloudFolder;
  final AppPrefs _prefs;
  final DateTime Function() _now;

  /// Whether an automatic backup is due right now.
  ///
  /// `false` when the feature is disabled, when no writable folder is
  /// available, or when the interval has not yet elapsed since the last
  /// successful backup. `true` on the first run after enabling (no timestamp).
  Future<bool> isDue(DateTime now) async {
    if (!await _prefs.getAutoBackupEnabled()) return false;
    if (!await _cloudFolder.hasFolder()) return false;

    final last = await _prefs.getLastAutoBackupAt();
    if (last == null) return true; // first run after enabling

    final intervalDays = await _prefs.getAutoBackupIntervalDays();
    return now.difference(last) >= Duration(days: intervalDays);
  }

  /// Runs an automatic backup only when [isDue]. A no-op (returns [Ok]) when
  /// not due. Safe to call on every launch / resume.
  Future<Result<void>> runIfDue() async {
    final now = _now();
    if (!await isDue(now)) return const Ok(null);
    return _runBackup(now);
  }

  /// Runs a backup immediately, bypassing the due check (the "Jetzt sichern"
  /// manual trigger). Still stamps the timestamp on success.
  Future<Result<void>> runNow() => _runBackup(_now());

  /// Creates the backup file and writes it into the chosen folder, stamping
  /// the last-backup timestamp only on success.
  Future<Result<void>> _runBackup(DateTime now) async {
    final created = await _backupService.createBackup();
    switch (created) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        final destName = _destFileName(now);
        final written = await _cloudFolder.writeBackup(value, destName);
        if (written case Ok()) {
          await _prefs.setLastAutoBackupAt(now);
        }
        return written;
    }
  }

  /// Date-stamped destination name so the folder keeps a weekly history rather
  /// than overwriting a single file, e.g. `trailblazer-backup-2026-11-25.trailblazer`.
  String _destFileName(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final mo = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return 'trailblazer-backup-$y-$mo-$d.trailblazer';
  }
}
