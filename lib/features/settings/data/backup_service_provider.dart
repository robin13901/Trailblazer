import 'package:auto_explore/features/settings/data/backup_service.dart';
import 'package:auto_explore/features/settings/data/drift_backup_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides the [BackupService] implementation backed by [DriftBackupService].
///
/// Plain `Provider` — Riverpod codegen is OFF per project conventions.
/// Reads `appDatabaseProvider` via `Ref.read()` on each call (not cached).
final backupServiceProvider = Provider<BackupService>(DriftBackupService.new);
