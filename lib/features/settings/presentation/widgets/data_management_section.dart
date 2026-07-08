import 'dart:async';

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Settings > Data section.
///
/// Currently hosts the manual "Refresh admin regions" button — the ONLY
/// user-facing runtime OSM operation in Phase 4 besides trip-time
/// Overpass fetches (per plan §Task 3 intent).
class DataManagementSection extends ConsumerStatefulWidget {
  const DataManagementSection({super.key});

  @override
  ConsumerState<DataManagementSection> createState() =>
      _DataManagementSectionState();
}

class _DataManagementSectionState
    extends ConsumerState<DataManagementSection> {
  bool _refreshing = false;
  String? _cachedVersion;
  bool _versionLoaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    final version =
        await ref.read(appPrefsProvider).getAdminBundleVersion();
    if (!mounted) return;
    setState(() {
      _cachedVersion = version;
      _versionLoaded = true;
    });
  }

  Future<void> _onTapRefresh() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Refresh admin regions?'),
        content: const Text(
          'This will download ~10 MB of data and may take 1-2 minutes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Refresh'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;

    setState(() => _refreshing = true);
    try {
      await ref.read(adminBundleRefresherProvider).refreshFromOverpass();
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Admin regions updated')),
      );
      await _loadVersion();
    } on Object catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Refresh failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = !_versionLoaded
        ? 'Loading…'
        : _cachedVersion == null
            ? 'Using bundled version'
            : 'Last refreshed: $_cachedVersion';
    return ListTile(
      title: const Text('Refresh admin regions'),
      subtitle: Text(subtitle),
      trailing: _refreshing
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      onTap: _refreshing ? null : _onTapRefresh,
    );
  }
}
