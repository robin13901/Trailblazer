import 'package:auto_explore/features/settings/data/cloud_backup_folder.dart';
import 'package:auto_explore/features/settings/data/method_channel_cloud_backup_folder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides the [CloudBackupFolder] implementation backed by the native
/// platform channel.
///
/// Plain `Provider` — Riverpod codegen is OFF per project conventions.
/// Overridden with `FakeCloudBackupFolder` in tests via `ProviderScope`.
final cloudBackupFolderProvider = Provider<CloudBackupFolder>(
  (_) => const MethodChannelCloudBackupFolder(),
);
