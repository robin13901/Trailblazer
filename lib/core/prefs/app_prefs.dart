import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide key/value preferences.
///
/// Follows the same shape as `OnboardingFlagRepository` (STATE Plan 01-03):
/// a thin, constructor-injectable wrapper around [SharedPreferencesAsync]
/// that carries no in-memory cache — every read/write goes through the
/// platform channel.
class AppPrefs {
  AppPrefs(this._prefs);

  static const String kAdminBundleVersion = 'admin_bundle_version';

  final SharedPreferencesAsync _prefs;

  /// Returns the last-known admin-bundle version stamp, or null when the
  /// user has never triggered a runtime refresh (in which case the
  /// bundled asset from `assets/admin/germany_admin.geojson.gz` is
  /// authoritative).
  Future<String?> getAdminBundleVersion() =>
      _prefs.getString(kAdminBundleVersion);

  /// Stores [version] as the current admin-bundle version stamp. Written
  /// by `AdminBundleRefresher` after every successful runtime refresh.
  Future<void> setAdminBundleVersion(String version) =>
      _prefs.setString(kAdminBundleVersion, version);
}

/// Provider for the singleton [AppPrefs].
///
/// Plain `Provider<T>` per STATE Plan 01-01 (no `@Riverpod` codegen).
final appPrefsProvider = Provider<AppPrefs>(
  (ref) => AppPrefs(SharedPreferencesAsync()),
);
