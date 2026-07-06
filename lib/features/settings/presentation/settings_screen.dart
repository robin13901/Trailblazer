import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

/// Placeholder for the Settings screen — wired fully in Phase 10.
///
/// This is a top-level route (`/settings`), NOT inside the shell.
/// Reachable from the top-left settings glass button on the map screen.
///
/// Currently hosts the "About" section (map data credits / attribution).
/// The native MapLibre attribution button is pushed off-screen; OSM's
/// license terms are satisfied by exposing attribution here in a
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
          _AboutTile(),
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

class _AboutTile extends StatelessWidget {
  const _AboutTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Trailblazer paints the roads you have driven onto an offline '
            'map of the world.',
          ),
          const SizedBox(height: 16),
          Text('Map data credits', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Base map tiles © '),
                TextSpan(
                  text: 'Protomaps',
                  style: link,
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => _open('https://protomaps.com'),
                ),
                const TextSpan(text: '. Map data © '),
                TextSpan(
                  text: 'OpenStreetMap',
                  style: link,
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => _open('https://openstreetmap.org/copyright'),
                ),
                const TextSpan(text: ' contributors, ODbL. Rendered with '),
                TextSpan(
                  text: 'MapLibre',
                  style: link,
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => _open('https://maplibre.org'),
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
