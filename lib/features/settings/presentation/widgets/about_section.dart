import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// App version string — keep in sync with `version:` in pubspec.yaml.
const kAppVersion = '0.1.0';

/// About section for the Settings screen.
///
/// Extracted from the inline `_AboutTile` in `settings_screen.dart` so 04-11
/// could add the MapTiler attribution row without duplicating structure.
///
/// **Free-tier attribution contract:**
/// - MapTiler free tier requires a visible `© MapTiler` credit that links to
///   https://www.maptiler.com/copyright/.
/// - OSM ODbL requires a visible `© OpenStreetMap contributors` credit that
///   links to https://www.openstreetmap.org/copyright.
///
/// The native MapLibre attribution button is pushed off-screen in the map
/// widget; Settings > About is the only reachable surface for these credits,
/// so both links MUST stay clickable + screen-reader focusable.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

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
          const SizedBox(height: 8),
          // ── App version ──────────────────────────────────────────────────
          Text(
            'Version $kAppVersion',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          // ── OSS licenses ─────────────────────────────────────────────────
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Open-source licenses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Trailblazer',
              applicationVersion: kAppVersion,
            ),
          ),
          const SizedBox(height: 8),
          Text('Map data credits', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          // MapTiler free-tier attribution — required by TOS.
          Semantics(
            label: 'MapTiler copyright link',
            link: true,
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '© '),
                  TextSpan(
                    text: 'MapTiler',
                    style: link,
                    recognizer: TapGestureRecognizer()
                      ..onTap = () =>
                          _open('https://www.maptiler.com/copyright/'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // OpenStreetMap ODbL attribution — required by ODbL.
          Semantics(
            label: 'OpenStreetMap copyright link',
            link: true,
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '© '),
                  TextSpan(
                    text: 'OpenStreetMap',
                    style: link,
                    recognizer: TapGestureRecognizer()
                      ..onTap = () =>
                          _open('https://www.openstreetmap.org/copyright'),
                  ),
                  const TextSpan(text: ' contributors'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('Rendered with', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
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
