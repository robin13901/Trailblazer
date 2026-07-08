import 'package:auto_explore/features/settings/presentation/widgets/about_section.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Placeholder for the Settings screen — wired fully in Phase 10.
///
/// This is a top-level route (`/settings`), NOT inside the shell.
/// Reachable from the top-left settings glass button on the map screen.
///
/// Currently hosts the "About" section (map data credits / attribution).
/// The native MapLibre attribution button is pushed off-screen; MapTiler +
/// OSM license terms are satisfied by exposing attribution here in a
/// user-reachable "common area".
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: const [
          _SectionHeader('About'),
          AboutSection(),
          Divider(height: 1),
          _SectionHeader('Coming later'),
          ListTile(
            title: Text('Full settings arrive in Phase 10'),
            subtitle: Text(
              'Backup / restore, permissions inspector, OSM extract updates, '
              'raw-GPS retention, diagnostics.',
            ),
          ),
          // Dev-only entry point (Plan 03-1-01). Compiled out of release
          // builds — `kDebugMode` is a const, so tree-shaking removes both
          // the tile and the route target.
          if (kDebugMode) ...[
            Divider(height: 1),
            _SectionHeader('Developer'),
            _DiagnosticsTile(),
          ],
        ],
      ),
    );
  }
}

class _DiagnosticsTile extends StatelessWidget {
  const _DiagnosticsTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('Tracking diagnostics'),
      subtitle: const Text('Live FGB state, fix counters, permissions'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/settings/diagnostics'),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
