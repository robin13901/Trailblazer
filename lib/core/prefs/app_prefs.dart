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

  // ── SET-05: raw-GPS retention ─────────────────────────────────────────────
  //
  // Sentinel encoding:
  //   key absent  → "never set" → returns default 30 days
  //   key = -1    → "forever" (explicit user choice, no sweep)
  //   key = 0     → "delete after matching" (sweep with Duration.zero)
  //   key = 30    → 30-day window (default, but explicitly saved)
  //   key = 365   → 1-year window
  //
  // The sentinel (-1 for forever) is preferred over key removal because
  // removing the key loses the distinction between "unset → 30-day default"
  // and "explicit forever → null" (see 09-RESEARCH Open Question #2 discussion).
  static const String kRawGpsRetentionDays = 'raw_gps_retention_days';

  // ── SET-06: diagnostics HUD toggle (consumed by Plans 09-06 / 09-07) ─────
  //
  // This key is added here (09-03) to keep app_prefs.dart single-owner for all
  // of Phase 9. Plans 09-06 / 09-07 read / write via these getters without
  // ever touching this file again.
  static const String kShowDiagnosticsHud = 'show_diagnostics_hud';

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
  /// `3` = 2026-07-13 coverage-from-trail rework: re-match every stored trip so
  /// `_rematchOne` backfills the new `trips.coverage_path_json` (the trimmed
  /// on-road GPS trail that is now the visible coverage line) for trips
  /// recorded before schema v5.
  /// `4` = 2026-07-14 road-snapped coverage line: `coverage_path_json` now holds
  /// the road-snapped polyline (on-road fixes drawn at their snapped position,
  /// raw GPS bridging only off-road gaps). Re-match rebuilds it for all trips.
  /// `5` = 2026-07-18 route-aware matcher + clipped-way coverage: the Viterbi
  /// transition now uses a real bounded on-road route distance (node graph),
  /// eliminating the junction triangle/fan/zigzag mis-snaps; the visible line
  /// is rendered from `driven_way_intervals` clipped to driven sub-intervals
  /// and deduped per way (no longer `coverage_path_json`). Re-match rewrites
  /// every stored trip's intervals under the new matcher so existing trips
  /// repaint correctly without a fresh drive.
  /// `6` = 2026-07-21 partial-match repair: a long trip matched on INCOMPLETE
  /// tile data (the stuck-fetch build cached the trip's northern tiles only
  /// AFTER the match already ran) froze with intervals for just part of the
  /// path — the map drew a fraction of the drive and coverage was under-counted.
  /// All corridor tiles are cached now, so one forced re-match rebuilds the
  /// complete intervals. Paired with a recompute bump so `coverage_cache` is
  /// rebuilt from the repaired intervals (see [kCurrentCoverageRecomputeVersion]).
  /// `7` = 2026-07-22 Viterbi traceback repair: the v6 re-match (shipped with
  /// the OLD decoder) already ran on-device and stamped version 6, so the
  /// 2026-07-22 traceback chain-break fix (viterbi_decoder.dart — long trips
  /// were dropping the pre-reset FIRST half, e.g. trip 11: 271 of ~560
  /// intervals, only the southern part drawn) was gated OUT: `applied(6) >=
  /// current(6)` skipped the re-match entirely. This bump forces exactly one
  /// re-match under the FIXED decoder so every stored trip rebuilds its full
  /// intervals end-to-end. Paired with the recompute bump below.
  /// `8` = 2026-07-26 direction-aware matcher: the Viterbi emission now scores
  /// a GPS-bearing-vs-oneway-direction term (correct carriageway on divided
  /// roads, no overtaking flips), the interval collapse tracks the peak
  /// excursion + splits genuine two-way reversals (in→U-turn→out now covers the
  /// full length), and a small-gap auto-fill closes <=30 m gaps on continuous
  /// roads. Historical trips never stored a heading column, so the decoder's
  /// derived-bearing fallback (from consecutive fixes) supplies direction on
  /// re-match. This bump forces one re-match so all stored trips gain the new
  /// matching. Paired with the recompute bump below.
  /// `9` = 2026-07-26 carriageway hard-gate + highway gap-fill: the emission now
  /// HARD-DROPS a oneway candidate whose legal direction opposes travel by >120°
  /// (the additive soft term at v8 could not overcome the closer wrong
  /// carriageway), queryTopK dedupes by wayId so both carriageways get a beam
  /// slot, and the gap-fill uncaps same-way merges + widens the degree-2
  /// continuation tolerance to 60 m for highway speeds. v8 already ran + stamped
  /// on-device, so this bump is REQUIRED to re-match stored trips under the new
  /// matcher (verified on the live DB: A66 both carriageways 36/69%→100%, A45
  /// dropped carriageway 0%→100%). Paired with the recompute bump below.
  /// `10` = 2026-07-27 segment-aware oneway check + through-intersection gap
  /// bridge. The oneway-violation penalty compared projectionFraction WITHOUT
  /// segIdx; that fraction resets 0→1 per segment, so on a fast, densely-
  /// segmented forward-oneway trunk ~half the genuinely-forward steps wrongly
  /// incurred kOnewayViolationLog and a parallel `oneway=no` side road (exempt
  /// from the penalty) out-scored the correct carriageway — the match defected
  /// onto it for kilometres (live trip 18, B469 near Wörth). Fix: derive the
  /// direction sign from the segIdx delta first, fraction only within one
  /// segment. Plus a new corridor-gated shortest-path gap bridge that closes
  /// through-intersection holes without painting undriven roads. Verified on the
  /// live DB (B469/A45/A66 all correct, junctions continuous). This bump forces
  /// one re-match so stored trips gain both. Paired with the recompute bump.
  /// `11` = 2026-07-27 six-defect matcher batch (all verified on the live DB at
  /// the rendered level): (B) the gap-fill direction-equality guard is now
  /// scoped to the same-wayId merge only, so an in-town TURN between two ways
  /// (which flips each way's direction label) closes its apex gap; (E) the
  /// gap-fill now recognises an INTERIOR-node junction (two ways meeting where
  /// the node is mid-way along the longer way), closing the turn gap it missed;
  /// (C) a collapsed interval is DROPPED when >35 % of its geometry lies far
  /// (>15 m) from the raw GPS track — kills the parallel residential over-draw
  /// (Obrigheim) and the B469-frontage over-paint (Stockstadt, defect F) with
  /// one geometry-based rule; (A) the traceback now prefers a CONNECTED terminal
  /// over a broken-path reset, so a node-disjoint under-bridge road can no longer
  /// out-select the correctly-driven A66 carriageway on a single closer fix
  /// (closes the gap + drops the wrong paint). A/F use NO speed heuristic and no
  /// static road-class prior (both explicitly rejected). Re-match rebuilds every
  /// stored trip under the corrected matcher. Paired with the recompute bump.
  /// `12` = 2026-08-13 force full re-match + recompute on fresh install after
  /// importing a backup, so all trips are processed under the current matcher
  /// and coverage_cache is fully rebuilt from scratch.
  static const int kCurrentMatcherRematchVersion = 12;

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
  /// showed nothing despite driven intervals existing. `2` = 2026-07-19 heal:
  /// the auto seam used the incremental `recomputeForTrip()`, whose partial
  /// per-bbox overwrite drove region coverage % DOWN (non-monotonic). The seam
  /// is now the full `recompute()`; this forces one clean full pass to repair
  /// the corrupted absolute driven/total lengths left by the incremental path.
  /// `3` = 2026-07-21: rebuild `coverage_cache` after the v6 re-match repairs
  /// trip 11's partial intervals. Also: the recompute now runs UNCONDITIONALLY
  /// whenever the re-match migration runs (see App._runStartupMigrations), so a
  /// future forced re-match can never again leave the region stats stale — this
  /// bump is the belt-and-suspenders trigger for the current repair.
  /// `4` = 2026-07-22: paired with the v7 re-match (Viterbi traceback fix). The
  /// `force: rematched` path already rebuilds `coverage_cache` from the repaired
  /// intervals, but this explicit bump keeps the recompute stamp truthful and
  /// gives a standalone trigger should the re-match itself be a no-op on some
  /// device (e.g. version already 7 but cache never written).
  /// `5` = 2026-07-26 durable clip-per-region recompute: coverage is now summed
  /// from the `way_region_attribution` table (each way clipped to the meter-
  /// ranges inside each admin region) instead of centroid-whole-way attribution
  /// over live Overpass tiles. This is the first pass that populates the new
  /// attribution table AND rebuilds `coverage_cache` under the corrected
  /// (boundary-splitting, eviction-proof, monotonic) numbers. Paired with the v8
  /// re-match so the repaired intervals feed the new aggregation.
  /// `6` = 2026-07-26 paired with the v9 re-match (carriageway hard-gate +
  /// highway gap-fill). The re-match rewrites intervals under the new matcher;
  /// this bump forces one clean clip-per-region rebuild so coverage_cache
  /// reflects the corrected carriageway coverage. (v5 already stamped on-device,
  /// so a bump is required for the recompute to re-run.)
  /// `7` = 2026-07-27 paired with the v10 re-match (segment-aware oneway check +
  /// through-intersection gap bridge). The re-match rewrites intervals; this
  /// bump forces one clip-per-region rebuild so coverage_cache reflects the
  /// corrected B469/A45/A66 carriageways and the newly-closed junction gaps.
  /// `8` = 2026-07-27 paired with the v11 six-defect batch. The re-match removes
  /// the parallel over-draw (Obrigheim/Stockstadt) and under-bridge mis-paint
  /// (A66) and closes the in-town turn gaps (Geislitz/Kleinheubach); this bump
  /// forces one clip-per-region rebuild so coverage_cache reflects the corrected
  /// driven set (dropped false-positive km + newly-closed gaps).
  /// `9` = 2026-08-13 fix LRU-eviction blind spot in Stage-1 attribution: the
  /// recompute now fetches tiles from the network when they are not in the 50 MB
  /// LRU cache (cacheOnly:false), so new regions driven after a long gap (where
  /// trip tiles were evicted before recompute ran) are no longer stuck at 0%.
  /// Forces one clean clip-per-region rebuild to attribute any previously-missed
  /// ways from trips 32/33 and similar drives.
  /// `10` = 2026-08-13 paired with rematch v12: force full recompute after
  /// re-match so coverage_cache is rebuilt from the freshly rewritten intervals.
  static const int kCurrentCoverageRecomputeVersion = 10;

  /// Version stamp of the last stuck-fetch recovery migration applied to this
  /// device. Bumped when a one-shot recovery of trips parked by an Overpass
  /// outage is needed (reset the pending-fetch backoff + purge poisoned 0-way
  /// tiles). The startup migration compares this against
  /// [kCurrentStuckFetchRecoveryVersion] and runs the recovery once when they
  /// differ.
  static const String kStuckFetchRecoveryVersion =
      'stuck_fetch_recovery_version';

  /// Current stuck-fetch recovery version. Bump to force a one-shot recovery
  /// on the next launch.
  /// * `1` = 2026-07-14: the Overpass HTTP-200-error client fix — trips parked
  ///   under the 5min→24h backoff (or abandoned) and tiles poisoned as 0-way
  ///   HTML need a one-time reset + purge to recover without a fresh drive.
  /// * `2` = 2026-07-21: orphan reconcile — trips stranded at `pendingRoadData`
  ///   with no `pending_road_fetches` row (app killed mid-fetch) are
  ///   re-enqueued so the resume drain completes them.
  static const int kCurrentStuckFetchRecoveryVersion = 2;

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

  /// The stuck-fetch recovery version already applied on this device, or null
  /// when it has never run.
  Future<int?> getStuckFetchRecoveryVersion() =>
      _prefs.getInt(kStuckFetchRecoveryVersion);

  /// Records [version] as the stuck-fetch recovery migration applied on this
  /// device. Written only after the recovery completes so a failed run retries
  /// on the next launch.
  Future<void> setStuckFetchRecoveryVersion(int version) =>
      _prefs.setInt(kStuckFetchRecoveryVersion, version);

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
    return s == null
        ? CoverageColorPreset.amber
        : CoverageColorPreset.fromString(s);
  }

  /// Persists [p] as the user-chosen coverage color preset.
  Future<void> setCoveragePreset(CoverageColorPreset p) =>
      _prefs.setString(kCoveragePreset, p.name);

  // ── SET-05: raw-GPS retention ─────────────────────────────────────────────

  /// Retention window in days.
  ///
  /// - Returns `null` when the user has chosen "forever" (no sweep).
  /// - Returns `0` when the user has chosen "delete after matching".
  /// - Returns `30` (the default) when the key has never been written.
  /// - Returns `365` for the 1-year window.
  ///
  /// Sentinel: stored value `-1` → `null` (forever). This lets the
  /// getter distinguish "unset → default 30" from "explicit forever → null".
  Future<int?> getRawGpsRetentionDays() async {
    final v = await _prefs.getInt(kRawGpsRetentionDays);
    if (v == null) return 30; // never set → default 30 days
    if (v < 0) return null; // -1 sentinel → forever
    return v;
  }

  /// Persists the raw-GPS retention window.
  ///
  /// [days] == `null` stores the forever sentinel (`-1`).
  /// [days] == `0` deletes raw points immediately after matching.
  /// [days] == `30` or `365` stores verbatim.
  Future<void> setRawGpsRetentionDays(int? days) =>
      _prefs.setInt(kRawGpsRetentionDays, days ?? -1);

  // ── SET-06: diagnostics HUD toggle ───────────────────────────────────────

  /// Whether the live diagnostics HUD overlay is enabled.
  ///
  /// Defaults to `false` when the key has never been written.
  Future<bool> getShowDiagnosticsHud() async =>
      (await _prefs.getBool(kShowDiagnosticsHud)) ?? false;

  /// Persists the diagnostics-HUD toggle state.
  Future<void> setShowDiagnosticsHud({required bool show}) =>
      _prefs.setBool(kShowDiagnosticsHud, show);
}

/// Provider for the singleton [AppPrefs].
///
/// Plain `Provider<T>` per STATE Plan 01-01 (no `@Riverpod` codegen).
final appPrefsProvider = Provider<AppPrefs>(
  (ref) => AppPrefs(SharedPreferencesAsync()),
);
