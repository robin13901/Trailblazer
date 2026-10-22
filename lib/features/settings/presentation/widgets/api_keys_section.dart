import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings section for user-supplied API keys.
///
/// Currently exposes a single entry: the NextGIS Overpass API key.
/// The key is stored on-device (SharedPreferences) and never committed to
/// source control.  When present, the Overpass pool appends a NextGIS
/// endpoint (8 extra slots, key-based — no IP throttling).
class ApiKeysSection extends ConsumerWidget {
  const ApiKeysSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentKey = ref.watch(nextgisApiKeyProvider);
    final hasKey = currentKey.isNotEmpty;

    return ListTile(
      title: const Text('NextGIS Overpass API-Key'),
      subtitle: Text(
        hasKey ? _maskKey(currentKey) : 'Nicht konfiguriert',
        style: TextStyle(
          color: hasKey
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showKeyDialog(context, ref, currentKey),
    );
  }

  /// Shows at most the first and last four characters of the key separated by
  /// "••••" so the user can recognise their own key without exposing it fully.
  String _maskKey(String key) {
    if (key.length <= 8) return '••••••••';
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  Future<void> _showKeyDialog(
    BuildContext context,
    WidgetRef ref,
    String currentKey,
  ) async {
    final controller = TextEditingController(text: currentKey);
    final result = await showDialog<_KeyDialogResult>(
      context: context,
      builder: (dialogContext) => _NextGisKeyDialog(controller: controller),
    );
    controller.dispose();

    if (result == null) return;

    final prefs = ref.read(appPrefsProvider);
    final String newKey;
    if (result == _KeyDialogResult.clear) {
      await prefs.clearNextGisApiKey();
      newKey = '';
    } else {
      newKey = controller.text.trim();
      await prefs.setNextGisApiKey(newKey);
    }
    ref.read(nextgisApiKeyProvider.notifier).currentKey = newKey;
  }
}

enum _KeyDialogResult { save, clear }

class _NextGisKeyDialog extends StatelessWidget {
  const _NextGisKeyDialog({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('NextGIS Overpass API-Key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Kostenlosen Key unter my.nextgis.com erstellen '
            '(→ Software & Services).',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'API-Key',
              hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
            enableSuggestions: false,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_KeyDialogResult.clear),
          child: const Text('Entfernen'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_KeyDialogResult.save),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
