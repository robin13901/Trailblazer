import 'dart:async';

import 'package:auto_explore/core/prefs/app_prefs.dart';
import 'package:auto_explore/core/routing/app_router.dart';
import 'package:auto_explore/core/theme/app_theme.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
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
    // One-shot matcher-rematch migration: after a matcher-algorithm change we
    // re-process every already-stored trip once so old coverage repaints with
    // the new logic (e.g. the 2026-07-10 pass-through topology guard that
    // stops exit-ramps / side-street stubs / parallel roads from over-drawing).
    // Guarded by a prefs version stamp so it runs exactly once per bump.
    // Deferred to after first frame so it never blocks startup; fire-and-forget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runMatcherRematchMigrationIfNeeded());
    });
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
      // Plan 05-07 (MMT-10): 30-day raw-GPS retention sweep.
      unawaited(ref.read(tripsRepositoryProvider).sweepRawGpsRetention());
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
