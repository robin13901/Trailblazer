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
          await ref
              .read(filePlatformProvider)
              .shareFile(
                value,
                subject: 'Trailblazer Backup',
              );
          if (!mounted) return;
          messenger.showSnackBar(
            const SnackBar(content: Text('Backup bereit zum Teilen')),
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
        title: const Text('Alle Daten ersetzen?'),
        content: const Text(
          'Beim nächsten Start der App werden alle aktuellen Fahrten, '
          'Abdeckungs- und Einstellungsdaten DAUERHAFT durch den Inhalt '
          'dieses Backups ersetzt. Dies kann nicht rückgängig gemacht werden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Ersetzen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    // Step 3 — show restoring progress state while the file is staged.
    setState(() => _restoring = true);
    final Result<void> result;
    try {
      // Step 4 — stage the restore (validated + copied; live DB untouched).
      result = await ref.read(backupServiceProvider).restore(path);
    } finally {
      // Clear the spinner BEFORE any follow-up dialog — an active
      // CircularProgressIndicator never lets the frame settle.
      if (mounted) setState(() => _restoring = false);
    }
    if (!mounted) return;

    switch (result) {
      case Ok():
        // The swap happens on the next launch (restore_staging.dart). iOS
        // offers no clean programmatic restart, so we instruct the user to
        // relaunch manually.
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Backup vorgemerkt'),
            content: const Text(
              'Das Backup wird beim nächsten Start der App eingespielt.\n\n'
              'Schließe die App jetzt vollständig (über den App-Umschalter) '
              'und öffne sie erneut.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Verstanden'),
              ),
            ],
          ),
        );
      case Err(:final error):
        // Validation or staging failed — live DB is intact (nothing was
        // touched; the swap only runs at launch on a valid staged file).
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Wiederherstellung fehlgeschlagen: ${error.message}',
            ),
          ),
        );
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
          title: const Text('Meine Daten sichern'),
          subtitle: const Text(
            'Erstellt eine teilbare Kopie all deiner Fahrten & Abdeckung',
          ),
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
          title: const Text('Aus Backup wiederherstellen'),
          subtitle: const Text(
            'Ersetzt ALLE aktuellen Daten durch eine Backup-Datei',
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
