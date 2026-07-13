import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/settings/data/backup_service.dart';
import 'package:auto_explore/features/settings/data/backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/file_platform.dart';
import 'package:auto_explore/features/settings/data/file_platform_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings > Data & Backup section.
///
/// Provides two user-facing actions:
///
/// * **Export** — calls [BackupService.createBackup] then hands the resulting
///   file to [FilePlatform.shareFile] (OS share sheet / ACTION_SEND).
/// * **Restore** — calls [FilePlatform.pickBackupFile], presents a destructive
///   confirm dialog, then calls [BackupService.restore] with a progress state.
///
/// Wired into the settings screen by Plan 09-07.
class DataBackupSection extends ConsumerStatefulWidget {
  const DataBackupSection({super.key});

  @override
  ConsumerState<DataBackupSection> createState() => _DataBackupSectionState();
}

class _DataBackupSectionState extends ConsumerState<DataBackupSection> {
  bool _exporting = false;
  bool _restoring = false;

  // ── Export ──────────────────────────────────────────────────────────────────

  Future<void> _onTapExport() async {
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _exporting = true);
    try {
      final r = await ref.read(backupServiceProvider).createBackup();
      if (!mounted) return;

      switch (r) {
        case Ok(:final value):
          await ref.read(filePlatformProvider).shareFile(
                value,
                subject: 'Trailblazer Backup',
              );
          if (!mounted) return;
          messenger.showSnackBar(
            const SnackBar(content: Text('Backup ready to share')),
          );
        case Err(:final error):
          messenger.showSnackBar(
            SnackBar(content: Text(error.message)),
          );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── Restore ─────────────────────────────────────────────────────────────────

  Future<void> _onTapRestore() async {
    final messenger = ScaffoldMessenger.of(context);

    // Step 1 — pick a file; cancel if the user dismisses the picker.
    final path = await ref.read(filePlatformProvider).pickBackupFile();
    if (path == null) return;
    if (!mounted) return;

    // Step 2 — destructive confirm dialog.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Replace all data?'),
        content: const Text(
          'Restoring will PERMANENTLY replace all current trips, coverage, '
          'and settings with the contents of this backup. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    // Step 3 — show restoring progress state.
    setState(() => _restoring = true);
    try {
      // Step 4 — perform the restore.
      final r = await ref.read(backupServiceProvider).restore(path);
      if (!mounted) return;

      switch (r) {
        case Ok():
          // appDatabaseProvider was invalidated inside restore(); dependents
          // rebuild on the next frame. Show feedback and let the tree refresh.
          messenger.showSnackBar(
            const SnackBar(content: Text('Backup restored')),
          );
        case Err(:final error):
          // Validation or I/O failed — live DB is intact (safety-snapshot
          // contract in BackupService).
          messenger.showSnackBar(
            SnackBar(content: Text('Restore failed: ${error.message}')),
          );
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Export tile
        ListTile(
          title: const Text('Back up my data'),
          subtitle: const Text('Creates a shareable copy of all your trips & coverage'),
          trailing: _exporting
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.backup_outlined),
          onTap: (_exporting || _restoring) ? null : _onTapExport,
        ),

        // Restore tile
        ListTile(
          title: const Text('Restore from backup'),
          subtitle: const Text(
            'Replaces ALL current data with a backup file',
          ),
          trailing: _restoring
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.restore_outlined),
          onTap: (_exporting || _restoring) ? null : _onTapRestore,
        ),
      ],
    );
  }
}
