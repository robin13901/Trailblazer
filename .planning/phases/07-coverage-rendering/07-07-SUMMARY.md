---
phase: 07-coverage-rendering
plan: 07
subsystem: testing
tags: [flutter, coverage, stress-test, maplibre, frame-timing, compute-isolate, debug-tool]

# Dependency graph
requires:
  - phase: 07-04
    provides: buildCoverageFeatureCollection, CoverageOverlayApplier, coverageOverlayApplierProvider
  - phase: 07-03
    provides: CoverageWay, CoverageOverlayData
  - phase: 07-01
    provides: classifyCoverage, CoverageDatum, CoverageColorPreset
affects:
  - 07-device-verification (deferred on-device 50k fps read)
  - 08-regions (stress harness pattern reusable for region coverage)

provides:
  - "syntheticCoverageWays: deterministic Germany-bbox 50k CoverageWay generator (compute-safe)"
  - "buildSyntheticFeatureCollection: compute-isolate GeoJSON FeatureCollection builder (Pitfall 4)"
  - "FrameTimingMeter: rolling P90 frame-time meter with fps + PASS/FAIL gate"
  - "StressCoverageScreen: debug-only screen loading 50k synthetic ways via production applier"
  - "/settings/stress-coverage route (kDebugMode-gated, tree-shaken from release)"
  - "_StressCoverageTile in Settings Developer section"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "compute isolate for heavy Map<String,dynamic> construction (Pitfall 4 guard)"
    - "WidgetsBinding.addTimingsCallback / removeTimingsCallback for P90 frame metrics"
    - "kDebugMode const-gated GoRoute + widget import for tree-shaking from release"
    - "addFrameMs(double) internal seam for testable P90 logic without FrameTiming construction"

key-files:
  created:
    - lib/features/coverage/presentation/stress/synthetic_coverage_generator.dart
    - lib/features/coverage/presentation/stress/frame_timing_meter.dart
    - lib/features/coverage/presentation/stress/stress_coverage_screen.dart
    - test/features/coverage/presentation/stress/synthetic_coverage_generator_test.dart
    - test/features/coverage/presentation/stress/frame_timing_meter_test.dart
  modified:
    - lib/core/routing/app_router.dart
    - lib/features/settings/presentation/settings_screen.dart

key-decisions:
  - "syntheticCoverageWays runs classifyCoverage with realistic way-length estimate so is_full/floor logic is exercised identically to production"
  - "P90 index uses integer arithmetic (len*9~/10) to satisfy prefer_int_literals lint"
  - "addFrameMs(double) internal seam avoids FrameTiming construction in unit tests"
  - "Two-hop design in onStyleLoaded: buildSyntheticFeatureCollection on compute isolate, then syntheticCoverageWays again on UI isolate only for the CoverageOverlayData wrapper (data wrapper is cheap; FeatureCollection is the expensive part)"

patterns-established:
  - "Stress harness pattern: compute isolate for FeatureCollection + production applier in onStyleLoaded for true end-to-end validation"
  - "Debug tile alongside existing diagnostic tile in Settings Developer section"

# Metrics
duration: 16min
completed: 2026-07-10
---

# Phase 7 Plan 07: Stress Harness Summary

**REN-04 stress harness code-complete: debug-only StressCoverageScreen loads 50k synthetic Germany-bbox driven ways via the production CoverageOverlayApplier, measures P90 frame time via WidgetsBinding.addTimingsCallback, and displays fps / PASS-FAIL vs the 33.3ms gate; on-device fps read deferred**

## Performance

- **Duration:** 16 min
- **Started:** 2026-07-10T05:55:02Z
- **Completed:** 2026-07-10T06:11:07Z
- **Tasks:** 3
- **Files modified:** 7 (5 created, 2 modified)

## Accomplishments

- Synthetic 50k coverage generator: deterministic, Germany-bbox, compute-isolate-safe, exercises production classifyCoverage is_full/floor logic
- FrameTimingMeter: rolling 600-frame P90 with fps + REN-04 pass gate; 14 unit tests via addFrameMs seam
- StressCoverageScreen: debug-only ConsumerStatefulWidget with production applier, kDebugMode-gated route, Settings Developer tile; 23 unit tests total

## Task Commits

Each task was committed atomically:

1. **Task 1: Synthetic 50k coverage generator (compute-friendly) + test** - `c4a7fce` (feat)
2. **Task 2: FrameTimingMeter (P90 over rolling window) + test** - `66a96f9` (feat)
3. **Task 3: StressCoverageScreen + debug route + Settings dev entry** - `f9e5784` (feat)

**Plan metadata:** *(docs commit follows)*

## Files Created/Modified

- `lib/features/coverage/presentation/stress/synthetic_coverage_generator.dart` - syntheticCoverageWays, syntheticCoverageWaysArgs, buildSyntheticFeatureCollection (compute isolate)
- `lib/features/coverage/presentation/stress/frame_timing_meter.dart` - FrameTimingMeter class (P90, fps, passes, reset, addTimings, addFrameMs seam)
- `lib/features/coverage/presentation/stress/stress_coverage_screen.dart` - StressCoverageScreen (ConsumerStatefulWidget, production applier, FrameTiming callback, banner overlay)
- `lib/core/routing/app_router.dart` - Added `/settings/stress-coverage` GoRoute inside kDebugMode block; StressCoverageScreen import
- `lib/features/settings/presentation/settings_screen.dart` - Added `_StressCoverageTile` to Developer section
- `test/features/coverage/presentation/stress/synthetic_coverage_generator_test.dart` - 9 tests: count, wayId, bbox, geometry length, determinism, datum fraction
- `test/features/coverage/presentation/stress/frame_timing_meter_test.dart` - 14 tests: empty, P90 tail, passes gate, fps, cap, reset, single-frame edge cases

## Decisions Made

- **Two-hop isolate design:** `buildSyntheticFeatureCollection(50000)` runs generator + FeatureCollection build on a compute isolate (Pitfall 4 — ~25–40 MB JSON off UI thread); then `syntheticCoverageWays()` runs again on UI isolate only to construct the `CoverageOverlayData` wrapper (this second call is cheap — the wrapper allocation is negligible vs JSON serialization).
- **P90 integer arithmetic:** `len * 9 ~/ 10` instead of `(len * 0.9).floor()` — satisfies `prefer_int_literals` lint from `very_good_analysis`.
- **addFrameMs internal seam:** `FrameTiming` constructor is not publicly constructible in tests; the `addFrameMs(double)` seam allows full unit testing of P90/fps/passes/cap without requiring a live rendering pipeline.
- **kDebugMode import pattern:** `StressCoverageScreen` import is unconditional (same as `TrackingDiagnosticsScreen`); the `kDebugMode` const at route definition time is sufficient for tree-shaking; Dart compiler eliminates the route body and its widget reference from release.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

- P90 test assertion needed adjustment: plan description said "100x16.6ms + 10x50ms → p90 reflects the tail" but with 110 total frames, `floor(110*0.9)=99` → sorted[99]=16.6ms (still fast). Corrected to 90x16.6ms + 10x50ms (100 total) → `floor(100*0.9)=90` → sorted[90]=50ms (slow, > 33.3). The meter implementation is correct per spec; only the test count needed adjustment.
- Minor lint fixes during Ralph Loop: removed `0.0` double literals → int literals in test files; removed redundant `seed: 42` default argument values.

## Deferred Manual Checkpoint

**REN-04 on-device 50k fps read (deferred)**

The actual fps measurement requires a physical device running a debug build with MAPTILER_KEY. This was intentionally deferred per project memory (batch drives across phases).

**To execute when ready:**
1. Connect device; run: `flutter run --dart-define-from-file=env/dev.json`
2. Navigate: Settings → Developer → Coverage stress test
3. Map loads 50k synthetic ways via the production overlay
4. Pan/zoom for 10 seconds
5. Read P90 ms and fps from the banner
6. Pass criteria: P90 ≤ 33.3 ms (≥ 30 fps) — screen shows PASS/FAIL automatically

**Expected result:** PASS (MapLibre GL native engine handles 50k GeoJSON features with data-driven expressions entirely GPU-side; Dart-side cost is one-time JSON upload via addGeoJsonSource, not per-frame — per RESEARCH §REN-04).

## User Setup Required

None — no external service configuration required. Map will be blank without `--dart-define-from-file=env/dev.json` (expected for the deferred device test; not required for unit tests).

## Next Phase Readiness

- REN-04 harness code-complete: all 3 tasks done, 23 unit tests green, flutter analyze clean
- Deferred on-device fps read is cataloged above; batched to next device session
- Phase 7 plans complete: 07-01 through 07-07 done (07-06 parallel in same wave)
- Phase 8 (regions) can proceed; stress harness pattern reusable if region coverage needs verification

---
*Phase: 07-coverage-rendering*
*Completed: 2026-07-10*
