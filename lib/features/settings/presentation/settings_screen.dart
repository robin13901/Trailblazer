import 'dart:async';

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/settings/presentation/widgets/about_section.dart';
import 'package:auto_explore/features/settings/presentation/widgets/coverage_color_section.dart';
import 'package:auto_explore/features/settings/presentation/widgets/data_backup_section.dart';
import 'package:auto_explore/features/settings/presentation/widgets/permissions_section.dart';
import 'package:auto_explore/features/settings/presentation/widgets/raw_gps_retention_section.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Grouped Settings screen assembling all Phase 9 sections.
///
/// Section order (CONTEXT-locked):
///   1. Data & Backup  — DataBackupSection + DataManagementSection + RawGpsRetentionSection
///   2. Coverage       — CoverageColorSection
///   3. Permissions    — PermissionsSection
///   4. Diagnostics    — HUD toggle + optional "Tracking diagnostics" tile
///   5. About          — AboutSection
///   6. Developer      — debug-only StressCoverageTile
///
/// This is a top-level route (`/settings`), NOT inside the shell.
/// Reachable from the top-left settings glass button on the map screen.
///
/// The native MapLibre attribution button is pushed off-screen; MapTiler +
/// OSM license terms are satisfied by exposing attribution here in a
/// user-reachable "common area".
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _showHud = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHudPref());
  }

  Future<void> _loadHudPref() async {
    final val = await ref.read(appPrefsProvider).getShowDiagnosticsHud();
    if (!mounted) return;
    setState(() => _showHud = val);
  }

  Future<void> _setHudPref({required bool show}) async {
    setState(() => _showHud = show);
    await ref.read(appPrefsProvider).setShowDiagnosticsHud(show: show);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        children: [
          // ── Data & Backup ───────────────────────────────────────────────
          const _SectionHeader('Daten & Backup'),
          const DataBackupSection(),
          const Divider(height: 1),
          const RawGpsRetentionSection(),

          // ── Coverage ────────────────────────────────────────────────────
          const Divider(height: 1),
          const _SectionHeader('Abdeckung'),
          const CoverageColorSection(),

          // ── Permissions ─────────────────────────────────────────────────
          const Divider(height: 1),
          const _SectionHeader('Berechtigungen'),
          const PermissionsSection(),

          // ── Diagnostics ──────────────────────────────────────────────────
          const Divider(height: 1),
          const _SectionHeader('Diagnose'),
          SwitchListTile(
            title: const Text('Diagnose-HUD anzeigen'),
            subtitle: const Text('Live-FGB-Status als Overlay auf der Karte'),
            value: _showHud,
            onChanged: (v) => _setHudPref(show: v),
          ),
          if (_showHud)
            const _DiagnosticsTile(),

          // ── About ────────────────────────────────────────────────────────
          const Divider(height: 1),
          const _SectionHeader('Über'),
          const AboutSection(),

          // ── Developer (debug-only) ────────────────────────────────────────
          if (kDebugMode) ...[
            const Divider(height: 1),
            const _SectionHeader('Entwickler'),
            const _StressCoverageTile(),
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
      title: const Text('Tracking-Diagnose'),
      subtitle: const Text('Live-FGB-Status, Fix-Zähler, Berechtigungen'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/settings/diagnostics'),
    );
  }
}

/// REN-04 stress harness entry (Plan 07-07).
/// Compiled out of release builds — only present in debug.
class _StressCoverageTile extends StatelessWidget {
  const _StressCoverageTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('Abdeckung-Stresstest'),
      subtitle: const Text('50k Segmente · fps-Anzeige'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/settings/stress-coverage'),
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
