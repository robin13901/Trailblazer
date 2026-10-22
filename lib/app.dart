import 'dart:async';

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_geometry_dao.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/core/routing/app_router.dart';
import 'package:auto_explore/core/theme/app_theme.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/data/way_geometry_backfill_service.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_providers.dart';
import 'package:auto_explore/features/startup/data/global_recalc_progress_provider.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> with WidgetsBindingObserver {
  static final _log = Logger('App');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // One-shot startup migrations, run in order after the first frame so they
    // never block startup; fire-and-forget. Each is guarded by its own prefs
    // version stamp so it runs exactly once per bump.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadNextGisKey());
      unawaited(_runStartupMigrations());
    });
  }

  /// Runs one-shot startup migrations, ordered by user-visible priority and
  /// network cost so a flaky link never starves the important work:
  ///   1. Stuck-fetch recovery FIRST (awaited) — depends on nothing and
  ///      recovers a trip parked by an Overpass outage; must not sit behind the
  ///      network-heavy re-match.
  ///   2. Matcher re-match (awaited when it has work) — a trip matched on
  ///      incomplete tile data (stuck-fetch build) froze with partial intervals;
  ///      re-matching now that all corridor tiles are cached rebuilds the full
  ///      intervals. Awaited BEFORE the recompute so the recompute reads the
  ///      REPAIRED intervals (2026-07-21 ordering fix — previously recompute ran
  ///      first, over stale intervals, then never re-ran).
  ///   3. Coverage recompute (awaited) so `coverage_cache` rows are rebuilt from
  ///      the (now-repaired) intervals, including real_total_length_m from the
  ///      bundled totals table. Forced to run whenever the re-match migration
  ///      just ran, so a repaired trip can never leave the region stats stale.
  Future<void> _runStartupMigrations() async {
    try {
      await _runStuckFetchRecoveryMigrationIfNeeded();
      final rematched = await _runMatcherRematchMigrationIfNeeded();
      await _runCoverageRecomputeMigrationIfNeeded(force: rematched);
      // Way-geometry backfill runs AFTER recompute so the tile cache is warm.
      await _runWayGeometryBackfillIfNeeded();
    } finally {
      ref.read(globalRecalcProgressProvider.notifier).clear();
    }
  }

  /// Loads the NextGIS Overpass API key from SharedPreferences into
  /// [nextgisApiKeyProvider] so the pool includes the NextGIS endpoint from
  /// the first tile fetch onwards. Runs fire-and-forget after the first frame.
  Future<void> _loadNextGisKey() async {
    final key = await ref.read(appPrefsProvider).getNextGisApiKey();
    if (!mounted) return;
    if (key != null && key.isNotEmpty) {
      ref.read(nextgisApiKeyProvider.notifier).currentKey = key;
    }
  }

  /// Runs the one-shot re-match migration when the stored matcher-rematch
  /// version is behind [AppPrefs.kCurrentMatcherRematchVersion]. Best-effort:
  /// logs and swallows all errors so a migration hiccup never blocks the app,
  /// and only stamps the new version after a successful pass so a failed run
  /// retries on the next launch.
  ///
  /// Returns true when a re-match pass actually ran this launch (so the caller
  /// can force the coverage recompute to reflect the rewritten intervals).
  Future<bool> _runMatcherRematchMigrationIfNeeded() async {
    final prefs = ref.read(appPrefsProvider);
    try {
      final applied = await prefs.getMatcherRematchVersion() ?? 0;
      if (applied >= AppPrefs.kCurrentMatcherRematchVersion) return false;
      _log.info(
        'matcher-rematch migration: applied=$applied '
        'current=${AppPrefs.kCurrentMatcherRematchVersion} — reprocessing',
      );
      // Surface the app-wide banner immediately ("Neuberechnung …"); the
      // per-trip onTripDone callback below fills in the N/M counts as each
      // stored trip is reprocessed. Cleared in _runStartupMigrations.
      final recalc = ref.read(globalRecalcProgressProvider.notifier)
        ..startRematching(0);
      final n = await ref
          .read(tripMatchCoordinatorProvider)
          .rematchAllStoredTrips(
            onTripDone: recalc.updateRematching,
          );
      await prefs.setMatcherRematchVersion(
        AppPrefs.kCurrentMatcherRematchVersion,
      );
      _log.info('matcher-rematch migration: done ($n trips reprocessed)');
      return true;
      // Catch every throwable: a cosmetic reprocess must never crash startup.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('matcher-rematch migration failed (will retry): $e', e, st);
      return false;
    }
  }

  /// Runs the one-shot coverage-cache recompute when the stored version is
  /// behind [AppPrefs.kCurrentCoverageRecomputeVersion], OR when [force] is
  /// true (the re-match migration just rewrote intervals this launch, so
  /// `coverage_cache` MUST be rebuilt to reflect them even if the recompute
  /// version stamp is already current — 2026-07-21 fix for the stale-regions
  /// bug where a repaired trip left the region browser showing old numbers).
  ///
  /// Phase 8 shipped the `coverage_cache` writer, but trips confirmed before
  /// that never triggered the post-confirm `recompute()` hook, so
  /// `coverage_cache` stayed empty and the region browser + focus pill showed
  /// nothing despite driven intervals existing. This backfills those trips.
  ///
  /// Best-effort: logs and swallows all errors so a hiccup never blocks the
  /// app, and only stamps the new version after a successful pass so a failed
  /// run (e.g. admin bundle still loading) retries on the next launch.
  Future<void> _runCoverageRecomputeMigrationIfNeeded({
    bool force = false,
  }) async {
    final prefs = ref.read(appPrefsProvider);
    try {
      final applied = await prefs.getCoverageRecomputeVersion() ?? 0;
      final versionBehind = applied < AppPrefs.kCurrentCoverageRecomputeVersion;
      if (!versionBehind && !force) return;
      _log.info(
        'coverage-recompute migration: applied=$applied '
        'current=${AppPrefs.kCurrentCoverageRecomputeVersion} '
        'force=$force — recomputing',
      );
      // Invalidate the durable line blob so the resolver does not serve a
      // stale/partial one while the recompute is refilling the tile cache.
      // The blob is rebuilt fresh by the overlay resolver after recompute().
      try {
        await ref.read(coverageLineCacheDaoProvider).deleteAll();
        // A blob-clear hiccup must never abort startup.
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        _log.warning('coverage-recompute migration: blob clear failed: $e');
      }
      // Switch the app-wide banner to the coverage-rebuild phase ("Abdeckung
      // wird neu berechnet …"). Cleared in _runStartupMigrations after this
      // returns.
      final recalc = ref.read(globalRecalcProgressProvider.notifier)
        ..startRecomputing();
      // Thread STAGE-1 clip progress into the banner so it shows a determinate
      // "… N/M" bar instead of a 20-min indeterminate spinner. Progress is
      // tile-coarse (per-way counts can't cross the compute-isolate boundary).
      final result = await ref
          .read(coverageComputeServiceProvider)
          .recompute(
            onProgress: recalc.updateRecomputing,
            onTileFetch: recalc.updateRecomputing,
          );
      // recompute() never throws — it returns Result. Only stamp on Ok so a
      // failed pass retries next launch. When only [force] triggered this (the
      // version stamp was already current), a successful pass re-stamps the
      // same current version — harmless and keeps the stamp truthful.
      if (result case Ok(value: final written)) {
        await prefs.setCoverageRecomputeVersion(
          AppPrefs.kCurrentCoverageRecomputeVersion,
        );
        _log.info('coverage-recompute migration: done ($written regions)');
      } else {
        _log.warning(
          'coverage-recompute migration: recompute returned Err — will retry',
        );
      }
      // Catch every throwable: a cache backfill must never crash startup.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning(
        'coverage-recompute migration failed (will retry): $e',
        e,
        st,
      );
    }
  }

  /// One-time recovery of trips left parked by an Overpass outage, plus a
  /// purge of tiles poisoned as 0-way before the HTTP-200-error client fix.
  /// Version-stamped via [AppPrefs] so it runs exactly once per bump.
  ///
  /// Steps: reset the pending-fetch backoff so parked/abandoned trips are
  /// immediately drainable; delete 0-way cached tiles so a re-fetch gets real
  /// road data; then kick `drainQueue` + `processPending` to recover now
  /// rather than waiting for the next resume. Best-effort: logs and swallows
  /// all errors, and stamps the version only on success so a failed run
  /// retries next launch.
  Future<void> _runStuckFetchRecoveryMigrationIfNeeded() async {
    final prefs = ref.read(appPrefsProvider);
    try {
      final applied = await prefs.getStuckFetchRecoveryVersion() ?? 0;
      if (applied >= AppPrefs.kCurrentStuckFetchRecoveryVersion) return;
      _log.info(
        'stuck-fetch recovery: applied=$applied '
        'current=${AppPrefs.kCurrentStuckFetchRecoveryVersion} — recovering',
      );
      final db = ref.read(appDatabaseProvider);
      final resetRows = await db.pendingRoadFetchesDao.resetAllBackoff();
      final purgedTiles = await db.overpassWayCacheDao.deleteZeroWayTiles();
      // Orphan reconcile (2026-07-21): re-enqueue trips stranded at
      // pendingRoadData with no queue row (e.g. app killed mid-fetch after a
      // long drive) so the drainQueue below can complete them. Without this
      // they are invisible to every recovery path and spin forever.
      final reconciled = await ref
          .read(tripRoadFetchCoordinatorProvider)
          .reconcileOrphanedPendingRoadData();
      _log.info(
        'stuck-fetch recovery: reset $resetRows queued fetch(es), '
        'purged $purgedTiles zero-way tile(s), '
        'reconciled $reconciled orphaned pendingRoadData trip(s)',
      );
      // Kick recovery immediately instead of waiting for the next resume.
      unawaited(ref.read(tripRoadFetchCoordinatorProvider).drainQueue());
      unawaited(ref.read(tripMatchCoordinatorProvider).processPending());
      await prefs.setStuckFetchRecoveryVersion(
        AppPrefs.kCurrentStuckFetchRecoveryVersion,
      );
      _log.info('stuck-fetch recovery: done');
      // Catch every throwable: a recovery hiccup must never crash startup.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('stuck-fetch recovery failed (will retry): $e', e, st);
    }
  }

  /// One-shot backfill: populate driven_way_geometry for all existing trips
  /// that were matched before schema v10. Runs once, stamped via prefs.
  Future<void> _runWayGeometryBackfillIfNeeded() async {
    final prefs = ref.read(appPrefsProvider);
    try {
      final applied = await prefs.getWayGeometryBackfillVersion() ?? 0;
      if (applied >= AppPrefs.kCurrentWayGeometryBackfillVersion) return;
      _log.info(
        'way-geometry backfill: applied=$applied '
        'current=${AppPrefs.kCurrentWayGeometryBackfillVersion} — starting',
      );
      final recalc = ref.read(globalRecalcProgressProvider.notifier)
        ..startGeometryBackfill();
      final db = ref.read(appDatabaseProvider);
      final service = WayGeometryBackfillService(
        intervalsDao: DrivenWayIntervalsDao(db),
        geometryDao: DrivenWayGeometryDao(db),
        waySource: ref.read(wayCandidateSourceProvider),
        tripsDao: TripsDao(db),
      );
      final result = await service.run(
        onProgress: recalc.updateGeometryBackfill,
      );
      if (result case Ok(value: final written)) {
        await prefs.setWayGeometryBackfillVersion(
          AppPrefs.kCurrentWayGeometryBackfillVersion,
        );
        _log.info('way-geometry backfill: done ($written ways written)');
      } else {
        _log.warning(
          'way-geometry backfill returned Err — will retry next launch',
        );
      }
      // Catches all throwables: a geometry backfill must never crash startup.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('way-geometry backfill failed (will retry): $e', e, st);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Plan 04-15: drain any pending Overpass road-fetches queued while the
      // app was backgrounded or offline. Fire-and-forget — the coordinator
      // logs its own errors and never throws to callers.
      unawaited(ref.read(tripRoadFetchCoordinatorProvider).drainQueue());
      // Plan 05-07: pick up any pending trips that arrived while the isolate
      // was not running (e.g. app killed mid-match).
      unawaited(ref.read(tripMatchCoordinatorProvider).processPending());
      // Plan 09-03 (MMT-10): raw-GPS retention sweep using the persisted
      // window. Skip when the user has chosen "forever" (null retention).
      unawaited(_runRetentionSweepIfNeeded());
    }
  }

  /// Reads the user-chosen raw-GPS retention window from [AppPrefs] and
  /// runs the sweep. Skipped entirely when the window is `null` (forever).
  ///
  /// Fire-and-forget. Logs and swallows errors so a sweep hiccup never
  /// crashes the app on resume.
  Future<void> _runRetentionSweepIfNeeded() async {
    try {
      final days = await ref.read(appPrefsProvider).getRawGpsRetentionDays();
      if (days == null) {
        // "Forever" — user has opted out of automatic deletion.
        _log.fine('retention sweep skipped (window=forever)');
        return;
      }
      unawaited(
        ref
            .read(tripsRepositoryProvider)
            .sweepRawGpsRetention(
              retention: Duration(days: days),
            ),
      );
      // Catches all throwables: a sweep hiccup must never crash on resume.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('retention sweep failed: $e', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Trailblazer',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
