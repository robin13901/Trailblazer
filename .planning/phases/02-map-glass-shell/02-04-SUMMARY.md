---
phase: 02-map-glass-shell
plan: "02-04"
subsystem: theming
tags: [dark-mode, map-style, brightness, riverpod, animated-opacity, material-theme]

# Dependency graph
requires:
  - phase: 02-02
    provides: "map_style_light.json + map_style_dark.json assets; MapWidget ConsumerStatefulWidget"
  - phase: 02-03
    provides: "mapControllerProvider; MapWidget with WidgetsBindingObserver base pattern"

provides:
  - AppTheme.light + AppTheme.dark matching map palette colors
  - MaterialApp.router with ThemeMode.system (Flutter chrome follows OS brightness)
  - mapStyleAssetProvider (NotifierProvider<String>): brightness-derived style path
  - assetForBrightness() public helper for tests
  - MapStyleFade stateless widget: 180ms AnimatedOpacity crossfade
  - MapWidget extended with WidgetsBindingObserver: brightness-triggered setStyle + fade

affects: [02-05, 02-07]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "mapStyleAssetProvider as single source of truth for active style: widget builds read
       ref.watch(mapStyleAssetProvider); WidgetsBindingObserver writes via notifier"
    - "_FixedMapStyleNotifier: test stub that overrides mapStyleAssetProvider with a fixed
       asset path — preserves test determinism regardless of test-runner brightness"
    - "unawaited() wrapper on Future-returning calls in void override methods
       (didChangePlatformBrightness) to satisfy discarded_futures lint"
    - "Required named constructor params before optional (key) per
       always_put_required_named_parameters_first lint"

key-files:
  created:
    - lib/core/theme/app_theme.dart
    - lib/features/map/presentation/providers/map_style_provider.dart
    - lib/features/map/presentation/widgets/map_style_fade.dart
    - test/features/map/map_style_provider_test.dart
  modified:
    - lib/app.dart (theme + darkTheme + ThemeMode.system added)
    - lib/features/map/presentation/widgets/map_widget.dart (WidgetsBindingObserver +
      _swapStyleWithFade + MapStyleFade wrapper + styleAsset param removed)
    - test/features/map/map_widget_test.dart (styleOverride pattern +
      _FixedMapStyleNotifier stub)

key-decisions:
  - "MapWidget.styleAsset constructor param removed — mapStyleAssetProvider is the
     single source of truth; passing a fixed style in tests uses ProviderScope overrides"
  - "themeMode: ThemeMode.system is the default in MaterialApp so the arg is omitted
     per avoid_redundant_argument_values; the behavior (system following) is documented
     in app.dart comment"
  - "brightness: Brightness.light omitted from ColorScheme.fromSeed light theme —
     it is the default; dark theme retains brightness: Brightness.dark (non-default)"
  - "fade duration: 180ms easeInOut — matches the MapStyleFade.duration constant;
     the delay before setStyle() also uses 180ms to let the fade-out complete before
     the native map begins the reload"
  - "onStyleLoadedCallback used as fade-back-in trigger (not a fixed timer) per
     plan must_have; this ensures the map is fully painted before becoming visible again"

patterns-established:
  - "_FixedMapStyleNotifier extends MapStyleAssetNotifier: override build() to return a
     fixed string; inject via mapStyleAssetProvider.overrideWith in pumpMapWidget helper"
  - "Provider-driven styleString pattern: MapLibreMap.styleString always reads from
     the Riverpod provider; the widget never caches style state locally"

# Metrics
duration: ~6min
completed: 2026-07-03
---

# Phase 2 Plan 04: Dark-Mode Style Switching Summary

**System-brightness-driven map style switching with 180 ms opacity crossfade; Flutter chrome follows ThemeMode.system; all wired via mapStyleAssetProvider as the single source of truth.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-07-03T13:55Z
- **Completed:** 2026-07-03T14:01Z
- **Tasks:** 3/3
- **Files modified/created:** 7 files (4 new + 3 modified)

## Accomplishments

- **`AppTheme`** at `lib/core/theme/app_theme.dart`: `AppTheme.light` (warm off-white `#F2F1EF` surface, Trailblazer accent blue seed) and `AppTheme.dark` (deep navy `#0A1728` surface). Colors mirror the map palette assets for visual consistency across the full UI.
- **`MaterialApp.router`** updated in `lib/app.dart`: `theme: AppTheme.light` + `darkTheme: AppTheme.dark`. `ThemeMode.system` is the default so the redundant arg is omitted per lint — the intent is documented in a comment.
- **`mapStyleAssetProvider`** at `lib/features/map/presentation/providers/map_style_provider.dart`: `NotifierProvider<MapStyleAssetNotifier, String>`. Initializes from `PlatformDispatcher.instance.platformBrightness`. `assetForBrightness()` public helper enables test assertions without constructing the container. `updateFromBrightness(Brightness)` called by `MapWidget`.
- **`MapStyleFade`** at `lib/features/map/presentation/widgets/map_style_fade.dart`: stateless `AnimatedOpacity` wrapper. Required params before `key` (lint). 180 ms `Curves.easeInOut`.
- **`MapWidget` extended** with `WidgetsBindingObserver`:
  - `initState` registers observer; `dispose` removes it and clears controller.
  - `didChangePlatformBrightness` calls `unawaited(_swapStyleWithFade(brightness))`.
  - `_swapStyleWithFade`: fade out → 180 ms delay → `updateFromBrightness` → `controller.setStyle()` → `_onStyleLoaded` fades back in.
  - `styleString` reads `ref.watch(mapStyleAssetProvider)` — no local style state.
  - `MapLibreMap` wrapped in `MapStyleFade(visible: _styleVisible)`.
  - Phase 7 comment embedded: programmatic sources must be re-added in `_onStyleLoaded`.
- **`MapWidget.styleAsset` param removed** (was unused). `mapStyleAssetProvider` is the canonical style authority.
- **Tests**: 5 new `map_style_provider_test.dart` (2 `assetForBrightness` + 3 container tests). `map_widget_test.dart` updated: `_FixedMapStyleNotifier` stub + `styleOverride` param on `pumpMapWidget`. All 40 project tests green.

## Task Commits

1. **Task 1: AppTheme + MaterialApp ThemeMode.system** — `833684d` (feat)
   - `lib/core/theme/app_theme.dart` (new), `lib/app.dart` (modified)
2. **Task 2: mapStyleAssetProvider + assetForBrightness** — `cdd09bf` (feat)
   - `lib/features/map/presentation/providers/map_style_provider.dart` (new)
   - `test/features/map/map_style_provider_test.dart` (new)
3. **Task 3: MapWidget brightness observer + MapStyleFade crossfade** — `f7ab7f4` (feat)
   - `lib/features/map/presentation/widgets/map_style_fade.dart` (new)
   - `lib/features/map/presentation/widgets/map_widget.dart` (modified)
   - `test/features/map/map_widget_test.dart` (modified)

## Files Created/Modified

- `lib/core/theme/app_theme.dart` — new; `AppTheme.light` + `AppTheme.dark`
- `lib/app.dart` — `theme:` + `darkTheme:` added; `ThemeMode.system` (default, no arg)
- `lib/features/map/presentation/providers/map_style_provider.dart` — new notifier + helper
- `lib/features/map/presentation/widgets/map_style_fade.dart` — new fade helper
- `lib/features/map/presentation/widgets/map_widget.dart` — brightness observer + fade wired
- `test/features/map/map_style_provider_test.dart` — 5 new unit tests
- `test/features/map/map_widget_test.dart` — updated for provider-based style testing

## Decisions Made

- **`MapWidget.styleAsset` removed.** The constructor param served as a test-time initial value but is now superseded by `mapStyleAssetProvider`. Tests that need a specific style use `mapStyleAssetProvider.overrideWith` via `ProviderScope.overrides` — this is cleaner and consistent with how other providers are tested in the project.
- **Fade duration: 180 ms.** Matches the crossfade time in `MapStyleFade`. The delay before `setStyle()` also uses 180 ms to let the opacity animation complete before the native map reloads (which would cause a brief blank on Impeller if the map is still visible).
- **`onStyleLoadedCallback` as fade-back-in trigger.** Not a timer. The native map fires this callback once the new style + tiles are ready to render, so the map is guaranteed painted before it becomes visible. This satisfies the plan's `must_have` for no white flash.
- **`themeMode: ThemeMode.system` arg omitted.** `ThemeMode.system` is the `MaterialApp` default; `avoid_redundant_argument_values` fires. The intent (follow OS) is documented in a comment in `app.dart`.
- **`unawaited()` wrapper.** `didChangePlatformBrightness` is a `void` override — cannot be marked `async`. The `discarded_futures` lint requires wrapping fire-and-forget `Future` calls with `unawaited()` from `dart:async`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] `brightness: Brightness.light` redundant in `ColorScheme.fromSeed`**
- **Found during:** Task 1 (`flutter analyze`)
- **Issue:** `avoid_redundant_argument_values` — `fromSeed` defaults to `Brightness.light`; explicitly passing it in the light theme triggers the lint.
- **Fix:** Removed the `brightness:` arg from the light `ColorScheme.fromSeed` call; retained for the dark theme (non-default).
- **Files modified:** `lib/core/theme/app_theme.dart`
- **Committed in:** `833684d`

**2. [Rule 1 — Bug] `themeMode: ThemeMode.system` redundant in `MaterialApp.router`**
- **Found during:** Task 1 (`flutter analyze`)
- **Issue:** `ThemeMode.system` is the `MaterialApp` default; the lint fires.
- **Fix:** Removed the arg. Added inline comment documenting the intent.
- **Files modified:** `lib/app.dart`
- **Committed in:** `833684d`

**3. [Rule 1 — Bug] `comment_references` lint on doc comments in `map_style_provider.dart`**
- **Found during:** Task 2 (`flutter analyze`)
- **Issue:** `comment_references` lint: `[MapWidget]` and `[WidgetsBindingObserver.didChangePlatformBrightness]` in `///` doc comments are not resolvable without importing those types.
- **Fix:** Changed references to backtick-quoted strings in the affected doc comments.
- **Files modified:** `lib/features/map/presentation/providers/map_style_provider.dart`
- **Committed in:** `cdd09bf`

**4. [Rule 1 — Bug] `always_put_required_named_parameters_first` in `MapStyleFade` constructor**
- **Found during:** Task 3 (`flutter analyze`)
- **Issue:** Constructor had `super.key` before `required this.visible` and `required this.child`.
- **Fix:** Reordered constructor params: `required this.visible`, `required this.child`, then `super.key`.
- **Files modified:** `lib/features/map/presentation/widgets/map_style_fade.dart`
- **Committed in:** `f7ab7f4`

**5. [Rule 1 — Bug] `discarded_futures` in `didChangePlatformBrightness`**
- **Found during:** Task 3 (`flutter analyze`)
- **Issue:** `_swapStyleWithFade(newBrightness)` returns `Future<void>` but `didChangePlatformBrightness` is a `void` override; lint fires.
- **Fix:** Added `unawaited()` wrapper from `dart:async` import.
- **Files modified:** `lib/features/map/presentation/widgets/map_widget.dart`
- **Committed in:** `f7ab7f4`

**6. [Rule 1 — Bug] `comment_references` for `onStyleLoadedCallback` in `map_widget.dart`**
- **Found during:** Task 3 (`flutter analyze`)
- **Issue:** `[onStyleLoadedCallback]` in doc comment — MapLibreMap member not imported at doc scope.
- **Fix:** Changed to backtick-quoted string `onStyleLoadedCallback`.
- **Files modified:** `lib/features/map/presentation/widgets/map_widget.dart`
- **Committed in:** `f7ab7f4`

**7. [Rule 1 — Bug] `map_widget_test.dart` removed `styleAsset` param reference**
- **Found during:** Task 3 (first `flutter test` run — compilation error)
- **Issue:** Test used `MapWidget(styleAsset: 'assets/map_style_dark.json')` which no longer compiles after the constructor param was removed.
- **Fix:** Updated `pumpMapWidget` to accept `styleOverride` + `_FixedMapStyleNotifier` stub; renamed two test descriptions to match provider-driven behavior.
- **Files modified:** `test/features/map/map_widget_test.dart`
- **Committed in:** `f7ab7f4`

---

**Total deviations:** 7 auto-fixed (all lint/bug/compilation category)
**Impact on plan:** All auto-fixes required for clean analyzer and compilable tests. No scope changes. Provider-driven style approach is cleaner than the `styleAsset` param — the deviation improves testability.

## Verification

- `flutter analyze` — 0 issues (full project, 3.5s)
- `flutter test` — 40/40 green (5 new `map_style_provider_test.dart` + 8 updated `map_widget_test.dart`)
- Manual (deferred to 02-07): change system theme in device Settings while map is open → observe crossfade + palette change with no abrupt reload / no visible white flash.

## Notes on setStyle Timing

`MapLibreMapController.setStyle()` is fire-and-forget from Dart's perspective. The `onStyleLoadedCallback` fires asynchronously on the native side after the new style + tiles are committed to the render tree. The fade-back-in in `_onStyleLoaded` therefore guarantees the map is fully painted before it becomes visible — no timer approximation needed. On real hardware, `setStyle` with a bundled PMTiles asset typically completes in 100–300 ms; the 180 ms fade is a natural dead-time while the reload runs.

## Next Phase Readiness

- **02-05 (Glass shell):** `MapWidget` is fully provider-driven for style and location. The `LiquidGlassSettings.instance.platformSupportsBlurOverMap` flag is unchanged; 02-05 reads it for the glass chrome conditional.
- **02-07 (End-to-end device test):** Verify dark-mode crossfade on Android (SM S921B) by toggling system brightness while the map screen is open. Pitfall 4 comment (`_onStyleLoaded` must re-add programmatic sources) is in the code for Phase 7 reference.

---

*Phase: 02-map-glass-shell*
*Completed: 2026-07-03*
