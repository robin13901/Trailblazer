---
phase: 05-overpass-matcher-and-golden-corpus
plan: 01
subsystem: database
tags: [drift, dao, retention, trip-points, driven-way-intervals, schema-v3]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: "schema v3 driven_way_intervals table + FK SET NULL policy"
  - phase: 01-scaffolding
    provides: "AppDatabase, DomainError, Result<T> pattern"
  - phase: 03-tracking-mvp
    provides: "TripsDao, TripsRepository, trip_points table"
provides:
  - "DrivenWayIntervalsDao: insertBatch / getByTrip / deleteByTrip CRUD on driven_way_intervals"
  - "AppDatabase.drivenWayIntervalsDao getter (codegen-backed)"
  - "TripsDao.deleteTripPointsForMatchedTripsOlderThan: 30-day GPS retention sweep via SQL DELETE"
  - "TripsRepository.sweepRawGpsRetention: Result<int>-wrapped sweep callable from resume hook"
affects:
  - 05-07-matcher-isolate-coordinator
  - 05-08-retention-resume-hook
  - 06-coverage-renderer

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "@DriftAccessor(tables: [DrivenWayIntervals]) — third DAO to use the annotation (after OverpassWayCacheDao, PendingRoadFetchesDao)"
    - "drift/drift.dart hide isNull/isNotNull — required when test file imports both Drift and flutter_test"
    - "customUpdate with Variable.withDateTime for correlated DELETE with HAVING clause"

key-files:
  created:
    - lib/core/db/daos/driven_way_intervals_dao.dart
    - test/core/db/daos/driven_way_intervals_dao_test.dart
    - test/features/trips/data/trips_dao_retention_test.dart
  modified:
    - lib/core/db/app_database.dart
    - lib/features/trips/data/trips_dao.dart
    - lib/features/trips/data/trips_repository.dart

key-decisions:
  - "DrivenWayIntervalsDao lives under lib/core/db/daos/ matching OverpassWayCacheDao + PendingRoadFetchesDao pattern"
  - "DAO list in @DriftDatabase alphabetically ordered: [DrivenWayIntervalsDao, OverpassWayCacheDao, PendingRoadFetchesDao]"
  - "Retention sweep uses MAX(matched_at) HAVING clause — preserves trips with any recent interval"
  - "Schema stays at v3 — no migration needed; driven_way_intervals was already in v3"
  - "sweepRawGpsRetention default 30 days per MMT-10; Phase 10 will override from AppPrefs"

patterns-established:
  - "hide isNull / hide isNotNull: when a DAO test imports both package:drift/drift.dart and flutter_test, the top-level Drift query predicates shadow matcher's isNull/isNotNull — always hide from Drift import"
  - "Retention sweep entry point in TripsRepository: takes optional now: DateTime? for test-time clock injection"

# Metrics
duration: ~35min
completed: 2026-07-08
---

# Phase 5 Plan 01: Driven Way Intervals DAO and Retention Summary

**DrivenWayIntervalsDao wired into schema-v3 driven_way_intervals table with MAX-matched_at 30-day GPS retention sweep callable from AppLifecycleState.resumed**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-07-08T~12:00Z
- **Completed:** 2026-07-08
- **Tasks:** 2
- **Files modified:** 6 (3 new source, 3 modified)

## Accomplishments

- `DrivenWayIntervalsDao` ships with `insertBatch`, `getByTrip`, `deleteByTrip`; registered in `AppDatabase.drivenWayIntervalsDao` via Drift codegen
- `TripsDao.deleteTripPointsForMatchedTripsOlderThan(DateTime)` implements the correlated DELETE with `MAX(matched_at) HAVING` — ensures partially-matched trips (one stale + one fresh interval) are NOT swept
- `TripsRepository.sweepRawGpsRetention({Duration retention, DateTime? now})` wraps the DAO in `Result<int>` per the repository contract — ready to be called from Plan 05-07's resume hook

## Task Commits

Each task was committed atomically:

1. **Task 1: DrivenWayIntervalsDao + AppDatabase registration** — `d04bd58` (feat)
2. **Task 2: TripsDao retention sweep + repository wrapper** — `2775e78` (feat)

## Files Created/Modified

- `lib/core/db/daos/driven_way_intervals_dao.dart` — new DAO; @DriftAccessor(tables: [DrivenWayIntervals]); insertBatch/getByTrip/deleteByTrip
- `lib/core/db/app_database.dart` — added DrivenWayIntervalsDao import + appended to daos: [...] alphabetically
- `lib/features/trips/data/trips_dao.dart` — added deleteTripPointsForMatchedTripsOlderThan with customUpdate + HAVING MAX clause
- `lib/features/trips/data/trips_repository.dart` — added sweepRawGpsRetention wrapping the new DAO method
- `test/core/db/daos/driven_way_intervals_dao_test.dart` — 5 tests: batch write + ordering, empty batch no-op, deleteByTrip isolation, FK SET NULL survival, direction default
- `test/features/trips/data/trips_dao_retention_test.dart` — 7 tests: TripsDao (5) + TripsRepository wrapper (2)

## Decisions Made

- **DAO under lib/core/db/daos/**: Consistent with OverpassWayCacheDao + PendingRoadFetchesDao pattern; resolves 05-01 research open question #2.
- **MAX(matched_at) semantics**: A trip with 1 old + 1 fresh interval is NOT swept. Only when every interval is stale (max is still < cutoff) does the trip become eligible. This prevents premature point deletion for partially-matched long trips.
- **Schema stays v3**: The `driven_way_intervals` table was already defined in schema v3 (`lib/core/db/tables/driven_intervals_table.dart` + `drift_schemas/drift_schema_v3.json`). No migration needed; plan explicitly notes this was pre-existing.
- **Default retention 30 days**: Compile-time constant per MMT-10; Phase 10 will override from AppPrefs settings UI.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Ambiguous `isNull`/`isNotNull` import conflict in test files**

- **Found during:** Task 1 (DAO test) and Task 2 (retention test compilation)
- **Issue:** Both `package:drift/drift.dart` and `package:flutter_test/flutter_test.dart` export top-level `isNull` / `isNotNull` predicates. The analyzer/compiler raises `ambiguous_import` when both are in scope.
- **Fix:** Added `hide isNull` or `hide isNotNull` to the Drift import in each affected test file.
- **Files modified:** `test/core/db/daos/driven_way_intervals_dao_test.dart`, `test/features/trips/data/trips_dao_retention_test.dart`
- **Verification:** `flutter analyze` clean; tests compile and pass.
- **Committed in:** `d04bd58` / `2775e78` (within task commits)

**2. [Rule 1 - Bug] `prefer_int_literals` lint — double literals `0.0` in test companions**

- **Found during:** Task 1 (first analyze pass)
- **Issue:** `startMeters: 0.0` / `endMeters: 0.0` triggered `prefer_int_literals` since both columns are `REAL` but accept `int` in Dart.
- **Fix:** Changed all `0.0`/`100.0` to `0`/`100` etc. in test companions.
- **Files modified:** `test/core/db/daos/driven_way_intervals_dao_test.dart`
- **Committed in:** `d04bd58`

---

**Total deviations:** 2 auto-fixed (2× Rule 1 - Bug)
**Impact on plan:** Cosmetic lint fixes only; no scope change.

## Issues Encountered

- **`missing_whitespace_between_adjacent_strings`** in `trips_dao.dart`: The SQL string literal sequence `'HAVING MAX(d.matched_at) < ?'` + `')'` triggered this lint. Fixed by inserting a leading space in the closing paren string: `' )'`.
- **Pre-existing analyzer issue in `test/features/matching/domain/way_segment_index_test.dart`**: One `comment_references` info in an untracked file belonging to Plan 05-03. Not introduced by this plan; not in scope to fix.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `AppDatabase.drivenWayIntervalsDao` is reachable and tested; Plan 05-07 (matcher isolate coordinator) can call `insertBatch` after each HMM run.
- `TripsRepository.sweepRawGpsRetention()` is ready to be wired from `AppLifecycleState.resumed` in Plan 05-08 (or the retention resume hook plan).
- Schema stays at v3; no new `drift_schemas/` JSON produced.
- All 12 new tests green; full suite 340/340 green.

---
*Phase: 05-overpass-matcher-and-golden-corpus*
*Completed: 2026-07-08*
