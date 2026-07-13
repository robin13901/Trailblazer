import 'dart:async';

import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/core/routing/app_router.dart';
import 'package:auto_explore/core/theme/app_theme.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_providers.dart';
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
      unawaited(_runStartupMigrations());
    });
  }

  /// Runs one-shot startup migrations in order, best-effort. The coverage
  /// recompute runs AFTER the matcher rematch so it reads settled
  /// `driven_way_intervals` (the rematch can rewrite intervals, which the
  /// recompute then aggregates into `coverage_cache`).
  Future<void> _runStartupMigrations() async {
    await _runMatcherRematchMigrationIfNeeded();
    await _runCoverageRecomputeMigrationIfNeeded();
    // After the driven-coverage cache is populated, compute the REAL
    // region-wide total road length for any region missing it (background,
    // once per region, tiled area-clipped Overpass sums). Runs last because it
    // depends on coverage_cache rows existing and is the heaviest / most
    // network-bound step. Best-effort; failures retry next launch.
    await _computeMissingRegionTotals();
  }

  /// Runs the one-shot re-match migration when the stored matcher-rematch
  /// version is behind [AppPrefs.kCurrentMatcherRematchVersion]. Best-effort:
  /// logs and swallows all errors so a migration hiccup never blocks the app,
  /// and only stamps the new version after a successful pass so a failed run
  /// retries on the next launch.
  Future<void> _runMatcherRematchMigrationIfNeeded() async {
    final prefs = ref.read(appPrefsProvider);
    try {
      final applied = await prefs.getMatcherRematchVersion() ?? 0;
      if (applied >= AppPrefs.kCurrentMatcherRematchVersion) return;
      _log.info(
        'matcher-rematch migration: applied=$applied '
        'current=${AppPrefs.kCurrentMatcherRematchVersion} — reprocessing',
      );
      final n = await ref
          .read(tripMatchCoordinatorProvider)
          .rematchAllStoredTrips();
      await prefs
          .setMatcherRematchVersion(AppPrefs.kCurrentMatcherRematchVersion);
      _log.info('matcher-rematch migration: done ($n trips reprocessed)');
      // Catch every throwable: a cosmetic reprocess must never crash startup.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('matcher-rematch migration failed (will retry): $e', e, st);
    }
  }

  /// Runs the one-shot coverage-cache recompute when the stored version is
  /// behind [AppPrefs.kCurrentCoverageRecomputeVersion]. Phase 8 shipped the
  /// `coverage_cache` writer, but trips confirmed before that never triggered
  /// the post-confirm `recompute()` hook, so `coverage_cache` stayed empty and
  /// the region browser + focus pill showed nothing despite driven intervals
  /// existing. This backfills those pre-Phase-8 trips exactly once.
  ///
  /// Best-effort: logs and swallows all errors so a hiccup never blocks the
  /// app, and only stamps the new version after a successful pass so a failed
  /// run (e.g. admin bundle still loading) retries on the next launch.
  Future<void> _runCoverageRecomputeMigrationIfNeeded() async {
    final prefs = ref.read(appPrefsProvider);
    try {
      final applied = await prefs.getCoverageRecomputeVersion() ?? 0;
      if (applied >= AppPrefs.kCurrentCoverageRecomputeVersion) return;
      _log.info(
        'coverage-recompute migration: applied=$applied '
        'current=${AppPrefs.kCurrentCoverageRecomputeVersion} — recomputing',
      );
      final result =
          await ref.read(coverageComputeServiceProvider).recompute();
      // recompute() never throws — it returns Result. Only stamp on Ok so a
      // failed pass retries next launch.
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

  /// Computes the REAL per-region total road length for any region that has
  /// driven coverage but no real total cached yet. Fire-and-forget from the
  /// startup migration chain; the service is best-effort and never throws, so
  /// a partial run (or a total network outage) simply leaves regions pending
  /// (their cards show a spinner) and retries on the next launch.
  Future<void> _computeMissingRegionTotals() async {
    try {
      final n = await ref
          .read(regionTotalLengthServiceProvider)
          .computeMissingTotals();
      if (n > 0) _log.info('region-total compute: $n regions computed');
      // Catch every throwable: a background total compute must never crash.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _log.warning('region-total compute failed (will retry): $e', e, st);
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
      final days =
          await ref.read(appPrefsProvider).getRawGpsRetentionDays();
      if (days == null) {
        // "Forever" — user has opted out of automatic deletion.
        _log.fine('retention sweep skipped (window=forever)');
        return;
      }
      unawaited(
        ref.read(tripsRepositoryProvider).sweepRawGpsRetention(
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
