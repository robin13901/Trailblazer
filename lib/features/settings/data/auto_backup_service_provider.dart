import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/settings/data/auto_backup_service.dart';
import 'package:auto_explore/features/settings/data/backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/cloud_backup_folder_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides the [AutoBackupService].
///
/// Plain `Provider` — Riverpod codegen is OFF per project conventions. Wires
/// the backup service, the cloud-folder seam, and prefs together; the clock
/// defaults to `DateTime.now`.
final autoBackupServiceProvider = Provider<AutoBackupService>(
  (ref) => AutoBackupService(
    ref.read(backupServiceProvider),
    ref.read(cloudBackupFolderProvider),
    ref.read(appPrefsProvider),
  ),
);
