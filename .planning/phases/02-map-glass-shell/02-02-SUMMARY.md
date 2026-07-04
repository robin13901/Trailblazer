---
phase: 02-map-glass-shell
plan: "02-02"
subsystem: map-rendering
tags: [maplibre, pmtiles, protomaps, flutter, widget-test, offline-maps]

# Dependency graph
requires:
  - phase: 02-01
    provides: maplibre_gl ^0.26.2 in pubspec; LiquidGlassSettings G1 gate resolved

provides:
  - Bundled dev_berlin.pmtiles (Berlin bbox, 30.8 MB, zoom 0–14) committed to git
  - Two project-owned map style JSON assets (light + dark, Protomaps v4 schema)
  - MapWidget — MapLibreMap wrapper with Phase-2-correct gesture set (tilt off)
  - MapScreen — bare Scaffold host, no AppBar (glass chrome in 02-05)
  - FakeMapLibrePlatform test helper for all future maplibre widget tests

affects: [02-03, 02-04, 02-05, 02-07]

# Tech tracking
tech-stack:
  added:
    - dev_berlin.pmtiles (bundled asset, ~30.8 MB, Protomaps v4 vector tiles)
    - maplibre_gl_platform_interface ^0.26.2 (dev_dependency — needed to subclass
      MapLibrePlatform in tests without depend_on_referenced_packages lint)
  patterns:
    - FakeMapLibrePlatform pattern: swap MapLibrePlatform.createInstance in setUp()
      so MapLibreMap widget tests don't need a real native platform view
    - Style JSON in assets/ referenced via bare asset path string in MapLibreMap.styleString
    - PMTiles source declared in style JSON via "pmtiles://assets/tiles/..." URL —
      NOT added at runtime via controller.addSource() (Pitfall 1 avoided)

key-files:
  created:
    - assets/tiles/dev_berlin.pmtiles
    - assets/tiles/README.md
    - assets/map_style_light.json
    - assets/map_style_dark.json
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/presentation/map_screen.dart
    - test/features/map/map_widget_test.dart
    - test/helpers/fake_maplibre_platform.dart
  modified:
    - pubspec.yaml (assets/tiles/ + both style JSONs registered; maplibre_gl_platform_interface dev_dep added)
    - pubspec.lock

key-decisions:
  - "MapWidget keeps redundant gesture defaults out of code (avoid_redundant_argument_values);
     only tiltGesturesEnabled: false is stated explicitly — all others are MapLibreMap defaults"
  - "FakeMapLibrePlatform stored in test/helpers/ so future map widget tests reuse it
     without copying from pub cache"
  - "maplibre_gl_platform_interface added as dev_dependency to satisfy depend_on_referenced_packages
     lint when subclassing MapLibrePlatform in tests"
  - "MapWidget._controller field removed (unused in Phase 2) to satisfy unused_field lint;
     onMapCreated callback still forwarded via widget.onMapCreated?.call(c)"

patterns-established:
  - "FakeMapLibrePlatform: replace MapLibrePlatform.createInstance in setUp + addTearDown
     — standard pattern for all future maplibre widget tests in this project"
  - "Style asset loaded via styleString: 'assets/map_style_light.json' (bare asset path,
     not asset:// URL) — MapLibreMap docs confirm this is the correct local-asset form"

# Metrics
duration: ~15min
completed: 2026-07-03
---

# Phase 2 Plan 02: PMTiles Base Map Summary

**Bundled Berlin PMTiles offline base map wired into MapWidget — Protomaps v4 light/dark styles, tilt-off gesture config, and FakeMapLibrePlatform test harness all green.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-07-03T15:30Z (continuation — Tasks 1–2 completed by prior executor)
- **Completed:** 2026-07-03T16:00Z (est.)
- **Tasks:** 4/4
- **Files modified/created:** 8 new + 2 modified

## Accomplishments

- `assets/tiles/dev_berlin.pmtiles` (30.8 MB, Protomaps v4, Berlin bbox, zoom 0–14) committed and registered in pubspec assets
- Two project-owned style JSONs (light + dark, Protomaps v4 schema, warm Google-Maps-inspired palette vs deep navy dark) each containing `"pmtiles://assets/tiles/dev_berlin.pmtiles"` source URL
- `MapWidget` wraps `MapLibreMap` with `tiltGesturesEnabled: false` (CONTEXT.md mandate), compass at `topRight`, `myLocationEnabled` omitted (02-03 territory), no `useHybridComposition` override (Pitfall 2 avoided)
- `MapScreen` — bare `Scaffold(body: MapWidget())` with no `AppBar`, ready for glass chrome in 02-05
- 7 new widget tests via `FakeMapLibrePlatform` (replaces platform view with `SizedBox.shrink()`); all 21 project tests green, `flutter analyze` zero issues

## Task Commits

1. **Task 1: Acquire dev_berlin.pmtiles + register assets** — `79c91ef` (feat)
2. **Task 2: Author light + dark map style JSON assets** — `de251db` (feat)
3. **Task 3: Build MapWidget + MapScreen** — `246b56e` (feat)
4. **Task 4: Widget tests** — `55b6761` (test)

## Files Created/Modified

- `assets/tiles/dev_berlin.pmtiles` — Berlin bbox PMTiles v4 archive (~30.8 MB)
- `assets/tiles/README.md` — provenance, bbox, zoom range, regeneration instructions
- `assets/map_style_light.json` — Protomaps v4 light style, Google Maps-inspired warm palette
- `assets/map_style_dark.json` — Protomaps v4 dark style, deep navy
- `lib/features/map/presentation/widgets/map_widget.dart` — Phase-2 MapLibreMap wrapper
- `lib/features/map/presentation/map_screen.dart` — bare Scaffold host
- `test/features/map/map_widget_test.dart` — 7 gesture-config + style tests
- `test/helpers/fake_maplibre_platform.dart` — FakeMapLibrePlatform for all future map tests
- `pubspec.yaml` — assets block + `maplibre_gl_platform_interface` dev_dep
- `pubspec.lock` — updated

## Decisions Made

- **FakeMapLibrePlatform pattern adopted** — replaces `MapLibrePlatform.createInstance` factory in test `setUp()` so MapLibreMap widget tests run in pure-Dart environment without a native PlatformView. Stored in `test/helpers/fake_maplibre_platform.dart` for reuse. `Point<num>` (not `Point<double>`) used for `toScreenLocation`/`toLatLng` overrides — matched to platform interface signature.
- **`maplibre_gl_platform_interface` as dev_dependency** — `FakeMapLibrePlatform` must import from `maplibre_gl_platform_interface` directly (not the re-export-limited `maplibre_gl`). `very_good_analysis` `depend_on_referenced_packages` lint required an explicit declaration. Version locked to `^0.26.2` to match `maplibre_gl 0.26.2`.
- **Redundant gesture defaults omitted** — `rotateGesturesEnabled: true`, `scrollGesturesEnabled: true`, `zoomGesturesEnabled: true`, `compassEnabled: true`, `logoEnabled: false`, `attributionButtonPosition: AttributionButtonPosition.bottomRight` are all `MapLibreMap` constructor defaults; `avoid_redundant_argument_values` lint requires omitting them. Only `tiltGesturesEnabled: false` is stated (the one non-default we care about).
- **`_controller` field removed from `_MapWidgetState`** — unused in Phase 2; storing it triggered `unused_field` + `use_late_for_private_fields_and_variables` lint pair. `onMapCreated` callback still forwarded to the parent widget via `widget.onMapCreated?.call(c)`.
- **`StatefulShellRoute` in doc comment** — replaced with backtick reference to avoid `comment_references` lint (the class is not in scope of `map_screen.dart`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] Redundant argument values removed from MapWidget**
- **Found during:** Task 3 (flutter analyze)
- **Issue:** Plan sketch listed all gesture flags explicitly; `avoid_redundant_argument_values` lint flags arguments that match constructor defaults
- **Fix:** Removed `rotateGesturesEnabled: true`, `scrollGesturesEnabled: true`, `zoomGesturesEnabled: true`, `compassEnabled: true`, `logoEnabled: false`, `attributionButtonPosition: ...bottomRight`; kept only `tiltGesturesEnabled: false`
- **Files modified:** `lib/features/map/presentation/widgets/map_widget.dart`
- **Committed in:** `246b56e`

**2. [Rule 1 — Bug] `_controller` field removed from `_MapWidgetState`**
- **Found during:** Task 3 (flutter analyze)
- **Issue:** Storing `MapLibreMapController?` in state but never reading it triggered `unused_field` + `use_late_for_private_fields_and_variables`
- **Fix:** Removed field; callback forwarded inline
- **Files modified:** `lib/features/map/presentation/widgets/map_widget.dart`
- **Committed in:** `246b56e`

**3. [Rule 1 — Bug] `Point<double>` → `Point<num>` in FakeMapLibrePlatform**
- **Found during:** Task 4 (first `flutter test` run — compilation error)
- **Issue:** `toScreenLocation`, `toScreenLocationBatch`, `toLatLng` override types used `Point<double>` but platform interface declares `Point<num>`
- **Fix:** Changed all three to `Point<num>`
- **Files modified:** `test/helpers/fake_maplibre_platform.dart`
- **Committed in:** `55b6761`

**4. [Rule 2 — Missing Critical] `maplibre_gl_platform_interface` dev_dependency added**
- **Found during:** Task 4 (`flutter analyze` after tests passed)
- **Issue:** `depend_on_referenced_packages` lint: `fake_maplibre_platform.dart` imports `maplibre_gl_platform_interface` which wasn't declared as a dependency
- **Fix:** Added `maplibre_gl_platform_interface: ^0.26.2` to `dev_dependencies` (alphabetically between `integration_test` and `mocktail`); `pubspec.lock` updated
- **Files modified:** `pubspec.yaml`, `pubspec.lock`
- **Committed in:** `55b6761`

**5. [Rule 1 — Bug] `enableInteraction` named param reordered to before optional params**
- **Found during:** Task 4 (`flutter analyze`)
- **Issue:** In the 5 layer-adding methods of `FakeMapLibrePlatform`, `required bool enableInteraction` was at the end of the named param block after optional params, violating `always_put_required_named_parameters_first`
- **Fix:** Moved `required bool enableInteraction` to first position in named block for each of `addSymbolLayer`, `addLineLayer`, `addCircleLayer`, `addFillLayer`, `addFillExtrusionLayer`
- **Files modified:** `test/helpers/fake_maplibre_platform.dart`
- **Committed in:** `55b6761`

---

**Total deviations:** 5 auto-fixed (3 lint/bug, 2 missing-critical)
**Impact on plan:** All auto-fixes required for clean analyzer and correct override signatures. No scope changes.

## Issues Encountered

- **SkSL shader warnings** from `liquid_glass_renderer-0.2.0-dev.4` during `flutter test` (pre-existing since 02-01, not introduced by this plan). These are compile warnings for the Skia backend only; Impeller backend (Android) is unaffected. Tests still pass.
- **PMTiles file size** — the bundled file is ~30.8 MB (upper end of the 5–15 MB plan estimate). This is because the bbox extract at `--maxzoom=14` covers a fairly large Berlin area. Acceptable for dev bundling; production will use a network-downloaded tile archive (Phase 8+).

## Next Phase Readiness

- **02-03 (Location):** `MapWidget` has `myLocationEnabled: false` and `onMapCreated` callback hook — ready to add location layer behind a permission check
- **02-04 (Dark mode):** `MapWidget.styleAsset` parameter is exposed and defaults to light; dark mode switching just needs to pass `'assets/map_style_dark.json'`
- **02-05 (Glass shell):** `MapScreen` has no `AppBar`, `Scaffold.body` is full-screen `MapWidget` — glass overlay widgets can be added as `Stack` children
- **02-07 (End-to-end device test):** Install debug build on SM S921B; open `MapScreen` via temporary route; verify tiles render in airplane mode and LiquidGlass renders correctly over real PMTiles-backed map (G1 re-verify carry-forward from 02-01)

---

## Wave 7 Addendum — Berlin → Germany extract (2026-07-04)

**Trigger:** User's device location is Kleinheubach, Bavaria — far outside the Berlin bbox
(13.088°E, 52.338°N → 13.761°E, 52.677°N). Map rendered empty (only background layer).

**Change:**
- `assets/tiles/dev_berlin.pmtiles` (30 MB) replaced by `assets/tiles/dev_germany.pmtiles`
  (full Germany bbox 5.866,47.270,15.042,55.058, maxzoom 11, 371 MB — fell back from
  maxzoom 14/13 because those extracts were 3.2 GB / 1.8 GB respectively, exceeding the
  500 MB APK bundling budget; maxzoom 11 = 5125 tiles, 371 MB, practical for debug APK).
- `assets/tiles/*.pmtiles` added to `.gitignore` — file is no longer committed.
- `tool/fetch_pmtiles.sh` (bash) + `tool/fetch_pmtiles.ps1` (PowerShell) added; each
  fresh clone must run one of these to fetch the tile asset.
- `TileServer.assetPath` default changed from `'assets/tiles/dev_berlin.pmtiles'` to
  `'assets/tiles/dev_germany.pmtiles'`.
- `assets/tiles/README.md` rewritten to document Germany extract + gitignore policy.

**No code contract changes.** Tests use a fake `TileServer` override — unchanged.

*Addendum added: 2026-07-04*

---

*Phase: 02-map-glass-shell*
*Completed: 2026-07-03*
