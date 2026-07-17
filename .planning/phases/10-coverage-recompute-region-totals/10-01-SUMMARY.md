---
phase: 10-coverage-recompute-region-totals
plan: 01
subsystem: ui
tags: [flutter, regions, coverage, admin-levels, requirements]

# Dependency graph
requires:
  - phase: 08-regions-focus-area
    provides: region_card.dart with levelLabel() badge system
  - phase: 06-coverage-rendering
    provides: CoverageInvalidator with kCoverageAdminLevels

provides:
  - Correct German OSM region-type badge labels (L6=Landkreis, L8=Gemeinde/Stadt)
  - Aligned invalidation levels including L9 Ortsteil
  - Formally de-scoped QUA-01/04/07 in REQUIREMENTS.md

affects:
  - 10-02-PLAN (inherits clean analyze baseline)
  - Future phases reading REQUIREMENTS.md QUA status

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "inline // ignore: comment (not leading) for very_good_analysis document_ignores rule"

key-files:
  created: []
  modified:
    - lib/features/regions/presentation/widgets/region_card.dart
    - lib/features/coverage/data/coverage_invalidator.dart
    - test/features/coverage/coverage_invalidator_test.dart
    - lib/features/map/presentation/widgets/live_puck_bridge.dart
    - test/features/map/live_puck_bridge_test.dart
    - .planning/REQUIREMENTS.md

key-decisions:
  - "levelLabel() corrected: L4=Bundesland, L6=Landkreis, L8=Gemeinde/Stadt, L9=Ortsteil, L10=Ortsteil/Stadtteil"
  - "kCoverageAdminLevels now [4,6,8,9,10] — matches CoverageComputeService.kComputeAdminLevels"
  - "QUA-01/04/07 de-scoped per 10-CONTEXT decision 9 (Hardening phase dropped)"
  - "very_good_analysis document_ignores: inline ignore comment required, not leading comment"

patterns-established:
  - "Inline ignore: `void foo() => ...; // ignore: rule_name` (document_ignores compliant)"

# Metrics
duration: 35min
completed: 2026-07-17
---

# Phase 10 Plan 01: Badge/Invalidator/De-scope Summary

**Corrected German OSM badge hierarchy (L6→Landkreis, L8→Gemeinde/Stadt), aligned L9 Ortsteil invalidation, and formally de-scoped QUA-01/04/07 per dropped Hardening phase**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-07-17T00:00:00Z
- **Completed:** 2026-07-17
- **Tasks:** 2 of 2
- **Files modified:** 6

## Accomplishments

- Badge labels now match actual German OSM hierarchy: Kleinheubach (L8) shows "Gemeinde / Stadt" not "Landkreis"; Landkreis Miltenberg (L6) shows "Landkreis" not "Regierungsbezirk"
- `kCoverageAdminLevels` extended from `[4,6,8,10]` to `[4,6,8,9,10]` — L9 Ortsteil rows are now invalidated on trip confirm/discard, eliminating the stale-cache gap
- QUA-01 (widget-test coverage), QUA-04 (patrol E2E), QUA-07 (device QA gauntlet) formally de-scoped in both checklist and mapping table in REQUIREMENTS.md

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix badge labels (F3) + align invalidation levels (F2)** - `ac2ab97` (fix)
2. **Task 2: De-scope QUA-01/04/07 in REQUIREMENTS.md** - `c10158e` (docs)

**Plan metadata:** (below)

## Files Created/Modified

- `lib/features/regions/presentation/widgets/region_card.dart` — corrected `levelLabel()` switch arms
- `lib/features/coverage/data/coverage_invalidator.dart` — `kCoverageAdminLevels` + doc comment updated
- `test/features/coverage/coverage_invalidator_test.dart` — updated Kleinheubach fixture (L9 added), calls 20→25
- `lib/features/map/presentation/widgets/live_puck_bridge.dart` — removed stale `_sourceAdded=false` (Rule 1 bug fix)
- `test/features/map/live_puck_bridge_test.dart` — fixed `// ignore:` placement for `document_ignores` compliance
- `.planning/REQUIREMENTS.md` — QUA-01/04/07 de-scoped in checklist + mapping table + footer

## Decisions Made

- **Badge mapping**: L6 = Landkreis (not Regierungsbezirk — L5 is Regierungsbezirk in Bavaria, not in scope); L8 = Gemeinde / Stadt (not Landkreis); L9 = Ortsteil; L10 = Ortsteil / Stadtteil. Space around slash matches OSM wiki wording.
- **Invalidation levels**: Added L9 to align with `CoverageComputeService.kComputeAdminLevels`. No architectural change — purely additive constant edit.
- **QUA de-scope**: Requirements text retained verbatim; only the de-scoped annotation + mapping-table status changed. IDs (QUA-01/04/07) remain listed for traceability.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed `_sourceAdded = false` referencing undeclared field in `live_puck_bridge.dart`**

- **Found during:** Task 1 (first `flutter analyze` run)
- **Issue:** `_sourceAdded` was assigned on line 78 but never declared as a field. Pre-existing bug that caused an `undefined_identifier` compile error blocking analyze from being clean.
- **Fix:** Removed the dead `_sourceAdded = false;` assignment. `_scheduleReadd()` on the next line already handles the re-add logic without a sentinel field.
- **Files modified:** `lib/features/map/presentation/widgets/live_puck_bridge.dart`, `test/features/map/live_puck_bridge_test.dart`
- **Verification:** `flutter analyze` clean; all `live_puck_bridge_test.dart` tests pass.
- **Committed in:** `ac2ab97` (part of Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 Rule 1 bug)
**Impact on plan:** Bug was blocking `flutter analyze` from being clean. Fix was a one-line removal with no behavior change to the bridge logic.

## Issues Encountered

- `very_good_analysis` `document_ignores` rule requires the `// ignore:` comment to be on the **same line** as the lint violation (inline trailing comment), not as a leading comment on the preceding line. Attempting a leading ignore triggers `unnecessary_ignore` at that location while the lint still fires at the actual violation line. Pattern now established in `patterns-established` frontmatter.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `flutter analyze` clean (0 issues); targeted tests (7 invalidator + 6 puck bridge + 6 regions presentation) all pass
- Plan 10-02 can proceed with a clean baseline
- No blockers from this plan

---
*Phase: 10-coverage-recompute-region-totals*
*Completed: 2026-07-17*
