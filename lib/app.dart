import 'dart:async';

import 'package:auto_explore/core/routing/app_router.dart';
import 'package:auto_explore/core/theme/app_theme.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
