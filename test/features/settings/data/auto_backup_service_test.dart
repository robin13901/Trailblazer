// Unit tests for AutoBackupService — due-calculation matrix + orchestration.
//
// Pure Dart: FakeBackupService + FakeCloudBackupFolder + a real AppPrefs over
// InMemorySharedPreferencesAsync, and an injected clock. No platform channels.

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/features/settings/data/auto_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../fakes/fake_backup_service.dart';
import '../fakes/fake_cloud_backup_folder.dart';

void main() {
  late FakeBackupService backup;
  late FakeCloudBackupFolder folder;
  late AppPrefs prefs;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    backup = FakeBackupService();
    folder = FakeCloudBackupFolder();
    prefs = AppPrefs(SharedPreferencesAsync());
  });

  AutoBackupService service({DateTime Function()? now}) =>
      AutoBackupService(backup, folder, prefs, now: now);

  // A fixed "now" so the due arithmetic is deterministic.
  final now = DateTime.utc(2026, 11, 25, 12);

  group('isDue', () {
    test('false when the feature is disabled', () async {
      await prefs.setAutoBackupEnabled(enabled: false);
      expect(await service().isDue(now), isFalse);
    });

    test('false when enabled but no folder is available', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      folder.hasFolderResult = false;
      expect(await service().isDue(now), isFalse);
    });

    test('true on first run after enabling (no timestamp yet)', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      expect(await service().isDue(now), isTrue);
    });

    test('false when less than the interval has elapsed', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      // 6 days ago — under the 7-day default.
      await prefs.setLastAutoBackupAt(now.subtract(const Duration(days: 6)));
      expect(await service().isDue(now), isFalse);
    });

    test('true when exactly the interval has elapsed', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      await prefs.setLastAutoBackupAt(now.subtract(const Duration(days: 7)));
      expect(await service().isDue(now), isTrue);
    });

    test('true when more than the interval has elapsed', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      await prefs.setLastAutoBackupAt(now.subtract(const Duration(days: 10)));
      expect(await service().isDue(now), isTrue);
    });

    test('honours a custom interval stored in prefs (14 days)', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      await prefs.setAutoBackupIntervalDays(14);
      await prefs.setLastAutoBackupAt(now.subtract(const Duration(days: 10)));
      // 10 days < 14-day interval → not due.
      expect(await service().isDue(now), isFalse);
      await prefs.setLastAutoBackupAt(now.subtract(const Duration(days: 14)));
      expect(await service().isDue(now), isTrue);
    });
  });

  group('runIfDue', () {
    test('no-op Ok when not due, without creating or writing', () async {
      await prefs.setAutoBackupEnabled(enabled: false);
      final result = await service(now: () => now).runIfDue();
      expect(result, isA<Ok<void>>());
      expect(folder.writtenFiles, isEmpty);
      expect(await prefs.getLastAutoBackupAt(), isNull);
    });

    test('creates a backup and writes a date-stamped file when due', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      final result = await service(now: () => now).runIfDue();
      expect(result, isA<Ok<void>>());
      expect(folder.writtenFiles, hasLength(1));
      expect(
        folder.writtenFiles.single.localFilePath,
        '/fake/backup.trailblazer',
      );
      expect(
        folder.writtenFiles.single.destFileName,
        'trailblazer-backup-2026-11-25.trailblazer',
      );
    });

    test('stamps the timestamp on a successful write', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      await service(now: () => now).runIfDue();
      expect((await prefs.getLastAutoBackupAt())!.toUtc(), now);
    });

    test('does NOT stamp when createBackup fails (retries later)', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      backup.createShouldFail = true;
      final result = await service(now: () => now).runIfDue();
      expect(result, isA<Err<void>>());
      expect(folder.writtenFiles, isEmpty);
      expect(await prefs.getLastAutoBackupAt(), isNull);
    });

    test('does NOT stamp when the folder write fails (retries later)', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      folder.writeResult = const Err(
        StorageError('Ordnerzugriff verloren – bitte erneut wählen.'),
      );
      final result = await service(now: () => now).runIfDue();
      expect(result, isA<Err<void>>());
      expect(await prefs.getLastAutoBackupAt(), isNull);
    });
  });

  group('runNow', () {
    test('backs up even when not due (bypasses the interval)', () async {
      await prefs.setAutoBackupEnabled(enabled: true);
      // Backed up just now — runIfDue would be a no-op, but runNow forces it.
      await prefs.setLastAutoBackupAt(now.subtract(const Duration(days: 1)));
      final result = await service(now: () => now).runNow();
      expect(result, isA<Ok<void>>());
      expect(folder.writtenFiles, hasLength(1));
      expect((await prefs.getLastAutoBackupAt())!.toUtc(), now);
    });
  });
}
