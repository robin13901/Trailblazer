---
phase: 08-regions-focus-area
plan: "06"
subsystem: ui
tags: [flutter, riverpod, regions, focus-pill, detail-sheet, widget-test, drift]

# Dependency graph
requires:
  - phase: 08-04
    provides: FocusAreaPill ConsumerWidget + focusPillProvider + liveCameraProvider
  - phase: 08-05
    provides: showRegionDetailSheet + RegionCoverage + AdminRegionLookup.regionAt

provides:
  - Pill tap opens region detail sheet for the region currently under the map view
  - GestureDetector onTap wired via _openSheet (fallbackLevelsFrom chain)
  - Widget test confirming tap resolves region and opens sheet
  - Phase-8 deferred device-verification checklist (10 items, no execution gate)

affects: [phase-09-vehicles, future-gap-plans]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GestureDetector tap -> async provider read chain -> showModalBottomSheet"
    - "context.mounted guard after each async step in tap handlers"
    - "Widget test with NativeDatabase.memory() for DAO seeding"
    - "Deferred checklist pattern (10 on-device confirms batched to next drive)"

key-files:
  created:
    - test/features/map/focus_area_pill_tap_test.dart
    - .planning/phases/08-regions-focus-area/08-DEVICE-VERIFICATION-DEFERRED.md
  modified:
    - lib/features/map/presentation/widgets/focus_area_pill.dart

key-decisions:
  - "Tap resolves region with same fallbackLevelsFrom chain as the background notifier — pill and sheet always show the same region"
  - "context.mounted checked after ensureLoaded and after getByRegionId — handles orientation changes / unmounts during async resolution"
  - "Widget test uses NativeDatabase.memory() rather than subclassing CoverageCacheDao — avoids null AppDatabase cast"
  - "Semantics button: true added to pill since it is now tappable"

patterns-established:
  - "Pill tap pattern: read providers -> async resolve -> context.mounted guard -> show sheet"
  - "Phase-level deferred checklist: one file per phase batching all on-device confirms"

# Metrics
duration: 25min
completed: 2026-07-11
---

# Phase 8 Plan 06: Pill Tap Integration Summary

**GestureDetector tap on FocusAreaPill resolves the live focus region via fallbackLevelsFrom chain and opens showRegionDetailSheet, closing the Wave-2 integration seam between pill (08-04) and detail sheet (08-05)**

## Performance

- **Duration:** ~25 min
- **Started:** 2026-07-11T10:30:00Z
- **Completed:** 2026-07-11T11:00:00Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments

- Wired pill tap: `GestureDetector` wraps `GlassPill`; `_openSheet` reads `liveCameraProvider` + `adminRegionLookupProvider`, walks `fallbackLevelsFrom(zoom)`, reads coverage cache, builds `RegionCoverage`, calls `showRegionDetailSheet`
- `context.mounted` guarded after each `await` (ensureLoaded, getByRegionId) so the handler is safe across orientation changes / navigator transitions
- Widget test with in-memory DB proves tap resolves the region and opens the sheet: 3 assertions (GestureDetector hittable, region name in sheet, "Im Karte anzeigen" button present)
- Phase-8 deferred device-verification checklist written (10 items) — covers pill live feel, zoom breakpoints, fallback, pill tap, browser cards, fuzzy search, sheet drag + glass, jump-to-map, recompute after confirm

## Task Commits

Each task was committed atomically:

1. **Task 1: wire pill tap to the region detail sheet** - `937e092` (feat)
2. **Task 2: pill-tap widget test** - `462cb4a` (test)
3. **Task 3: write the single deferred device-verification checklist** - `c8645f7` (docs)

**Plan metadata:** (docs commit follows this summary)

## Files Created/Modified

- `lib/features/map/presentation/widgets/focus_area_pill.dart` — Added `GestureDetector` + `_openSheet` async handler; `Semantics(button: true)`; new imports
- `test/features/map/focus_area_pill_tap_test.dart` — 3 widget tests proving tap wiring; `_FakeLookup`, `_FixedLiveCameraNotifier`, `NativeDatabase.memory()` DB setup
- `.planning/phases/08-regions-focus-area/08-DEVICE-VERIFICATION-DEFERRED.md` — 10-item on-device checklist batching all Phase-8 device confirms per "defer-in-car-verification" policy

## Decisions Made

- **Same fallback chain in tap as in notifier:** `_openSheet` uses `fallbackLevelsFrom(zoom)` — the pill and the sheet always agree on which region is "current". If the pill shows Grebenhain, the sheet opens for Grebenhain.
- **`context.mounted` after each await:** Flutter best practice for async tap handlers; prevents "setState after dispose" crashes during orientation changes or rapid navigation.
- **In-memory DB in test instead of fake DAO subclass:** `CoverageCacheDao` requires a non-null `AppDatabase` in its constructor; passing `null as dynamic` causes a runtime cast error. Using `NativeDatabase.memory()` gives a real, fast, hermetic DB.
- **`Semantics(button: true)` added:** The pill is now tappable; `button: true` makes it accessible as a button to screen readers.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed `prefer_final_locals` lint on `var region`**
- **Found during:** Task 1 (flutter analyze)
- **Issue:** `var region = await (...)()` triggered `prefer_final_locals`
- **Fix:** Changed to `final region = await (...)()` — the closure return is final by definition
- **Files modified:** `lib/features/map/presentation/widgets/focus_area_pill.dart`
- **Verification:** `flutter analyze` clean
- **Committed in:** `937e092` (Task 1 commit)

**2. [Rule 1 - Bug] Fixed `CoverageCacheData`/`Value` compile errors in test**
- **Found during:** Task 2 (flutter test compilation)
- **Issue:** Initial test used `Value(1200.0).value` syntax (Drift companion) for `CoverageCacheData` constructor; the constructor takes plain types. Also attempted `null as dynamic` for `AppDatabase` which fails at runtime.
- **Fix:** Rewrote `_FakeCacheDao` to use `NativeDatabase.memory()`-backed real `AppDatabase`; used plain double/int literals in `CoverageCacheData`
- **Files modified:** `test/features/map/focus_area_pill_tap_test.dart`
- **Verification:** All 3 tap tests pass
- **Committed in:** `462cb4a` (Task 2 commit)

**3. [Rule 1 - Bug] Fixed 4 analyze lint warnings in test file**
- **Found during:** Task 2 (flutter analyze after first test pass)
- **Issue:** `prefer_const_declarations`, `unnecessary_const`, `prefer_int_literals`
- **Fix:** `final _kTestRegion` → `const _kTestRegion`; removed redundant `const` on `polygons: []`; `15.0` → `15`, `1200.0` → `1200`, `9750.0` → `9750`
- **Files modified:** `test/features/map/focus_area_pill_tap_test.dart`
- **Verification:** `flutter analyze` clean (0 issues)
- **Committed in:** `462cb4a` (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (3 × Rule 1 — bug/lint)
**Impact on plan:** All fixes necessary for correct behavior and clean analyze. No scope creep.

## Issues Encountered

None beyond the auto-fixed lint/compile issues documented above.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Phase 8 is complete: all 6 plans (08-01 through 08-06) code-complete, analyze clean, tests green
- On-device confirms are deferred to next drive — see `08-DEVICE-VERIFICATION-DEFERRED.md`
- Phase 9 (Vehicles) can begin; Phase 8 left a clean hook: `coverageCacheDaoProvider` and `regionBrowserProvider` compute global coverage only; per-vehicle filter parameter can be added without schema changes

---
*Phase: 08-regions-focus-area*
*Completed: 2026-07-11*
