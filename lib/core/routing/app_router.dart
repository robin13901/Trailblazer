import 'package:auto_explore/features/map/presentation/map_screen.dart';
import 'package:auto_explore/features/onboarding/presentation/onboarding_screen.dart';
import 'package:auto_explore/features/onboarding/presentation/splash_screen.dart';
import 'package:auto_explore/features/regions/presentation/regions_screen.dart';
import 'package:auto_explore/features/settings/presentation/settings_screen.dart';
import 'package:auto_explore/features/settings/presentation/tracking_diagnostics_screen.dart';
import 'package:auto_explore/features/trips/presentation/trips_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Top-level GoRouter.
///
/// Onboarding gating stays inside SplashScreen (see Plan 01-03).
/// Phase 2 replaces the placeholder home route with a
/// StatefulShellRoute.indexedStack so tab-switching preserves per-tab
/// state.
///
/// Shell branches:
///   0: '/'         → MapScreen (base map + glass chrome)
///   1: '/trips'    → TripsScreen (stub, Phase 6)
///   2: '/regions'  → RegionsScreen (stub, Phase 8)
///
/// `/settings` is a separate top-level route reachable from the top-left
/// glass button on MapScreen. It is intentionally NOT a shell branch
/// (per 02-CONTEXT.md — Settings is out of the pill).
///
/// NOTE: plain `Provider` (no `@Riverpod` code-gen) — matches the
/// project-wide decision to avoid `riverpod_generator` code-gen while
/// `custom_lint`/`riverpod_lint` are out of the toolchain
/// (see STATE.md Plan 01-01 decision).
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/settings',
        // Plan 04-18 Task 6 (2026-07-08): NoTransitionPage — the default
        // MaterialPage transition (Android fade+slide) looked laggy
        // against the liquid-glass chrome per user feedback. Instant
        // swap on both push and pop.
        pageBuilder: (context, state) => NoTransitionPage(
          key: state.pageKey,
          child: const SettingsScreen(),
        ),
      ),
      // Dev-only diagnostics route (Plan 03-1-01). Registered only in debug
      // builds — `kDebugMode` is a const, so the route entry (and its widget
      // reference) is tree-shaken from release APK/IPA.
      if (kDebugMode)
        GoRoute(
          path: '/settings/diagnostics',
          builder: (context, state) => const TrackingDiagnosticsScreen(),
        ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            MapScreen(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const _MapTabContent(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/trips',
                builder: (context, state) => const TripsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/regions',
                builder: (context, state) => const RegionsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Sentinel widget used by the Map branch.
///
/// [MapScreen] is the shell builder itself — it owns the base map and all
/// chrome overlays. When the Map tab is active, the branch content is empty
/// because the map surface is already visible in the Stack. When Trips or
/// Regions tabs are active, [MapScreen] renders [StatefulNavigationShell]
/// directly (which shows [TripsScreen] / [RegionsScreen] with opaque
/// backgrounds masking the map).
///
/// Keeping this as an explicit, named sentinel (rather than `null` or a
/// `SizedBox`) makes the `StatefulShellRoute` branch intent clear for
/// Phase 3+ maintainers.
class _MapTabContent extends StatelessWidget {
  const _MapTabContent();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
