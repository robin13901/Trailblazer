---
phase: 02-map-glass-shell
plan: "02-05"
subsystem: ui-shell
tags: [liquid-glass, bottom-nav, fab, glass-pill, glass-circle, chrome, overlay, g1-gate]

# Dependency graph
requires:
  - phase: 02-01
    provides: "LiquidGlassSettings singleton; G1 gate flag (platformBlurEnabled=true); LiquidRoundedSuperellipse.borderRadius is double"
  - phase: 02-02
    provides: "MapWidget ConsumerStatefulWidget; PMTiles assets wired"
  - phase: 02-03
    provides: "mapControllerProvider; RecenterButton; location permission flow"
  - phase: 02-04
    provides: "AppTheme light/dark; mapStyleAssetProvider; MapStyleFade"

provides:
  - GlassPill widget: LiquidGlassLayer+LiquidGlass when G1=true; GlassPillFallback (tinted, no BackdropFilter) when G1=false
  - GlassCircle widget: same G1 branching for circular chrome
  - FocusAreaPill stub: top-center placeholder showing '—' (Phase 8 wires)
  - SettingsGlassButton: top-left GlassCircle(44) + gear icon; tap → SnackBar stub
  - TripFab: bottom-right GlassCircle(60) + record icon; tap → SnackBar stub
  - BottomNavShell: 3-tab glass pill (Map/Trips/Regions); pure widget with currentIndex + onTap API
  - MapScreen extended: Stack with all 5 chrome overlays; injectable bottomNav param for Plan 02-06

affects: [02-06, 02-07]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GlassPillFallback / GlassCircleFallback exposed as public types — widget tests can
       assert the fallback branch is active without private-type reflection"
    - "LiquidGlassLayer wraps LiquidGlass (required by liquid_glass_renderer API) —
       LiquidGlass without a parent LiquidGlassLayer or LiquidGlass.withOwnLayer is incomplete"
    - "BottomNavShell is a pure presentation widget (no state, no providers) — caller owns
       the index; Plan 02-06 injects StatefulNavigationShell via MapScreen.bottomNav param"
    - "SafeArea(child: ...) used at individual overlay sites — not wrapping entire Scaffold —
       allows per-element control of safe-area insets"

key-files:
  created:
    - lib/features/map/presentation/widgets/glass_pill.dart
    - lib/features/map/presentation/widgets/glass_circle.dart
    - lib/features/map/presentation/widgets/focus_area_pill.dart
    - lib/features/map/presentation/widgets/settings_glass_button.dart
    - lib/features/map/presentation/widgets/trip_fab.dart
    - lib/features/map/presentation/widgets/bottom_nav_shell.dart
    - test/features/map/glass_pill_test.dart
    - test/features/map/glass_shell_layout_test.dart
  modified:
    - lib/features/map/presentation/map_screen.dart

key-decisions:
  - "GlassPillFallback + GlassCircleFallback are public types (not private _Fallback*) so
     widget tests can locate them via find.byType() without relying on private class names"
  - "LiquidGlass must be wrapped in LiquidGlassLayer — confirmed from reading pub-cache source;
     the plan sketch suggested standalone LiquidGlass but the API requires a parent layer"
  - "MapScreen.bottomNav: optional Widget? param allows Plan 02-06 to inject a
     StatefulNavigationShell-driven pill; _LocalBottomNav handles standalone operation"
  - "SettingsGlassButton stub: SnackBar 'Settings coming in Phase 10' (matches TripFab pattern;
     avoids a premature go_router dependency before /settings route exists in 02-06)"
  - "RecenterButton stays inside MapWidget — it is tightly coupled to mapControllerProvider
     and cameraStateProvider; duplicating it in MapScreen's Stack would create two instances"
  - "avoid_redundant_argument_values lint: SafeArea(bottom: true) → SafeArea() since bottom
     defaults to true; detected by flutter analyze and auto-fixed"

patterns-established:
  - "G1 branch confirmed via widget test: glass_pill_test.dart verifies both paths + both
     brightnesses in isolation (no MapWidget needed)"
  - "BottomNavShell accepts currentIndex + onTap (not a Riverpod provider) — this is the
     established pattern for shell widgets that Plan 02-06 wires to StatefulNavigationShell"

# Metrics
duration: ~7min
completed: 2026-07-03
---

# Phase 2 Plan 05: Liquid Glass Shell Summary

**Liquid Glass chrome shell built: GlassPill + GlassCircle primitives, five overlay widgets, MapScreen Stack composition, 18 new tests; G1 branch behavior confirmed via widget tests; BottomNavShell accepts `currentIndex + onTap` for Plan 02-06 injection.**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-07-03T14:05Z
- **Completed:** 2026-07-03T14:12Z
- **Tasks:** 3/3
- **Files created:** 8 new; 1 modified

## Accomplishments

- **`GlassPill`** at `lib/features/map/presentation/widgets/glass_pill.dart`:
  - `true` branch: `lg.LiquidGlassLayer` (with shared visual params from `LiquidGlassSettings`) wrapping `lg.LiquidGlass` with `lg.LiquidRoundedSuperellipse(borderRadius: double)`.
  - `false` branch: `GlassPillFallback` (public) — tinted `Container` + hairline border; no `BackdropFilter`.
- **`GlassCircle`** at `lib/features/map/presentation/widgets/glass_circle.dart`: same G1 branching, circular shape.
- **`FocusAreaPill`** — `GlassPill` stub showing `'—'`; Semantics label "Focus area (not yet available)". Phase 8 wires.
- **`SettingsGlassButton`** — `GlassCircle(44)` + `Icons.settings_outlined`; tap → SnackBar "Settings coming in Phase 10".
- **`TripFab`** — `GlassCircle(60)` + `Icons.fiber_manual_record`; tap → SnackBar "Trip recording is coming in Phase 3".
- **`BottomNavShell`** — 3-tab glass pill (Map / Trips / Regions); pure presentation widget; `currentIndex + onTap` API; animated selection dot; `SafeArea` + bottom padding.
- **`MapScreen` rewritten** — `ConsumerWidget` with a `Stack`: `MapWidget` (fill) + four chrome overlays + injectable `bottomNav` param. No `AppBar`. `_LocalBottomNav` provides standalone tab state.
- **`glass_pill_test.dart`** — 9 tests: fallback branch (no BackdropFilter, light + dark tint), liquid glass branch (LiquidGlass + LiquidGlassLayer present), for both GlassPill and GlassCircle.
- **`glass_shell_layout_test.dart`** — 9 tests: all chrome widgets present (UI-01..UI-04), no AppBar (UI-06), FAB SnackBar, settings SnackBar, tab switch state, injectable bottomNav.

## Task Commits

1. **Task 1: Base glass primitives — GlassPill + GlassCircle** — `c6b6c4c` (feat)
   - `glass_pill.dart`, `glass_circle.dart`, `test/features/map/glass_pill_test.dart`
2. **Task 2: Chrome widgets** — `09356dc` (feat)
   - `focus_area_pill.dart`, `settings_glass_button.dart`, `trip_fab.dart`, `bottom_nav_shell.dart`
3. **Task 3: MapScreen composition + shell layout test** — `cc5ff1f` (feat)
   - `map_screen.dart` (modified), `test/features/map/glass_shell_layout_test.dart`

## Files Created/Modified

- `lib/features/map/presentation/widgets/glass_pill.dart` — new
- `lib/features/map/presentation/widgets/glass_circle.dart` — new
- `lib/features/map/presentation/widgets/focus_area_pill.dart` — new
- `lib/features/map/presentation/widgets/settings_glass_button.dart` — new
- `lib/features/map/presentation/widgets/trip_fab.dart` — new
- `lib/features/map/presentation/widgets/bottom_nav_shell.dart` — new
- `lib/features/map/presentation/map_screen.dart` — rewritten (Chrome Stack composition)
- `test/features/map/glass_pill_test.dart` — new (9 tests)
- `test/features/map/glass_shell_layout_test.dart` — new (9 tests)

## Decisions Made

- **`GlassPillFallback` and `GlassCircleFallback` are public types.** The plan suggested using private `_FallbackTintedPill`. Exposing them publicly allows `find.byType(GlassPillFallback)` in widget tests without `library_private_types_in_public_api` workarounds. No API surface impact — these are leaf widgets.
- **`LiquidGlass` must be wrapped in `LiquidGlassLayer`.** Confirmed from reading `liquid_glass_renderer-0.2.0-dev.4` pub-cache source. `LiquidGlass` without a parent `LiquidGlassLayer` renders but issues a warning. The spike screen used `LiquidGlassLayer` → replicated exactly.
- **`MapScreen.bottomNav: Widget?`.** Optional injection param lets Plan 02-06 provide the `StatefulNavigationShell`-driven pill without changing `MapScreen`'s API. `_LocalBottomNav` handles standalone testing.
- **`RecenterButton` stays inside `MapWidget`.** It reads `mapControllerProvider` and `cameraStateProvider`; extracting it to the `MapScreen` Stack would require passing those refs up — unnecessary coupling for Phase 2.
- **SnackBar stubs for SettingsGlassButton.** Consistent with `TripFab` pattern; avoids a `go_router` `/settings` dependency before Plan 02-06 adds the route.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] `comment_references` lint on doc comments**
- **Found during:** Task 1 (`flutter analyze`)
- **Issue:** `[lg.LiquidGlass]`, `[lg.LiquidGlassLayer]`, `[TripFab]`, `[GlassPill]` etc. in `///` doc comments — aliased imports and cross-file types are not resolvable in doc-comment scope without additional imports.
- **Fix:** Changed affected references to backtick-quoted strings.
- **Files modified:** `glass_pill.dart`, `glass_circle.dart`
- **Committed in:** `c6b6c4c`

**2. [Rule 1 — Bug] `prefer_const_declarations` on `LiquidGlassSettings.instance`**
- **Found during:** Task 1 (`flutter analyze`)
- **Issue:** `final settings = LiquidGlassSettings.instance` — the field is a `const`; the local binding should be `const`.
- **Fix:** Changed to `const settings = LiquidGlassSettings.instance;` in both files.
- **Files modified:** `glass_pill.dart`, `glass_circle.dart`
- **Committed in:** `c6b6c4c`

**3. [Rule 1 — Bug] `avoid_redundant_argument_values` on `SafeArea(bottom: true)`**
- **Found during:** Task 2 (`flutter analyze`)
- **Issue:** `SafeArea.bottom` defaults to `true`; explicit pass triggers the lint.
- **Fix:** Removed the redundant `bottom: true` arg.
- **Files modified:** `bottom_nav_shell.dart`
- **Committed in:** `09356dc`

**4. [Rule 1 — Bug] `unnecessary_lambdas` on `overrideWith(() => _FakeLocationPermissionNotifier())`**
- **Found during:** Task 3 (`flutter analyze`)
- **Issue:** The lambda wrapping a constructor call is a closure where a tearoff suffices.
- **Fix:** Changed to `overrideWith(_FakeLocationPermissionNotifier.new)`.
- **Files modified:** `test/features/map/glass_shell_layout_test.dart`
- **Committed in:** `cc5ff1f`

---

**Total deviations:** 4 auto-fixed (all lint category). No scope changes. Plan executed exactly as designed.

## Verification

- `flutter analyze` — 0 issues (full project, 13.1s)
- `flutter test` — 58/58 green (18 new: 9 `glass_pill_test.dart` + 9 `glass_shell_layout_test.dart`; all 40 pre-existing tests still pass)
- G1 branch confirmed via widget test: `platformBlurEnabled = true` → `LiquidGlass` in tree; `= false` → `GlassPillFallback` in tree, no `BackdropFilter`
- Manual (deferred to 02-07): install debug build, navigate to `MapScreen`, confirm glass chrome renders on real Android device in both light and dark themes

## Notes on LiquidGlassLayer Wrapping

`LiquidGlass` in `liquid_glass_renderer` 0.2.0-dev.4 requires a parent `LiquidGlassLayer` in the widget tree. Without it, the widget technically renders but the `LiquidGlassRenderScope` may not be present. Each `GlassPill` and `GlassCircle` create their own `LiquidGlassLayer` — this is slightly less efficient than sharing a single layer across all chrome elements (which `LiquidGlass.grouped` + `LiquidGlassBlendGroup` would enable), but it is simpler and correct for Phase 2. If performance profiling in 02-07 shows compositing cost, a single shared `LiquidGlassLayer` at the `MapScreen` level could be introduced.

## Next Phase Readiness

- **02-06 (Router wiring):** `BottomNavShell` accepts `currentIndex + onTap`; `MapScreen.bottomNav` accepts an injectable `Widget?`. Plan 02-06 wraps `MapScreen` in a `StatefulShellRoute`, passes `shell.currentIndex` and `shell.goBranch(i)` via a `BottomNavShell` wrapped widget. No API changes needed on `MapScreen` or `BottomNavShell`.
- **02-07 (End-to-end device test):** Verify glass chrome renders correctly over the real PMTiles MapLibre map on Android (SM S921B) in both light and dark themes. If `LiquidGlass` has compositing issues over the PlatformView, set `platformBlurEnabled = false` and fall back to `GlassPillFallback`.

---

*Phase: 02-map-glass-shell*
*Completed: 2026-07-03*
