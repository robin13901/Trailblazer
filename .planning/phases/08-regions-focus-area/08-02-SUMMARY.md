---
phase: 08-regions-focus-area
plan: "02"
subsystem: coverage
tags: [drift, riverpod, haversine, admin-region, coverage-cache, interval-union]

# Dependency graph
requires:
  - phase: 06-coverage-cache
    provides: CoverageCacheDao (upsert/delete/getByRegionId), CoverageInvalidator, driven_way_intervals table, TripsInboxRepository skeleton
  - phase: 07-coverage-rendering
    provides: DrivenWayGeometryResolver pattern (iterate intervals + fetch ways + union), DrivenWayIntervalsDao.getAllIntervals, TripsDao.watchUnionBbox
  - phase: 04-osm-pipeline
    provides: AdminRegionLookup (regionAt), WayCandidateSource (fetchWaysInBbox)
  - phase: 08-01
    provides: RegionCoverage value type (percentage math — not used by this plan directly)

provides:
  - CoverageComputeService.recompute() — FIRST real writer of coverage_cache; levels 4/6/8/9/10 only
  - coverageComputeServiceProvider (plain Provider<T>)
  - CoverageCacheDao.getAllWithCoverage() — list read for browser (driven_length_m > 0 filter)
  - unawaited recompute hook in TripsInboxRepository.confirmTrip (post-invalidation re-population)

affects:
  - 08-04 (focus-pill provider reads coverage_cache via getAllWithCoverage or getByRegionId)
  - 08-05 (region browser reads getAllWithCoverage())
  - 08-06 (region detail sheet reads getByRegionId)
  - 09 (per-vehicle coverage — plan leaves TODO hooks; vehicleId param TBD)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CoverageComputeService: same constructor shape as DrivenWayGeometryResolver — ensureLoaded on main isolate, one-shot .first on watchUnionBbox stream, fetchWaysInBbox(throwOnError:false)"
    - "kComputeAdminLevels const = [4,6,8,9,10] mirrors kCoverageAdminLevels from CoverageInvalidator"
    - "fire-and-forget unawaited recompute in TripsInboxRepository.confirmTrip after invalidation"
    - "CoverageCacheDao uses plain DatabaseAccessor<AppDatabase> (no @DriftAccessor / part file)"
    - "_FakeAdminRegionLookup + _FixedWayCandidateSource pattern for service unit tests"

key-files:
  created:
    - lib/features/regions/data/coverage_compute_service.dart
    - lib/features/regions/data/coverage_compute_providers.dart
    - test/features/regions/data/coverage_compute_service_test.dart
  modified:
    - lib/features/coverage/data/coverage_cache_dao.dart
    - lib/features/trips/data/trips_repository_inbox_extensions.dart
    - test/features/trips/trips_repository_inbox_extensions_test.dart

key-decisions:
  - "Level 2 (Germany country) excluded from kComputeAdminLevels: full-DE row accumulates entire road network, not useful for Phase-8 display"
  - "deleteAll before upsert loop: a region that dropped to 0 total length (ways disappeared from cache) disappears from the table cleanly"
  - "CoverageComputeService injects TripsDao for watchUnionBbox().first (one-shot) rather than a dedicated bbox DAO, matching DrivenWayGeometryResolver's existing caller contract"
  - "extractVersion: null left as explicit Phase-10 hook (omitted from upsert call — null is default)"
  - "recompute() wraps all throwables at DomainError boundary and returns Err (never throws); fire-and-forget callers swallow the Err"
  - "existing trips_repository_inbox_extensions_test updated with _NoopComputeService (extends CoverageComputeService, overrides recompute() → Ok(0)) to satisfy new required constructor param without hitting DB/network"

patterns-established:
  - "Phase-9 hook pattern: // TODO(phase-9): add vehicleId parameter ... comments left in CoverageComputeService"

# Metrics
duration: 13min
completed: 2026-07-11
---

# Phase 8 Plan 02: CoverageComputeService Summary

**Coverage-cache first writer: sweep-line union + Haversine total per admin region at levels 4/6/8/9/10, wired fire-and-forget into confirmTrip post-invalidation**

## Performance

- **Duration:** 13 min
- **Started:** 2026-07-11T07:47:20Z
- **Completed:** 2026-07-11T08:00:42Z
- **Tasks:** 3
- **Files modified:** 6 (3 created, 3 modified)

## Accomplishments

- `CoverageComputeService.recompute()` — first real writer of `coverage_cache`: iterates all driven intervals + all cached Kfz ways, attributes each way to its admin region at levels 4/6/8/9/10 (level 2 excluded), upserts driven/total lengths, yields number of rows written
- `CoverageCacheDao.getAllWithCoverage()` — list read for the Phase-8 region browser, filters to `driven_length_m > 0`
- `TripsInboxRepository.confirmTrip` re-populate hook — `unawaited(_computeService.recompute())` after `CoverageInvalidator.invalidateForTrip` so the deleted rows are immediately re-computed in the background
- 7-scenario unit test: empty DB, null bbox, all-null regions, driven+total populated, un-driven total-only, re-population after delete, level-2 exclusion

## Task Commits

1. **Task 1: CoverageComputeService + provider** - `a624713` (feat)
2. **Task 2: getAllWithCoverage() + recompute hook** - `ba9c2cb` (feat)
3. **Task 3: CoverageComputeService 7-scenario test** - `626cb1b` (test)

## Files Created/Modified

- `lib/features/regions/data/coverage_compute_service.dart` — CoverageComputeService class with recompute() + kComputeAdminLevels + Phase-9 TODO hooks
- `lib/features/regions/data/coverage_compute_providers.dart` — coverageComputeServiceProvider plain Provider<T>
- `lib/features/coverage/data/coverage_cache_dao.dart` — added getAllWithCoverage() method
- `lib/features/trips/data/trips_repository_inbox_extensions.dart` — added CoverageComputeService field + constructor param + unawaited recompute in confirmTrip; updated provider
- `test/features/regions/data/coverage_compute_service_test.dart` — 7-scenario unit test (new)
- `test/features/trips/trips_repository_inbox_extensions_test.dart` — updated with _NoopComputeService fake

## Decisions Made

- **Level 2 excluded from kComputeAdminLevels**: Writing a Germany-level coverage row on every recompute would accumulate the entire DE road network as `total_length_m` — not a useful Phase-8 display value. Excluded per RESEARCH.md Pitfall 2.
- **deleteAll before upsert**: Stale region rows (from ways that disappeared from the Overpass cache) are cleaned up each recompute cycle rather than accumulating.
- **CoverageComputeService owns a TripsDao**: One-shot `watchUnionBbox().first` mirrors the resolver's existing pattern without introducing a separate bbox query method.
- **extractVersion** intentionally omitted (null is default, Phase 10 wires the real value).
- **No `@DriftAccessor` on CoverageCacheDao**: Continues the plain `DatabaseAccessor<AppDatabase>` pattern from Phase 6 — no codegen, no `part` file.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Updated existing TripsInboxRepository test to satisfy new required `computeService` parameter**

- **Found during:** Task 2 test run
- **Issue:** `trips_repository_inbox_extensions_test.dart` constructed `TripsInboxRepository` without the new `computeService:` param — compile error in test suite
- **Fix:** Added `_NoopComputeService` (extends `CoverageComputeService`, overrides `recompute()` → `Ok(0)`) + `_FakeAdminRegionLookup` + `_EmptyWayCandidateSource` fakes; updated `buildRepo` helper; rewrote file cleanly (had gotten into a broken state during iterative edits)
- **Files modified:** `test/features/trips/trips_repository_inbox_extensions_test.dart`
- **Verification:** All 342 pre-existing tests pass; additional 7 new tests pass (401 total)
- **Committed in:** `ba9c2cb` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (blocking)
**Impact on plan:** Required to keep existing tests passing. No scope creep.

## Issues Encountered

- **`comment_references` info on `[DrivenWayGeometryResolver]` in doc comment** — Class not imported in `coverage_compute_service.dart`, so the bracket reference emitted an info diagnostic. Fixed by changing `[DrivenWayGeometryResolver]` to backtick-quoted `\`DrivenWayGeometryResolver\`` (no import needed).
- **`avoid_redundant_argument_values` on `extractVersion: null`** — `extractVersion` is `String?` with default `null`; omitted the named argument and left an inline comment instead.
- **`unused_import` for `way_candidate.dart`** — Removed; `WayCandidate` type is provided transitively via `WayCandidateSource` import.

## Next Phase Readiness

- `coverage_cache` is now populated by real data after each trip confirmation
- `getAllWithCoverage()` is ready for the region browser (08-05)
- `getByRegionId()` is ready for the focus pill (08-04) and detail sheet (08-06)
- Phase-9 TODO hooks in `CoverageComputeService` mark the `vehicleId` + time-attribution extension points cleanly

---
*Phase: 08-regions-focus-area*
*Completed: 2026-07-11*
