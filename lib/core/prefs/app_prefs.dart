import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
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
  static const String kCoveragePreset = 'coverage_preset';

  /// Version stamp of the last matcher-algorithm migration that has been
  /// applied to already-stored trips. Bumped whenever the matcher changes in
  /// a way that requires re-processing existing intervals; the startup
  /// migration compares this against [kCurrentMatcherRematchVersion] and
  /// re-matches all stored trips once when they differ.
  static const String kMatcherRematchVersion = 'matcher_rematch_version';

  /// Current matcher-algorithm migration version. Bump this (and ship the
  /// matcher change) to trigger a one-shot re-match of every stored trip on
  /// the next launch. `1` = the 2026-07-10 pass-through topology guard that
  /// stops exit-ramps / side-street stubs / parallel roads from over-drawing.
  /// `2` = same day, corrected the topology check to assign each neighbour to
  /// its NEAREST connector endpoint (the v1 "within-tolerance" test trivially
  /// passed on short stubs and left the artifacts extended).
  static const int kCurrentMatcherRematchVersion = 2;

  /// Version stamp of the last coverage-cache recompute migration applied to
  /// this device. Bumped whenever `coverage_cache` needs a one-shot
  /// repopulation for already-stored trips (e.g. Phase 8 shipped the cache
  /// writer, but trips confirmed before it never triggered the post-confirm
  /// `recompute()` hook). The startup migration compares this against
  /// [kCurrentCoverageRecomputeVersion] and runs
  /// `CoverageComputeService.recompute()` once when they differ.
  static const String kCoverageRecomputeVersion = 'coverage_recompute_version';

  /// Current coverage-recompute migration version. Bump to force a one-shot
  /// `coverage_cache` repopulation on the next launch. `1` = 2026-07-11
  /// Phase-8 backfill: trips confirmed before the Phase-8 recompute hook
  /// existed left `coverage_cache` empty, so the region browser + focus pill
  /// showed nothing despite driven intervals existing.
  static const int kCurrentCoverageRecomputeVersion = 1;

  final SharedPreferencesAsync _prefs;

  /// The matcher-rematch version already applied on this device, or null when
  /// no migration has run yet (fresh install, or first launch after the
  /// feature shipped).
  Future<int?> getMatcherRematchVersion() =>
      _prefs.getInt(kMatcherRematchVersion);

  /// Records [version] as the matcher-rematch migration applied on this
  /// device. Written after `rematchAllStoredTrips` completes so the one-shot
  /// migration never runs twice for the same version.
  Future<void> setMatcherRematchVersion(int version) =>
      _prefs.setInt(kMatcherRematchVersion, version);

  /// The coverage-recompute migration version already applied on this device,
  /// or null when it has never run (fresh install, or first launch after the
  /// backfill shipped).
  Future<int?> getCoverageRecomputeVersion() =>
      _prefs.getInt(kCoverageRecomputeVersion);

  /// Records [version] as the coverage-recompute migration applied on this
  /// device. Written only after `CoverageComputeService.recompute()` succeeds
  /// so a failed run retries on the next launch.
  Future<void> setCoverageRecomputeVersion(int version) =>
      _prefs.setInt(kCoverageRecomputeVersion, version);

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

  /// Returns the stored [CoverageColorPreset], defaulting to [CoverageColorPreset.amber]
  /// when no value has been persisted yet.
  Future<CoverageColorPreset> getCoveragePreset() async {
    final s = await _prefs.getString(kCoveragePreset);
    return s == null ? CoverageColorPreset.amber : CoverageColorPreset.fromString(s);
  }

  /// Persists [p] as the user-chosen coverage color preset.
  Future<void> setCoveragePreset(CoverageColorPreset p) =>
      _prefs.setString(kCoveragePreset, p.name);
}

/// Provider for the singleton [AppPrefs].
///
/// Plain `Provider<T>` per STATE Plan 01-01 (no `@Riverpod` codegen).
final appPrefsProvider = Provider<AppPrefs>(
  (ref) => AppPrefs(SharedPreferencesAsync()),
);
