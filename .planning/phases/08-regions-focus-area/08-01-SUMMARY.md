---
phase: 08-regions-focus-area
plan: "01"
subsystem: domain
tags: [dart, regions, coverage, zoom, admin-level, value-type, unit-tests]

# Dependency graph
requires:
  - phase: 07-coverage-rendering
    provides: "CoverageDatum, coverage_threshold patterns for percent/clamp math"
provides:
  - "zoomToAdminLevel: zoom double -> OSM admin level int (2/4/6/8/9/10)"
  - "kFallbackLevels + fallbackLevelsFrom: parent-fallback chain for water/no-region"
  - "RegionCoverage: immutable value type with percent/km derivations"
  - "coveragePercent + formatPercent: clamped percent math + one-decimal display"
affects:
  - 08-02-coverage-compute-service
  - 08-03-live-camera-provider
  - 08-04-focus-pill
  - 08-05-region-browser
  - 08-06-region-detail-sheet

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure-Dart domain primitives: no Flutter, no Riverpod, isolate-safe"
    - "coveragePercent clamp pattern: (driven/total*100).clamp(0,100) with totalLengthM<=0 guard"
    - "Object.hash equality on identity fields only (osmId+driven+total, not name/level)"

key-files:
  created:
    - lib/features/regions/domain/zoom_level_mapper.dart
    - lib/features/regions/domain/region_coverage.dart
    - test/features/regions/domain/zoom_level_mapper_test.dart
    - test/features/regions/domain/region_coverage_test.dart
  modified: []

key-decisions:
  - "osmId equality excludes adminLevel and name: two snapshots of the same region at different times are equal if their driven/total lengths match"
  - "kFallbackLevels is a const literal [10,9,8,6,4,2] — no 3/5/7 levels exist in OSM DE"
  - "formatPercent uses toStringAsFixed(1) — consistent one-decimal everywhere per CONTEXT.md"

patterns-established:
  - "Zoom breakpoints: <6->2, <9->4, <11->6, <13->8, <15->9, >=15->10"
  - "Fallback chain always terminates at level 2 (pill never blank)"
  - "RegionCoverage.percent/percentLabel/drivenKm/totalKm are computed getters (not stored)"

# Metrics
duration: 5min
completed: 2026-07-11
---

# Phase 8 Plan 01: Regions Domain Primitives Summary

**Zoom-to-admin-level mapper with 6-band breakpoints + RegionCoverage immutable value type with clamped percent math, 52 unit tests green**

## Performance

- **Duration:** 5 min
- **Started:** 2026-07-11T00:46:18Z
- **Completed:** 2026-07-11T00:51:35Z
- **Tasks:** 2
- **Files created:** 4

## Accomplishments

- `zoomToAdminLevel(zoom)` maps MapLibre camera zoom to OSM admin level using locked RESEARCH.md breakpoints
- `kFallbackLevels` + `fallbackLevelsFrom(zoom)` provide the parent-chain fallback so the focus pill never goes blank over water or road-free zones
- `RegionCoverage` immutable value type carries osmId/adminLevel/name/lengths and derives percent, percentLabel, drivenKm, totalKm
- `coveragePercent` / `formatPercent` match the clamping pattern from Phase 7's `coverage_threshold.dart`
- 52 unit tests across both files: all breakpoints, fallback chain, clamp/precision/zero-guard/km/equality cases

## Task Commits

Each task was committed atomically:

1. **Task 1: zoom_level_mapper.dart + breakpoint/fallback unit tests** - `b8dc502` (feat) — bundled in sibling 08-03 commit (parallel-wave hygiene issue; content identical to plan spec)
2. **Task 2: region_coverage.dart value type + percent math + tests** - `9504acd` (feat)

**Plan metadata:** see docs commit below

## Files Created/Modified

- `lib/features/regions/domain/zoom_level_mapper.dart` — zoomToAdminLevel, kFallbackLevels, fallbackLevelsFrom
- `lib/features/regions/domain/region_coverage.dart` — coveragePercent, formatPercent, RegionCoverage
- `test/features/regions/domain/zoom_level_mapper_test.dart` — 27 tests: all breakpoints + boundaries + fallback chain
- `test/features/regions/domain/region_coverage_test.dart` — 25 tests: clamp/precision/zero-guard/km/equality

## Decisions Made

- **osmId equality excludes adminLevel/name** — equality keyed on (osmId, drivenLengthM, totalLengthM) only; two snapshots of the same region at different times are equal if lengths match. Consistent with "osmId is globally unique across admin levels" (RESEARCH.md line 491).
- **No `meta` import in zoom_level_mapper.dart** — no `@immutable` needed on top-level functions/consts; kept fully import-free.
- **`flutter_test` not `test` package** — changed from plan's import hint to match rest of test suite (all existing tests use `package:flutter_test/flutter_test.dart`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Replaced `package:test/test.dart` with `package:flutter_test/flutter_test.dart`**
- **Found during:** Task 1 (flutter analyze pass)
- **Issue:** Plan's code snippet used `import 'package:test/test.dart'` but `test` is not in dev_dependencies; `depend_on_referenced_packages` lint fires. All existing test files use `flutter_test`.
- **Fix:** Changed import to `package:flutter_test/flutter_test.dart` in both test files.
- **Files modified:** test/features/regions/domain/zoom_level_mapper_test.dart, test/features/regions/domain/region_coverage_test.dart
- **Verification:** `flutter analyze` clean; all 52 tests pass.
- **Committed in:** b8dc502 / 9504acd (part of task commits)

---

**Total deviations:** 1 auto-fixed (Rule 3 - blocking lint)
**Impact on plan:** Trivial import swap; no logic change.

## Issues Encountered

- **Parallel-wave file absorption (Wave 2 hygiene):** The sibling 08-03 agent ran simultaneously and committed `zoom_level_mapper.dart` + `zoom_level_mapper_test.dart` inside its own commit (`b8dc502`) before our Task 1 commit could land. Both files contain the exact planned content — no data loss — but Task 1 lacks its own 08-01-prefixed commit. This matches the known MEMORY.md pattern "parallel-wave metadata hygiene". Task 2 committed cleanly under our own hash `9504acd`.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- All domain primitives are in place and test-locked; 08-02, 08-03, 08-04, 08-05, 08-06 can import them freely.
- No new pubspec dependencies added; analyzer clean.
- Breakpoints and clamp rules are locked by tests — future plans should not change them without updating the test file.

---
*Phase: 08-regions-focus-area*
*Completed: 2026-07-11*
