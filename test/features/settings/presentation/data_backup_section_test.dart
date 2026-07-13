// Trailblazer Phase 9, Plan 09-05: Widget tests for DataBackupSection.

import 'package:auto_explore/features/settings/data/backup_service_provider.dart';
import 'package:auto_explore/features/settings/data/file_platform_provider.dart';
import 'package:auto_explore/features/settings/presentation/widgets/data_backup_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_backup_service.dart';
import '../fakes/fake_file_platform.dart';

void main() {
  group('DataBackupSection', () {
    /// Utility: pump the widget under test inside a ProviderScope + MaterialApp
    /// with a Scaffold (required for SnackBar and Dialog).
    Future<void> pumpSection(
      WidgetTester tester, {
      required FakeBackupService fakeBackup,
      required FakeFilePlatform fakeFile,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backupServiceProvider.overrideWithValue(fakeBackup),
            filePlatformProvider.overrideWithValue(fakeFile),
          ],
          child: const MaterialApp(
            home: Scaffold(body: DataBackupSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // ── Test 1: Export happy path ──────────────────────────────────────────────

    testWidgets('export happy path: createBackup result shared via shareFile',
        (tester) async {
      final fakeBackup = FakeBackupService();
      final fakeFile = FakeFilePlatform();

      await pumpSection(tester, fakeBackup: fakeBackup, fakeFile: fakeFile);

      await tester.tap(find.text('Back up my data'));
      await tester.pumpAndSettle();

      // createBackup was called and set lastExportedPath.
      expect(fakeBackup.lastExportedPath, isNotNull);

      // shareFile was called with the returned path.
      expect(fakeFile.sharedPaths, contains(fakeBackup.lastExportedPath));

      // Success SnackBar is visible.
      expect(find.text('Backup ready to share'), findsOneWidget);
    });

    // ── Test 2: Restore confirm path ──────────────────────────────────────────

    testWidgets(
        'restore confirm path: pick → confirm → restore called + SnackBar',
        (tester) async {
      final fakeBackup = FakeBackupService();
      final fakeFile = FakeFilePlatform()
        ..pickResult = '/fake/backup.trailblazer';

      await pumpSection(tester, fakeBackup: fakeBackup, fakeFile: fakeFile);

      // Tap restore tile.
      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();

      // The destructive confirm dialog must be visible.
      expect(find.text('Replace all data?'), findsOneWidget);

      // Tap the "Replace" button.
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();

      // restore() was called with the picked path.
      expect(fakeBackup.restoredPaths, contains('/fake/backup.trailblazer'));

      // Success SnackBar is visible.
      expect(find.text('Backup restored'), findsOneWidget);
    });

    // ── Test 3: Restore cancel ─────────────────────────────────────────────────

    testWidgets('restore cancel: dialog shown but restore NOT called',
        (tester) async {
      final fakeBackup = FakeBackupService();
      final fakeFile = FakeFilePlatform()
        ..pickResult = '/fake/backup.trailblazer';

      await pumpSection(tester, fakeBackup: fakeBackup, fakeFile: fakeFile);

      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();

      // Confirm dialog is visible.
      expect(find.text('Replace all data?'), findsOneWidget);

      // Tap Cancel.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // restore() must NOT have been called.
      expect(fakeBackup.restoredPaths, isEmpty);
    });

    // ── Test 4: Restore failure ────────────────────────────────────────────────

    testWidgets(
        'restore failure: error SnackBar shown, app stays usable (no crash)',
        (tester) async {
      final fakeBackup = FakeBackupService()..restoreShouldFail = true;
      final fakeFile = FakeFilePlatform()
        ..pickResult = '/fake/backup.trailblazer';

      await pumpSection(tester, fakeBackup: fakeBackup, fakeFile: fakeFile);

      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();

      // Confirm dialog.
      expect(find.text('Replace all data?'), findsOneWidget);
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();

      // Failure SnackBar is shown.
      expect(
        find.textContaining('Restore failed'),
        findsOneWidget,
      );

      // The tiles are still present — app did not crash or navigate away.
      expect(find.text('Restore from backup'), findsOneWidget);
    });

    // ── Test 5: Pick cancelled ─────────────────────────────────────────────────

    testWidgets('pick cancelled: no dialog, restore not called', (tester) async {
      final fakeBackup = FakeBackupService();
      final fakeFile = FakeFilePlatform()..pickResult = null; // cancel

      await pumpSection(tester, fakeBackup: fakeBackup, fakeFile: fakeFile);

      await tester.tap(find.text('Restore from backup'));
      await tester.pumpAndSettle();

      // The confirm dialog must NOT appear.
      expect(find.text('Replace all data?'), findsNothing);

      // restore() must NOT have been called.
      expect(fakeBackup.restoredPaths, isEmpty);
    });
  });
}
