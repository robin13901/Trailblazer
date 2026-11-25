// Tests for AppPrefs — raw-GPS retention and diagnostics-HUD toggle (Plan 09-03).
//
// Uses InMemorySharedPreferencesAsync so no platform channel is required.
// Pattern from STATE Plan 01-03 (OnboardingFlagRepository tests).

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('AppPrefs — getRawGpsRetentionDays', () {
    test('returns 30 (default) when key has never been written', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      expect(await prefs.getRawGpsRetentionDays(), 30);
    });

    test('set 0 round-trips to 0 (delete after matching)', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setRawGpsRetentionDays(0);
      expect(await prefs.getRawGpsRetentionDays(), 0);
    });

    test('set 30 round-trips to 30', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setRawGpsRetentionDays(30);
      expect(await prefs.getRawGpsRetentionDays(), 30);
    });

    test('set 365 round-trips to 365', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setRawGpsRetentionDays(365);
      expect(await prefs.getRawGpsRetentionDays(), 365);
    });

    test('set null round-trips to null (forever, via -1 sentinel)', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setRawGpsRetentionDays(null);
      expect(await prefs.getRawGpsRetentionDays(), isNull);
    });

    test('forever sentinel (-1) is stored, not null/absent', () async {
      // The key must be present with value -1 after setting null, so that
      // getRawGpsRetentionDays returns null (forever) — not the default 30.
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setRawGpsRetentionDays(null);
      final raw = await SharedPreferencesAsync().getInt(
        AppPrefs.kRawGpsRetentionDays,
      );
      expect(raw, -1);
    });
  });

  group('AppPrefs — getShowDiagnosticsHud', () {
    test('returns false (default) when key has never been written', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      expect(await prefs.getShowDiagnosticsHud(), isFalse);
    });

    test('set true round-trips to true', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setShowDiagnosticsHud(show: true);
      expect(await prefs.getShowDiagnosticsHud(), isTrue);
    });

    test('set false round-trips to false', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setShowDiagnosticsHud(show: true);
      await prefs.setShowDiagnosticsHud(show: false);
      expect(await prefs.getShowDiagnosticsHud(), isFalse);
    });
  });

  group('AppPrefs — getAutoBackupEnabled', () {
    test('returns false (default) when key has never been written', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      expect(await prefs.getAutoBackupEnabled(), isFalse);
    });

    test('set true round-trips to true', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setAutoBackupEnabled(enabled: true);
      expect(await prefs.getAutoBackupEnabled(), isTrue);
    });

    test('set false round-trips to false', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setAutoBackupEnabled(enabled: true);
      await prefs.setAutoBackupEnabled(enabled: false);
      expect(await prefs.getAutoBackupEnabled(), isFalse);
    });
  });

  group('AppPrefs — getLastAutoBackupAt', () {
    test('returns null when key has never been written', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      expect(await prefs.getLastAutoBackupAt(), isNull);
    });

    test('round-trips a timestamp to second precision in UTC', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      final when = DateTime.utc(2026, 11, 25, 14, 30, 15);
      await prefs.setLastAutoBackupAt(when);
      final read = await prefs.getLastAutoBackupAt();
      expect(read, isNotNull);
      expect(read!.toUtc(), when);
    });

    test('stores a local time as its UTC equivalent', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      final local = DateTime(2026, 11, 25, 14, 30);
      await prefs.setLastAutoBackupAt(local);
      final read = await prefs.getLastAutoBackupAt();
      expect(read!.toUtc(), local.toUtc());
    });
  });

  group('AppPrefs — getAutoBackupIntervalDays', () {
    test('returns 7 (default) when key has never been written', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      expect(await prefs.getAutoBackupIntervalDays(), 7);
    });

    test('set 14 round-trips to 14', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setAutoBackupIntervalDays(14);
      expect(await prefs.getAutoBackupIntervalDays(), 14);
    });
  });

  group('AppPrefs — getCloudBackupFolderName', () {
    test('returns null when key has never been written', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      expect(await prefs.getCloudBackupFolderName(), isNull);
    });

    test('set round-trips the display name', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setCloudBackupFolderName('OneDrive › Trailblazer');
      expect(
        await prefs.getCloudBackupFolderName(),
        'OneDrive › Trailblazer',
      );
    });

    test('clear removes the stored name (back to null)', () async {
      final prefs = AppPrefs(SharedPreferencesAsync());
      await prefs.setCloudBackupFolderName('OneDrive › Trailblazer');
      await prefs.clearCloudBackupFolderName();
      expect(await prefs.getCloudBackupFolderName(), isNull);
    });
  });
}
