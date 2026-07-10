---
phase: 07-coverage-rendering
plan: 04
subsystem: ui
tags: [maplibre, geojson, dart, flutter, riverpod, data-driven-expressions, coverage-rendering]

# Dependency graph
requires:
  - phase: 07-01
    provides: CoverageColorPreset.forBrightness (fullHex/partialHex), CoverageDatum (fraction/isFull)
  - phase: 07-03
    provides: CoverageWay, CoverageOverlayData (data types for the render bridge)
provides:
  - buildCoverageFeatureCollection: pure GeoJSON FeatureCollection builder from CoverageWays
  - coverageLinePaintExpressions: pure paint-expression builder (lineColor/lineOpacity/lineWidth)
  - CoverageOverlayApplier abstract + MapLibreCoverageOverlayApplier: source+layer lifecycle
  - coverageOverlayApplierProvider: Provider<CoverageOverlayApplier>
affects:
  - 07-06 (map bridge wiring — consumes CoverageOverlayApplier.apply/updateColors)
  - 07-07 (stress harness — uses buildCoverageFeatureCollection on compute isolate)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "data-driven GeoJSON overlay: single source + case/interpolate expressions (Gate G2 resolution)"
    - "pure expression builder extracted for test seam (coverageLinePaintExpressions)"
    - "remove-then-readd idempotent overlay (style-swap safe, RESEARCH Pitfall 1/3)"
    - "full LineLayerProperties in setLayerProperties to avoid skipNulls:false partial wipe (Q3)"
    - "runtime getLayerIds() heuristic for belowLayerId label insertion (Q4)"

key-files:
  created:
    - lib/features/coverage/presentation/coverage_feature_collection.dart
    - lib/features/coverage/presentation/coverage_overlay_layers.dart
    - test/features/coverage/presentation/coverage_feature_collection_test.dart
    - test/features/coverage/presentation/coverage_overlay_layers_test.dart
  modified: []

key-decisions:
  - "is_full as int 1/0 not bool — ints safer in MapLibre method-channel JSON round-trip"
  - "coverageLinePaintExpressions extracted as pure top-level function (compute-isolate safe + test seam)"
  - "updateColors passes FULL LineLayerProperties (skipNulls:false contract in setLayerProperties)"
  - "_firstSymbolLayerId uses runtime heuristic (label/place/poi) not hardcoded MapTiler names"
  - "opacity constants named (_kFullOpacity, _kPartialOpacityScale, _kPartialOpacityFloor) for golden-corpus tuning"
  - "RESEARCH open-Q3 (setLayerProperties full set) and open-Q4 (belowLayerId heuristic) CLOSED"

patterns-established:
  - "CoverageOverlayApplier abstract + MapLibreCoverageOverlayApplier mirrors TripOverlayApplier pattern"
  - "Provider<T> plain provider with const constructor default — no @Riverpod codegen"
  - "Test files use flutter_test not test package (very_good_analysis: depend_on_referenced_packages)"

# Metrics
duration: 8min
completed: 2026-07-10
---

# Phase 7 Plan 04: Render Overlay Summary

**GeoJSON FeatureCollection builder + data-driven MapLibre line layer (case on is_full/fraction, zoom-interpolated width, runtime label-layer insertion) with full setLayerProperties recolor — RESEARCH open-Q3/Q4 closed**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-10T05:37:42Z
- **Completed:** 2026-07-10T05:46:04Z
- **Tasks:** 3
- **Files modified:** 4 created

## Accomplishments

- `buildCoverageFeatureCollection` pure function: CoverageWays → GeoJSON FeatureCollection with `is_full` (int 1/0), `fraction` (double), `way_id`; degenerate ways dropped; compute()-isolate safe
- `MapLibreCoverageOverlayApplier`: remove-then-readd apply(), full-property updateColors(), runtime `getLayerIds()` for belowLayerId (RESEARCH open-Q4 closed), idempotent remove()
- `coverageLinePaintExpressions()`: pure expression builder extracted as test seam; asserts amber light #FF8C00/#FFCD6B, amber dark #FFA726/#FFD54F, opacity 0.92 / max(0.25, 0.85*fraction), zoom stops z8:2.5→z18:7.0
- RESEARCH open-Q3 closed: full LineLayerProperties passed to setLayerProperties (skipNulls:false safety)
- Gate G2 confirmed: no setFeatureState/promoteId anywhere in coverage feature
- 128/128 coverage suite tests green; 0 flutter analyze issues

## Task Commits

Each task was committed atomically:

1. **Task 1: GeoJSON FeatureCollection builder** - `913fa8c` (feat)
2. **Task 2: CoverageOverlayApplier** - `db51b5b` (feat)
3. **Task 3: Expression-builder tests** - `c2ea7bf` (test)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `lib/features/coverage/presentation/coverage_feature_collection.dart` - Pure GeoJSON builder; buildCoverageFeatureCollection; compute-isolate safe
- `lib/features/coverage/presentation/coverage_overlay_layers.dart` - CoverageOverlayApplier abstract + MapLibreCoverageOverlayApplier + coverageLinePaintExpressions + coverageOverlayApplierProvider
- `test/features/coverage/presentation/coverage_feature_collection_test.dart` - 11 tests: coord order, is_full int, fraction double, degenerate drop, empty input
- `test/features/coverage/presentation/coverage_overlay_layers_test.dart` - 14 tests: color per brightness, opacity floor/scale, zoom stops, provider type

## Decisions Made

- `is_full` stored as int 1/0 (not bool) — ints survive the MapLibre Dart→native JSON→expression round-trip more reliably than booleans
- `coverageLinePaintExpressions()` extracted as a pure top-level function so it can be unit-tested without a controller and run on a compute isolate in the 07-06 stress harness
- `updateColors()` passes the FULL `LineLayerProperties` (including lineWidth + lineJoin + lineCap) — RESEARCH open-Q3: `setLayerProperties` internally calls `toJson(skipNulls: false)` which emits explicit nulls for omitted fields, clearing those native-side properties
- `_firstSymbolLayerId()` uses a runtime heuristic (first layer id containing 'label'/'place'/'poi') because MapTiler dataviz style layer ids are hosted and can change between style versions — hardcoding is brittle
- Opacity tuning constants named: `_kFullOpacity` (0.92), `_kPartialOpacityScale` (0.85), `_kPartialOpacityFloor` (0.25) — explicitly annotated as golden-corpus-tunable

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed `comment_references` lint violations in coverage_overlay_layers.dart**

- **Found during:** Task 2 (flutter analyze run)
- **Issue:** Doc comment `[SymbolName]` references to types not in scope (`TripOverlayApplier`, `setLayerProperties`, `getLayerIds`, `belowLayerId`, `tripOverlayApplierProvider`) caused `comment_references` info violations — treated as fatal by `very_good_analysis`
- **Fix:** Changed out-of-scope `[...]` links to backtick code style (e.g. `setLayerProperties`) or removed the bracket reference where the type is from another file
- **Files modified:** `lib/features/coverage/presentation/coverage_overlay_layers.dart`
- **Verification:** `flutter analyze` clean after fix

**2. [Rule 1 - Bug] Fixed test lint violations in test files**

- **Found during:** Task 3 final analyze
- **Issue:** Tests used `import 'package:test/test.dart'` (not a pubspec dependency); also `no_leading_underscores_for_local_identifiers`, `prefer_int_literals`, `strict_raw_type` violations
- **Fix:** Replaced `test` import with `flutter_test`; renamed local helper functions to drop leading underscores; replaced `1.0` with `1` in const LatLng args; added explicit `List<dynamic>` type arguments
- **Files modified:** Both test files
- **Verification:** `flutter analyze` clean; all 128 tests still pass

---

**Total deviations:** 2 auto-fixed (both Rule 1 - linter violations caught in Ralph Loop)
**Impact on plan:** Zero scope creep — both fixes were analysis-clean requirements. No behavior changes.

## Issues Encountered

None from planned work — Ralph Loop caught all issues on first analyze iteration.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `coverageOverlayApplierProvider` and `buildCoverageFeatureCollection` ready for 07-06 map bridge wiring
- RESEARCH open-Q3 (full setLayerProperties) and open-Q4 (runtime belowLayerId) CLOSED — 07-06 can proceed
- `coverageLinePaintExpressions()` is compute()-ready for 07-07 stress harness
- No blockers

---
*Phase: 07-coverage-rendering*
*Completed: 2026-07-10*
