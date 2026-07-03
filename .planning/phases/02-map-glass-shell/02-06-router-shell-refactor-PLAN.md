---
plan: "02-06"
title: "Router refactor — StatefulShellRoute with 3 tabs + Settings stub"
phase: "02-map-glass-shell"
type: execute
wave: 4
depends_on: ["02-05"]
files_modified:
  - lib/core/routing/app_router.dart
  - lib/features/map/presentation/map_screen.dart              # accept navigationShell
  - lib/features/trips/presentation/trips_screen.dart          # new stub
  - lib/features/regions/presentation/regions_screen.dart      # new stub
  - lib/features/settings/presentation/settings_screen.dart    # new stub (top-left glass button lands here)
  - lib/features/map/presentation/widgets/bottom_nav_shell.dart  # optional tweak: expose currentIndex from shell
  - lib/features/map/presentation/widgets/settings_glass_button.dart  # replace SnackBar with context.go('/settings')
  - test/features/map/router_shell_test.dart
  - test/widget_test.dart                                       # update final-screen assertion
autonomous: true

must_haves:
  truths:
    - "`/` route is replaced by a `StatefulShellRoute.indexedStack` with three branches: `/` (map), `/trips`, `/regions`."
    - "`MapScreen` accepts a `StatefulNavigationShell` and renders `navigationShell` inside the map area OR uses `navigationShell.currentIndex` + `navigationShell.goBranch(i)` to drive the bottom nav pill. Tab-switching preserves per-tab state (indexedStack semantics)."
    - "A `/settings` route exists as a plain (non-shell) sub-route so the top-left glass button opens it."
    - "Splash + onboarding are unchanged; `context.go('/')` still lands on the map."
    - "Widget test asserts: launching the app, dismissing splash+onboarding, lands on `MapScreen`; tapping Trips tab shows `TripsScreen` placeholder; tapping Map tab returns; back button behavior is sensible."
    - "`flutter analyze` + `flutter test` green (including the updated `test/widget_test.dart`)."
  artifacts:
    - path: lib/core/routing/app_router.dart
      provides: "GoRouter with splash + onboarding + StatefulShellRoute + settings."
      contains: "StatefulShellRoute.indexedStack"
    - path: lib/features/trips/presentation/trips_screen.dart
      provides: "Placeholder — 'Trips coming in Phase 6'."
      contains: "class TripsScreen"
    - path: lib/features/regions/presentation/regions_screen.dart
      provides: "Placeholder — 'Regions coming in Phase 8'."
      contains: "class RegionsScreen"
    - path: lib/features/settings/presentation/settings_screen.dart
      provides: "Placeholder — 'Settings coming in Phase 10'."
      contains: "class SettingsScreen"
  key_links:
    - from: lib/core/routing/app_router.dart
      to: lib/features/map/presentation/map_screen.dart
      via: "StatefulShellRoute builder passes navigationShell → MapScreen"
      pattern: "MapScreen(navigationShell: navigationShell)"
    - from: lib/features/map/presentation/map_screen.dart
      to: lib/features/map/presentation/widgets/bottom_nav_shell.dart
      via: "MapScreen builds BottomNavShell with currentIndex: navigationShell.currentIndex, onTap: navigationShell.goBranch"
      pattern: "goBranch"
    - from: lib/features/map/presentation/widgets/settings_glass_button.dart
      to: /settings route
      via: "context.go('/settings')"
      pattern: "context.go('/settings')"
---

<objective>
Replace `PlaceholderHomeScreen` with a `StatefulShellRoute.indexedStack` covering three tabs (Map / Trips / Regions), wire the glass bottom pill to drive the shell, and add a `/settings` route reachable from the top-left glass button. Splash + onboarding remain untouched.

Purpose: Satisfies UI-02 (bottom nav pill wired), FND-09-forward (typed navigation into sub-screens). Preserves the Phase 1 onboarding gating (still handled inside SplashScreen).
Output: A production router that Phase 3+ can extend without further refactoring.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/02-map-glass-shell/02-CONTEXT.md
@.planning/phases/02-map-glass-shell/02-RESEARCH.md
@lib/core/routing/app_router.dart
@lib/features/map/presentation/map_screen.dart
@lib/features/onboarding/presentation/splash_screen.dart
@lib/features/onboarding/presentation/onboarding_screen.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: Create placeholder screens (Trips, Regions, Settings)</name>
  <files>
    - lib/features/trips/presentation/trips_screen.dart
    - lib/features/regions/presentation/regions_screen.dart
    - lib/features/settings/presentation/settings_screen.dart
  </files>
  <action>
    Each is a `StatelessWidget` with a `Scaffold` and centered placeholder text. Use `AppBar` with the screen name for Settings (this is not the map screen, UI-06 doesn't apply). For Trips + Regions, still NO AppBar — they render inside the map's shell, so the map's chrome (focus pill etc.) provides the visual language. Actually they'll be nested inside `MapScreen`'s Stack in the shell — so they should have transparent Scaffold and just show their content over the map for Phase 2.

    Design decision: **Trips + Regions placeholders replace the map when their tab is active** (indexedStack). They should therefore have their own opaque background — not just floating over the map. This is why they use `Scaffold(body: Center(...))` normally. Confirm this in `MapScreen` when passing `navigationShell` — the shell replaces the map surface for tab index > 0.

    Sketch for Trips:
    ```dart
    import 'package:flutter/material.dart';

    class TripsScreen extends StatelessWidget {
      const TripsScreen({super.key});
      @override
      Widget build(BuildContext context) {
        return const Scaffold(
          body: Center(
            child: Text(
              'Trips inbox comes in Phase 6.',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
    }
    ```

    Regions: identical structure, text `'Regions browser comes in Phase 8.'`.

    Settings: has an AppBar (`AppBar(title: Text('Settings'))`) plus a placeholder body: `'Settings comes in Phase 10.'`. Settings is a plain top-level route, not inside the shell.
  </action>
  <verify>
    ```
    flutter analyze lib/features/trips/ lib/features/regions/ lib/features/settings/
    ```
    Zero issues.
  </verify>
  <done>
    - Three stub screens compile.
    - Trips + Regions use a plain Scaffold (opaque background, no AppBar).
    - Settings has an AppBar.
  </done>
</task>

<task type="auto">
  <name>Task 2: Refactor app_router.dart with StatefulShellRoute + /settings</name>
  <files>
    - lib/core/routing/app_router.dart
  </files>
  <action>
    Rewrite the router. Preserve:
    - Splash at `/splash` (initial location).
    - Onboarding at `/onboarding`.
    - Onboarding gating logic lives in `SplashScreen` (per STATE.md Plan 01-03 decision).

    Add:
    - `StatefulShellRoute.indexedStack` for the three tab branches.
    - `/settings` as a plain top-level route (not inside the shell).

    ```dart
    import 'package:auto_explore/features/map/presentation/map_screen.dart';
    import 'package:auto_explore/features/onboarding/presentation/onboarding_screen.dart';
    import 'package:auto_explore/features/onboarding/presentation/splash_screen.dart';
    import 'package:auto_explore/features/regions/presentation/regions_screen.dart';
    import 'package:auto_explore/features/settings/presentation/settings_screen.dart';
    import 'package:auto_explore/features/trips/presentation/trips_screen.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:go_router/go_router.dart';

    /// Top-level GoRouter.
    ///
    /// Onboarding gating stays inside SplashScreen (see Plan 01-03).
    /// Phase 2 replaces the placeholder home route with a
    /// StatefulShellRoute.indexedStack so tab-switching preserves per-tab
    /// state.
    ///
    /// The shell branches are:
    ///   0: '/'         → MapScreen (base map + glass chrome)
    ///   1: '/trips'    → TripsScreen (stub, Phase 6)
    ///   2: '/regions'  → RegionsScreen (stub, Phase 8)
    ///
    /// '/settings' is a separate top-level route reachable from the
    /// top-left glass button on MapScreen. It is intentionally NOT a
    /// shell branch (per 02-CONTEXT.md — Settings is out of the pill).
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
            builder: (context, state) => const SettingsScreen(),
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

    /// Sentinel used by the Map branch. `MapScreen` is the shell BUILDER
    /// itself (owns the base map + chrome); when the Map tab is active,
    /// the branch content is empty — the map is what's already visible.
    class _MapTabContent extends StatelessWidget {
      const _MapTabContent();
      @override
      Widget build(BuildContext context) => const SizedBox.shrink();
    }
    ```

    Important design point: `MapScreen` is both the shell builder AND owns the map render. When the user is on the Map tab (`currentIndex == 0`), `navigationShell` renders an empty `_MapTabContent` (the map itself is already visible in the Stack). When the user is on Trips or Regions (`currentIndex > 0`), `navigationShell` renders `TripsScreen` or `RegionsScreen` — those Scaffolds have opaque backgrounds that visually replace the map. Confirm this in Task 3.

    Preserved: no `redirect:` on the router — onboarding gating stays in SplashScreen (Phase 1 decision).
  </action>
  <verify>
    ```
    flutter analyze lib/core/routing/
    ```
    Zero issues.
  </verify>
  <done>
    - `app_router.dart` uses `StatefulShellRoute.indexedStack` with 3 branches.
    - `/settings` exists as a top-level route.
    - No `PlaceholderHomeScreen` import remaining.
  </done>
</task>

<task type="auto">
  <name>Task 3: MapScreen consumes navigationShell + wire settings button</name>
  <files>
    - lib/features/map/presentation/map_screen.dart
    - lib/features/map/presentation/widgets/settings_glass_button.dart
  </files>
  <action>
    1. Refactor `MapScreen` (from 02-05) to accept `StatefulNavigationShell? navigationShell`. Behavior:
       - If `navigationShell == null` (defensive — used only in isolated widget tests): use the local self-managed `_LocalBottomNav` from 02-05.
       - If `navigationShell != null`:
         - `BottomNavShell(currentIndex: navigationShell.currentIndex, onTap: navigationShell.goBranch)` at the bottom.
         - The Stack overlays include:
           - Base MapWidget (always visible, so the map is behind Trips/Regions when transitioning — this is fine per indexedStack semantics; the Trips/Regions Scaffolds have opaque backgrounds that mask the map).
           - `navigationShell` widget centered in the body area (this will render `_MapTabContent()` → empty when Map tab active, or the real screen when Trips/Regions active).
           - Chrome overlays (focus pill, settings button) ONLY when `currentIndex == 0` — hide them on Trips/Regions.
           - FAB + recenter also hidden on non-map tabs.

       Sketch:
       ```dart
       class MapScreen extends ConsumerWidget {
         const MapScreen({super.key, this.navigationShell});
         final StatefulNavigationShell? navigationShell;

         @override
         Widget build(BuildContext context, WidgetRef ref) {
           final currentIndex = navigationShell?.currentIndex ?? 0;
           final isMapTab = currentIndex == 0;

           return Scaffold(
             body: Stack(
               children: [
                 const Positioned.fill(child: MapWidget()),
                 // Non-map tabs render their content over the map.
                 if (navigationShell != null && !isMapTab)
                   Positioned.fill(child: navigationShell!),

                 // Chrome only on map tab.
                 if (isMapTab) ...[
                   const Positioned(
                     top: 44, left: 16,
                     child: SafeArea(child: SettingsGlassButton()),
                   ),
                   const Positioned(
                     top: 44, left: 0, right: 0,
                     child: SafeArea(child: Center(child: FocusAreaPill())),
                   ),
                   const Positioned(
                     right: 16, bottom: 110,
                     child: RecenterButton(),
                   ),
                   const Positioned(
                     right: 16, bottom: 40,
                     child: TripFab(),
                   ),
                 ],

                 // Bottom nav pill always visible.
                 Positioned(
                   left: 16, right: 16, bottom: 16,
                   child: navigationShell != null
                       ? BottomNavShell(
                           currentIndex: currentIndex,
                           onTap: navigationShell!.goBranch,
                         )
                       : const _LocalBottomNav(),
                 ),
               ],
             ),
           );
         }
       }
       ```

    2. Update `settings_glass_button.dart`: replace the SnackBar stub with `context.go('/settings')`. Wrap navigation in a `try` that no-ops if the route isn't registered (defensive for the local widget test).

    Alternative: pass a `VoidCallback? onTap` to `SettingsGlassButton` and let the caller decide; router-agnostic. Prefer this — more testable. Update `MapScreen` chrome slot to pass `onTap: () => context.go('/settings')`.
  </action>
  <verify>
    ```
    flutter analyze lib/features/map/
    ```
    Zero issues.
  </verify>
  <done>
    - `MapScreen` consumes `navigationShell?.currentIndex` and `goBranch`.
    - Chrome hidden on non-map tabs.
    - Settings button navigates to `/settings`.
  </done>
</task>

<task type="auto">
  <name>Task 4: Widget test — full router shell flow + update root widget_test.dart</name>
  <files>
    - test/features/map/router_shell_test.dart
    - test/widget_test.dart
  </files>
  <action>
    1. Update `test/widget_test.dart` — the existing test asserts "First launch → onboarding". Keep that assertion. Add a follow-up flow: after tapping Continue on onboarding, assert `MapScreen` (or `FocusAreaPill` or `BottomNavShell`) is present. Since MapScreen uses MapLibre, prefer asserting on `BottomNavShell` presence (Dart-only widget, no platform channel).

    2. Create `test/features/map/router_shell_test.dart`:
       - Set onboarding_done = true in InMemorySharedPreferencesAsync.
       - Pump `App`.
       - `pumpAndSettle` to skip splash.
       - Expect `FocusAreaPill` visible AND `BottomNavShell` visible.
       - Tap the "Trips" tab within `BottomNavShell` → `pumpAndSettle` → expect `TripsScreen` text 'Trips inbox comes in Phase 6.' visible AND `FocusAreaPill` NOT visible (chrome hidden on non-map tabs).
       - Tap the "Map" tab → `FocusAreaPill` visible again, `TripsScreen` text NOT visible.
       - Tap the settings button → `pumpAndSettle` → expect `Text('Settings comes in Phase 10.')` visible.

    If MapLibre platform channel errors break the test, either:
    (a) Register a mock channel handler returning `null` for `plugins.flutter.io/maplibre_gl_*` at test setup, OR
    (b) Introduce a small `mapWidgetBuilder` override (a top-level `Widget Function(BuildContext)?` in `MapWidget`) that tests override with a plain `Container()`.

    Prefer (a) — no production code change.
  </action>
  <verify>
    ```
    flutter test test/features/map/router_shell_test.dart
    flutter test test/widget_test.dart
    flutter test    # full suite
    ```
    All green.
  </verify>
  <done>
    - `test/widget_test.dart` asserts onboarding-first then map screen after Continue.
    - `router_shell_test.dart` asserts tab-switching and settings navigation.
    - Full test suite green.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` → 0 issues
- `flutter test` → all pre-existing + new tests green
- Manual (checked in 02-07 real-device verification): install debug build, complete onboarding, arrive on Map tab, tap through Trips → Regions → Map, tap top-left gear → land on Settings, back-button returns.
</verification>

<success_criteria>
- FND-09 (typed navigation) satisfied for Phase 2 tabs.
- UI-02 wired end-to-end (glass pill drives StatefulNavigationShell).
- CONTEXT.md constraint honored: Settings NOT in the pill; Settings reachable from top-left glass button.
- Chrome (focus pill, settings button, FAB, recenter) is hidden on non-map tabs.
- Onboarding gating in SplashScreen remains the source of truth (no router redirect added).
</success_criteria>

<deviations>
(Executor logs. Examples: whether `_MapTabContent` sentinel worked as expected or a different pattern was needed; whether widget test needed a platform-channel mock; whether SafeArea placement needed adjustment on notched devices.)
</deviations>

<output>
After completion, create `.planning/phases/02-map-glass-shell/02-06-SUMMARY.md`:
- Frontmatter: `subsystem: routing`, `affects: [02-07, phase-3, phase-6, phase-8, phase-10]`, `requires: [02-05]`
- Notes: `_MapTabContent` sentinel rationale (kept explicit to avoid confusion in Phase 3+); documented behavior of chrome hiding on non-map tabs.
</output>
