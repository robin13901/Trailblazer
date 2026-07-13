// Trailblazer Phase 9, Plan 09-07:
// Integration widget test for the assembled SettingsScreen.
//
// Verifies that all Phase 9 sections are wired together in a single screen:
//   - Section headers: Data & Backup, Coverage, Permissions, Diagnostics, About
//   - The "Full settings arrive in Phase 10" placeholder is GONE
//   - DataBackupSection tiles are present (09-05)
//   - About shows 'Open-source licenses' (SET-09)
//   - Diagnostics HUD SwitchListTile is present
//
// Strategy: InMemorySharedPreferencesAsync for appPrefsProvider (covers
// RawGpsRetentionSection, DataManagementSection, CoverageColorSection,
// and the HUD toggle). Platform-channel services are overridden with fakes.

import 'package:auto_explore/features/admin/data/admin_bundle_refresher.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/onboarding/data/permission_service_provider.dart';
import 'package:auto_explore/features/settings/data/backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/file_platform_provider.dart';
import 'package:auto_explore/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../onboarding/fakes/fake_permission_service.dart';
import '../fakes/fake_backup_service.dart';
import '../fakes/fake_file_platform.dart';

/// Minimal [AdminBundleRefresher] fake — never hits Overpass.
class _FakeAdminBundleRefresher implements AdminBundleRefresher {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;

  @override
  Future<void> refreshFromOverpass() async {}
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    // Tall surface so all sections mount eagerly (not lazy-off-viewport).
    await tester.binding.setSurfaceSize(const Size(800, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(const Size(800, 600)));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backupServiceProvider.overrideWithValue(FakeBackupService()),
          filePlatformProvider.overrideWithValue(FakeFilePlatform()),
          permissionServiceProvider.overrideWithValue(FakePermissionService()),
          adminBundleRefresherProvider
              .overrideWithValue(_FakeAdminBundleRefresher()),
        ],
        child: const MaterialApp(
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('SettingsScreen', () {
    // ── Section headers ───────────────────────────────────────────────────────

    testWidgets('renders Data & Backup section header', (tester) async {
      await pumpScreen(tester);
      // _SectionHeader uppercases the title text.
      expect(find.text('DATEN & BACKUP'), findsOneWidget);
    });

    testWidgets('renders Coverage section header', (tester) async {
      await pumpScreen(tester);
      expect(find.text('ABDECKUNG'), findsOneWidget);
    });

    testWidgets('renders Permissions section header', (tester) async {
      await pumpScreen(tester);
      expect(find.text('BERECHTIGUNGEN'), findsOneWidget);
    });

    testWidgets('renders Diagnostics section header', (tester) async {
      await pumpScreen(tester);
      expect(find.text('DIAGNOSE'), findsOneWidget);
    });

    testWidgets('renders About section header', (tester) async {
      await pumpScreen(tester);
      expect(find.text('ÜBER'), findsOneWidget);
    });

    // ── Placeholder removed ───────────────────────────────────────────────────

    testWidgets('placeholder tile is absent', (tester) async {
      await pumpScreen(tester);
      expect(
        find.text('Full settings arrive in Phase 10'),
        findsNothing,
      );
    });

    // ── DataBackupSection tiles (09-05) ───────────────────────────────────────

    testWidgets('Back up my data tile is present', (tester) async {
      await pumpScreen(tester);
      expect(find.text('Meine Daten sichern'), findsOneWidget);
    });

    testWidgets('Restore from backup tile is present', (tester) async {
      await pumpScreen(tester);
      expect(find.text('Aus Backup wiederherstellen'), findsOneWidget);
    });

    // ── About section (SET-09) ─────────────────────────────────────────────────

    testWidgets('Open-source licenses entry is present', (tester) async {
      await pumpScreen(tester);
      expect(find.text('Open-Source-Lizenzen'), findsOneWidget);
    });

    // ── Diagnostics HUD toggle ─────────────────────────────────────────────────

    testWidgets('Diagnostics HUD SwitchListTile is present', (tester) async {
      await pumpScreen(tester);
      expect(find.text('Diagnose-HUD anzeigen'), findsOneWidget);
      // The toggle itself — find the Switch widget.
      expect(find.byType(Switch), findsOneWidget);
    });

    testWidgets(
        'Tracking diagnostics tile is hidden when HUD toggle is OFF',
        (tester) async {
      await pumpScreen(tester);
      // Default state: HUD toggle OFF → diagnostics tile hidden.
      expect(find.text('Tracking-Diagnose'), findsNothing);
    });

    testWidgets(
        'Tracking diagnostics tile appears when HUD toggle is turned ON',
        (tester) async {
      await pumpScreen(tester);
      // Toggle the switch ON.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Tracking-Diagnose'), findsOneWidget);
    });
  });
}
