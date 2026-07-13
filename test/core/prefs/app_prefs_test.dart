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
      final raw =
          await SharedPreferencesAsync().getInt(AppPrefs.kRawGpsRetentionDays);
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
}
