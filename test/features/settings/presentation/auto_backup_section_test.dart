// Widget tests for AutoBackupSection.
//
// Injects FakeCloudBackupFolder + a real AppPrefs over
// InMemorySharedPreferencesAsync via ProviderScope.overrides, mirroring the
// DataBackupSection tests (Plan 09-05).

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/settings/data/backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/cloud_backup_folder_provider.dart';
import 'package:auto_explore/features/settings/presentation/widgets/auto_backup_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../fakes/fake_backup_service.dart';
import '../fakes/fake_cloud_backup_folder.dart';

void main() {
  group('AutoBackupSection', () {
    late FakeBackupService fakeBackup;
    late FakeCloudBackupFolder fakeFolder;

    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      fakeBackup = FakeBackupService();
      fakeFolder = FakeCloudBackupFolder();
    });

    Future<void> pumpSection(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backupServiceProvider.overrideWithValue(fakeBackup),
            cloudBackupFolderProvider.overrideWithValue(fakeFolder),
          ],
          child: const MaterialApp(
            home: Scaffold(body: AutoBackupSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('toggle off by default; the folder tiles are hidden', (
      tester,
    ) async {
      // No folder yet in this scenario.
      fakeFolder.hasFolderResult = false;
      await pumpSection(tester);

      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.value, isFalse);
      expect(find.text('Backup-Ordner'), findsNothing);
      expect(find.text('Jetzt sichern'), findsNothing);
    });

    testWidgets('enabling with no folder prompts the picker and reveals tiles', (
      tester,
    ) async {
      fakeFolder
        ..hasFolderResult = false
        ..displayName = 'OneDrive › Backups';
      await pumpSection(tester);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      // pickFolder was invoked exactly once, and the chosen name is shown.
      expect(fakeFolder.pickFolderCalls, 1);
      expect(find.text('OneDrive › Backups'), findsOneWidget);
      expect(find.text('Jetzt sichern'), findsOneWidget);
    });

    testWidgets('enabling then cancelling the picker reverts the toggle', (
      tester,
    ) async {
      fakeFolder
        ..hasFolderResult = false
        ..pickSucceeds = false; // user cancels the picker
      await pumpSection(tester);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.value, isFalse);
      expect(find.text('Bitte einen Ordner wählen'), findsOneWidget);
    });

    testWidgets('"Jetzt sichern" happy path shows the success SnackBar', (
      tester,
    ) async {
      // Pre-enable with an existing folder so the tiles render immediately.
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setAutoBackupEnabled(enabled: true);
      await prefs.setCloudBackupFolderName('OneDrive › Backups');
      await pumpSection(tester);

      await tester.tap(find.text('Jetzt sichern'));
      await tester.pumpAndSettle();

      expect(fakeFolder.writtenFiles, hasLength(1));
      expect(find.text('Backup gespeichert'), findsOneWidget);
    });

    testWidgets('"Jetzt sichern" failure shows the error message', (
      tester,
    ) async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setAutoBackupEnabled(enabled: true);
      await prefs.setCloudBackupFolderName('OneDrive › Backups');
      fakeFolder.writeResult = const Err(
        StorageError('Ordnerzugriff verloren – bitte erneut wählen.'),
      );
      await pumpSection(tester);

      await tester.tap(find.text('Jetzt sichern'));
      await tester.pumpAndSettle();

      expect(
        find.text('Ordnerzugriff verloren – bitte erneut wählen.'),
        findsOneWidget,
      );
    });

    testWidgets('shows "noch nie" when no backup has run yet', (tester) async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setAutoBackupEnabled(enabled: true);
      await prefs.setCloudBackupFolderName('OneDrive › Backups');
      await pumpSection(tester);

      expect(find.text('Zuletzt gesichert: noch nie'), findsOneWidget);
    });
  });
}
