import 'dart:async';

import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/settings/data/auto_backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/cloud_backup_folder_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings > Data & Backup > Automatic backup section.
///
/// Lets the user enable a weekly automatic backup into a folder they pick once
/// (intended to be a OneDrive-synced folder). Follows Pattern A (stateful,
/// load in `initState`, write in handlers) like the diagnostics-HUD toggle and
/// the `RawGpsRetentionSection`.
class AutoBackupSection extends ConsumerStatefulWidget {
  const AutoBackupSection({super.key});

  @override
  ConsumerState<AutoBackupSection> createState() => _AutoBackupSectionState();
}

class _AutoBackupSectionState extends ConsumerState<AutoBackupSection> {
  bool _loaded = false;
  bool _enabled = false;
  String? _folderName;
  DateTime? _lastBackup;
  bool _backingUp = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
  }

  Future<void> _loadInitial() async {
    final prefs = ref.read(appPrefsProvider);
    final enabled = await prefs.getAutoBackupEnabled();
    final hasFolder = await ref.read(cloudBackupFolderProvider).hasFolder();
    final folderName = hasFolder
        ? (await prefs.getCloudBackupFolderName())
        : null;
    final last = await prefs.getLastAutoBackupAt();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _folderName = folderName;
      _lastBackup = last?.toLocal();
      _loaded = true;
    });
  }

  // ── Enable toggle ──────────────────────────────────────────────────────────

  Future<void> _onToggle({required bool enable}) async {
    final messenger = ScaffoldMessenger.of(context);
    final prefs = ref.read(appPrefsProvider);

    if (!enable) {
      setState(() => _enabled = false);
      await prefs.setAutoBackupEnabled(enabled: false);
      return;
    }

    // Enabling: a folder is required. If none is set, prompt to pick one; if
    // the user cancels, leave the toggle off (a silently-useless enabled state
    // is worse than an explicit "pick a folder" nudge).
    setState(() => _enabled = true);
    await prefs.setAutoBackupEnabled(enabled: true);

    if (_folderName == null) {
      final picked = await _pickFolder();
      if (!picked) {
        if (!mounted) return;
        setState(() => _enabled = false);
        await prefs.setAutoBackupEnabled(enabled: false);
        messenger.showSnackBar(
          const SnackBar(content: Text('Bitte einen Ordner wählen')),
        );
      }
    }
  }

  // ── Folder picker ────────────────────────────────────────────────────────────

  /// Opens the native folder picker, persists the display name, and refreshes
  /// the UI. Returns true when a folder was chosen.
  Future<bool> _pickFolder() async {
    final folder = ref.read(cloudBackupFolderProvider);
    final prefs = ref.read(appPrefsProvider);

    final picked = await folder.pickFolder();
    if (!picked) return false;

    final name = await folder.folderDisplayName();
    if (name != null && name.isNotEmpty) {
      await prefs.setCloudBackupFolderName(name);
    }
    if (!mounted) return true;
    setState(() => _folderName = name);
    return true;
  }

  // ── Manual "back up now" ──────────────────────────────────────────────────────

  Future<void> _onTapBackupNow() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _backingUp = true);
    final Result<void> result;
    try {
      result = await ref.read(autoBackupServiceProvider).runNow();
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
    if (!mounted) return;

    switch (result) {
      case Ok():
        final last = await ref.read(appPrefsProvider).getLastAutoBackupAt();
        if (!mounted) return;
        setState(() => _lastBackup = last?.toLocal());
        messenger.showSnackBar(
          const SnackBar(content: Text('Backup gespeichert')),
        );
      case Err(:final error):
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  String _lastBackupSubtitle() {
    final last = _lastBackup;
    if (last == null) return 'Zuletzt gesichert: noch nie';
    final d = last.day.toString().padLeft(2, '0');
    final mo = last.month.toString().padLeft(2, '0');
    final y = last.year.toString().padLeft(4, '0');
    return 'Zuletzt gesichert: $d.$mo.$y';
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const ListTile(title: Text('Wird geladen …'));
    }

    final hasFolder = _folderName != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          title: const Text('Automatisches Backup'),
          subtitle: const Text(
            'Sichert deine Daten wöchentlich in einen gewählten Ordner',
          ),
          value: _enabled,
          onChanged: (v) => _onToggle(enable: v),
        ),

        // Chosen folder + pick action — shown once the feature is enabled.
        if (_enabled) ...[
          ListTile(
            title: const Text('Backup-Ordner'),
            subtitle: Text(_folderName ?? 'Kein Ordner gewählt'),
            trailing: TextButton(
              onPressed: () => unawaited(_pickFolder()),
              child: const Text('Ordner wählen'),
            ),
          ),
          ListTile(
            title: const Text('Jetzt sichern'),
            subtitle: Text(_lastBackupSubtitle()),
            trailing: _backingUp
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            onTap: (_backingUp || !hasFolder) ? null : _onTapBackupNow,
          ),
        ],
      ],
    );
  }
}
