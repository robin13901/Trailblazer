---
plan: "02-06"
title: "Router refactor — StatefulShellRoute with 3 tabs + Settings stub"
phase: "02-map-glass-shell"
subsystem: routing
status: complete
completed: "2026-07-03"
duration: "11 min"
tags: [go_router, StatefulShellRoute, routing, navigation, shell, settings]

dependency-graph:
  requires: ["02-05"]
  provides:
    - "StatefulShellRoute.indexedStack with 3 branches (/, /trips, /regions)"
    - "/settings top-level route pushed on top of shell"
    - "MapScreen consumes StatefulNavigationShell (currentIndex + goBranch)"
    - "SettingsGlassButton wired to context.push('/settings')"
    - "Chrome (focus pill, FAB, settings button) hidden on non-map tabs"
  affects: ["02-07", "phase-3", "phase-6", "phase-8", "phase-10"]

tech-stack:
  added: []
  patterns:
    - "_MapTabContent sentinel widget for the map branch (explicit empty widget, named for Phase 3+ clarity)"
    - "context.push('/settings') not context.go — preserves shell state and avoids MapWidget dispose-while-building"
    - "navigationShell null-guard in MapScreen for isolated widget tests (_LocalBottomNav fallback)"
    - "onTap: null on SettingsGlassButton when navigationShell is null (no-op, no crash)"

file-tracking:
  created:
    - lib/features/trips/presentation/trips_screen.dart
    - lib/features/regions/presentation/regions_screen.dart
    - lib/features/settings/presentation/settings_screen.dart
    - test/features/map/router_shell_test.dart
  modified:
    - lib/core/routing/app_router.dart
    - lib/features/map/presentation/map_screen.dart
    - lib/features/map/presentation/widgets/settings_glass_button.dart
    - test/features/map/glass_shell_layout_test.dart
    - test/core/routing/app_router_test.dart
    - test/widget_test.dart

decisions:
  - id: "D-02-06-01"
    decision: "context.push('/settings') instead of context.go('/settings')"
    rationale: "context.go() replaces the entire navigation stack, which unmounts MapWidget mid-frame and triggers a Riverpod 'modify provider during tree build' assertion from MapControllerNotifier.dispose(). context.push() overlays /settings on top of the shell, keeping MapWidget alive."
    alternatives: ["context.go('/settings') — tested, causes Riverpod assertion error on dispose", "defer provider reset in dispose with scheduleMicrotask — more complex, push is simpler"]
    impact: "Back button on SettingsScreen returns to MapScreen at same tab. Shell state (e.g. Trips tab previously selected) is preserved."

  - id: "D-02-06-02"
    decision: "_MapTabContent sentinel for the Map branch"
    rationale: "MapScreen is both the shell BUILDER and owns the map render. When the Map tab is active, the branch content must be an empty widget — the map is already rendered by the builder itself. Using an explicit named class (_MapTabContent) rather than SizedBox.shrink() directly makes the intent clear for Phase 3+ maintainers who will add sub-routes under '/'."
    impact: "Phase 3 sub-routes (e.g. '/trip/:id') should be added as child routes inside the Map branch."

  - id: "D-02-06-03"
    decision: "SettingsGlassButton takes VoidCallback? onTap (not context.go internally)"
    rationale: "Router-agnostic widget stays testable standalone. MapScreen passes the callback; tests pass null or a spy. Plan 02-05's SnackBar stub removed."
    impact: "Widget is now stateless-pure. Tests that asserted the SnackBar updated to assert button renders without crashing when onTap is null."

  - id: "D-02-06-04"
    decision: "Chrome hidden on non-map tabs (FocusAreaPill, SettingsGlassButton, TripFab)"
    rationale: "When Trips or Regions screens are active, those Scaffolds fill the viewport. Chrome overlays are map-context-specific and would float over the wrong content."
    impact: "Phase 6 (TripsScreen) and Phase 8 (RegionsScreen) own their full viewport when active. If those screens need their own chrome they must implement it themselves."

metrics:
  tasks-completed: 4
  tests-added: 10
  tests-total: 63
  analyze-final: "0 issues"
---

# Phase 2 Plan 06: Router Shell Refactor Summary

**One-liner:** StatefulShellRoute.indexedStack with 3 branches (Map/Trips/Regions), /settings as pushed overlay, glass pill wired to goBranch.

## What Was Built

Replaced `PlaceholderHomeScreen` at `/` with a `StatefulShellRoute.indexedStack` covering three shell branches. `MapScreen` is the shell builder — it owns the base map widget and all glass chrome. Tab switching is driven by `StatefulNavigationShell.currentIndex` + `goBranch(i)` flowing through `BottomNavShell`. Chrome overlays (focus pill, settings button, FAB) are hidden on non-map tabs so `TripsScreen` and `RegionsScreen` can own the full viewport.

`/settings` is a top-level route pushed on top of the shell via `context.push('/settings')` (not `go`) — this preserves `MapWidget` state across the navigation and avoids a Riverpod dispose-while-building assertion.

## Tasks Completed

| Task | Commit | Files |
|------|--------|-------|
| 1: Placeholder screens (Trips, Regions, Settings) | `ba4bcb6` | 3 new screen files |
| 2+3: StatefulShellRoute + MapScreen + SettingsButton | `6c0df3d` | app_router.dart, map_screen.dart, settings_glass_button.dart, glass_shell_layout_test.dart |
| 4: Widget tests — router shell flow | `dfc3c27` | router_shell_test.dart, widget_test.dart, app_router_test.dart |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] context.go('/settings') → context.push('/settings')**

- **Found during:** Task 4 — `router_shell_test.dart` settings navigation test
- **Issue:** `context.go('/settings')` replaces the navigator stack, dismounting `MapWidget` mid-frame. `_MapWidgetState.dispose()` calls `_mapControllerNotifier.controller = null` during `BuildOwner.finalizeTree()`, triggering Riverpod assertion: "Tried to modify a provider while the widget tree was building."
- **Fix:** Changed to `context.push('/settings')` — pushes Settings as an overlay, keeping the shell and MapWidget alive. The cached notifier pattern in `_MapWidgetState.dispose()` (from Plan 02-03) is correct; the root cause was the full-stack replacement by `go()`.
- **Files modified:** `lib/features/map/presentation/map_screen.dart`
- **Commit:** `dfc3c27` (map_screen.dart hunk)

**2. [Rule 2 - Missing Critical] SettingsGlassButton onTap: null guard in standalone tests**

- **Found during:** Task 3 — `glass_shell_layout_test.dart` still pumped MapScreen without a GoRouter. With `() => context.go('/settings')` always passed, the button would throw a GoRouter lookup error in tests.
- **Fix:** `MapScreen` guards `onTap: navigationShell != null ? () => context.push('/settings') : null`. When `navigationShell` is null (standalone widget test), the button renders but is a no-op.
- **Files modified:** `lib/features/map/presentation/map_screen.dart`

**3. [Rule 3 - Blocking] glass_shell_layout_test.dart uses old `bottomNav` API**

- **Found during:** Task 2 — full `flutter analyze` showed `undefined_named_parameter` for `bottomNav` in the test.
- **Fix:** Rewrote `pumpMapScreen` to use `const MapScreen()` (no params). Replaced the `injectable bottomNav param` test with a `_LocalBottomNav fallback` test. Replaced the SnackBar assertion for SettingsGlassButton with a no-crash assertion (button now has `onTap: null` in standalone mode).
- **Files modified:** `test/features/map/glass_shell_layout_test.dart`

**4. [Rule 3 - Blocking] app_router_test.dart assertions referenced PlaceholderHomeScreen text**

- **Found during:** Task 4 — both tests asserted `find.text('Trailblazer')` which was the `PlaceholderHomeScreen` body. Now the map shell has no such Text widget.
- **Fix:** Added `FakeMapLibrePlatform` setup to `app_router_test.dart`. Updated home-screen assertions from `find.text('Trailblazer')` to `find.byType(BottomNavShell)`.
- **Files modified:** `test/core/routing/app_router_test.dart`

## Architecture Notes

### _MapTabContent Sentinel

The Map branch of `StatefulShellRoute.indexedStack` uses a named `_MapTabContent` class that returns `SizedBox.shrink()`. This is deliberate:

- `MapScreen` is the shell **builder** — it renders `MapWidget` in its Stack regardless of which tab is active.
- When the Map tab is active, `navigationShell` renders `_MapTabContent` (empty). The map surface is already visible.
- When Trips/Regions are active, `navigationShell` renders `TripsScreen`/`RegionsScreen` which have opaque `Scaffold` backgrounds masking the map.
- The explicit `_MapTabContent` class name signals to Phase 3+ maintainers that child routes under `/` should be added as sub-routes inside the Map branch, not as additional branches.

### Chrome Hiding on Non-Map Tabs

When `currentIndex > 0`, the `isMapTab` guard in `MapScreen.build()` hides:
- `SettingsGlassButton`
- `FocusAreaPill`
- `TripFab`

`BottomNavShell` remains visible on all tabs (always rendered). This is consistent with the 02-CONTEXT.md layout intent — the pill is global navigation, the chrome is map-context-specific.

## Verification

- `flutter analyze` → 0 issues
- `flutter test` → 63/63 passed (10 new tests in router_shell_test.dart)
- Manual (deferred to 02-07): real-device onboarding → Map tab → Trips tab → Regions tab → Settings push → back → map chrome restored

## Next Phase Readiness

Plan 02-07 (verification + G1 documentation) can proceed. The router is production-ready:
- Phase 3 adds GPS recording logic under the Map branch (no router changes needed)
- Phase 6 implements `TripsScreen` (replace placeholder)
- Phase 8 implements `RegionsScreen` (replace placeholder)
- Phase 10 implements `SettingsScreen` (replace placeholder)
