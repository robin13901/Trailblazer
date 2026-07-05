---
phase: 03-tracking-mvp
plan: 01
subsystem: database
tags: [drift, sqlite, migration, dao, repository, riverpod, trip-tracking]

# Dependency graph
requires:
  - phase: 01-scaffolding
    provides: AppDatabase v1 schema (trips + trip_points tables), DomainError/Result types, NativeDatabase.memory() test pattern
provides:
  - Drift v2 schema with five additive bbox/pointCount nullable columns
  - TripStatus enum (recording|pending|matched|confirmed|rejected) with TEXT TypeConverter
  - TripsDao: Drift DatabaseAccessor with openTrip/appendPointsBatch/closeTrip/deleteTrip/activeTrip/watchPoints
  - TripsRepository: Result<T>-wrapped domain facade, sole write path for Wave 2
  - appDatabaseProvider + tripsDaoProvider + tripsRepositoryProvider (plain Provider, no codegen)
  - Migration test: v1-seeded row survives v1→v2 upgrade with NULL new columns
  - Repository test: openTrip → appendPoints → closeTrip → activeTrip round-trip verified
affects:
  - 03-04-tracking-service-notifier (consumes tripsRepositoryProvider)
  - 03-05 and later (schema v2 is the baseline from here)
  - Phase 9 (bluetooth_hint column deferred; stays NULL for all P3 writes)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TripsDao uses DatabaseAccessor<AppDatabase> without @DriftAccessor — avoids circular import when DAO is in a separate package path from AppDatabase"
    - "app_database.dart imports TripStatus/TripStatusConverter so the generated part file has them in scope"
    - "appDatabaseProvider: plain Provider<AppDatabase> with ref.onDispose(db.close) — same pattern as Phase 1 tile_server_providers"
    - "avoid_catches_without_on_clauses suppressed at the catch clause with inline doc comment — DomainError.wrap needs Object not Exception"

key-files:
  created:
    - lib/features/trips/domain/trip_status.dart
    - lib/core/db/converters/trip_status_converter.dart
    - lib/features/trips/domain/trip_summary.dart
    - lib/features/trips/data/trips_dao.dart
    - lib/features/trips/data/trips_repository.dart
    - lib/features/trips/data/trips_repository_providers.dart
    - lib/core/db/app_database_providers.dart
    - drift_schemas/drift_schema_v2.json
    - test/core/db/migration_v1_to_v2_test.dart
    - test/features/trips/data/trips_repository_test.dart
  modified:
    - lib/core/db/tables/trips_table.dart (added 5 nullable columns + TripStatusConverter on status)
    - lib/core/db/app_database.dart (schemaVersion 1→2, onUpgrade v1→v2, imports for TripStatus/Converter)

key-decisions:
  - "TripsDao uses DatabaseAccessor without @DriftAccessor to avoid circular import — accesses $TripsTable/$TripPointsTable via attachedDatabase getters"
  - "app_database.dart does NOT list TripsDao in @DriftDatabase(daos:[...]) — keeping DAO in separate file avoids Drift circular-import confusion"
  - "appDatabaseProvider created in lib/core/db/app_database_providers.dart as plain Provider<AppDatabase>"
  - "avoid_catches_without_on_clauses suppressed at catch clause with inline doc — boundary pattern requires catching all throwables for DomainError.wrap"

patterns-established:
  - "DAO pattern: plain DatabaseAccessor subclass with explicit table getters (no @DriftAccessor) for projects with DAO in a separate feature directory"
  - "TripStatus enum: stored as TEXT via TripStatusConverter.name — stable, human-readable, survives SQLite dump"
  - "bluetooth_hint stays NULL for all Phase 3 writes — Phase 9 deferred per 03-CONTEXT.md"

# Metrics
duration: 13min
completed: 2026-07-05
---

# Phase 3 Plan 01: Drift v2 Trip Repository Summary

**Drift schema v2 with bbox/pointCount columns, TripStatus TypeConverter, TripsDao + TripsRepository + providers, and passing migration + repository tests**

## Performance

- **Duration:** 13 min
- **Started:** 2026-07-05T10:40:52Z
- **Completed:** 2026-07-05T10:54:25Z
- **Tasks:** 2
- **Files modified:** 12

## Accomplishments

- AppDatabase schema bumped to v2 with five additive nullable columns (bboxMinLat/Lon, bboxMaxLat/Lon, pointCount) — additive migration preserves v1 data
- TripStatus enum persisted as TEXT via TripStatusConverter — eliminates status string drift between call sites
- TripsDao and TripsRepository provide the sole Drift write path for Wave 2; Wave 2 can import `tripsRepositoryProvider` immediately
- Migration test confirms v1-seeded row survives v1→v2 upgrade with NULL new columns
- Repository test proves openTrip → appendPoints → closeTrip → activeTrip round-trip against in-memory DB

## Task Commits

Each task was committed atomically:

1. **Task 1: Drift schema v2 — add summary columns + TripStatus converter** - `68cef2d` (feat)
2. **Task 2: TripsDao + TripsRepository + provider + repository test** - `d4b6acf` (feat)

**Plan metadata:** `(pending)` (docs: complete plan)

## Files Created/Modified

- `lib/features/trips/domain/trip_status.dart` - TripStatus enum (5 values)
- `lib/core/db/converters/trip_status_converter.dart` - TEXT TypeConverter for TripStatus
- `lib/core/db/tables/trips_table.dart` - 5 new nullable v2 columns + converter on status
- `lib/core/db/app_database.dart` - schemaVersion 2, onUpgrade v1→v2 addColumn calls
- `drift_schemas/drift_schema_v2.json` - committed v2 schema snapshot
- `lib/features/trips/domain/trip_summary.dart` - immutable TripSummary value class
- `lib/features/trips/data/trips_dao.dart` - Drift DAO (openTrip/appendPointsBatch/closeTrip/deleteTrip/activeTrip/watchPoints)
- `lib/features/trips/data/trips_repository.dart` - Result<T>-wrapped domain repository
- `lib/features/trips/data/trips_repository_providers.dart` - tripsDaoProvider + tripsRepositoryProvider
- `lib/core/db/app_database_providers.dart` - appDatabaseProvider singleton
- `test/core/db/migration_v1_to_v2_test.dart` - SchemaVerifier v1→v2 migration test
- `test/features/trips/data/trips_repository_test.dart` - 4 repository round-trip tests

## Decisions Made

1. **TripsDao without @DriftAccessor** — Using `DatabaseAccessor<AppDatabase>` directly and accessing `$TripsTable`/`$TripPointsTable` via `attachedDatabase.trips` / `attachedDatabase.tripPoints`. This avoids a circular import error that occurs when Drift's `@DriftAccessor(tables: [...])` annotation tries to resolve table classes from a file that imports `app_database.dart` (which is the parent library). The mixin approach (`_$TripsDaoMixin`) generated an empty mixin when tables couldn't be resolved, so the plain accessor pattern was chosen.

2. **No `daos:` list in @DriftDatabase** — Adding `daos: [TripsDao]` to `@DriftDatabase` caused build_runner to embed a `late final TripsDao tripsDao` getter in `app_database.g.dart`, but since `app_database.dart` didn't import `trips_dao.dart`, the compilation failed. The plan's intent (DAO consuming the database) is achieved via the provider layer, not via a DB-owned DAO getter.

3. **appDatabaseProvider in core/db** — Created `lib/core/db/app_database_providers.dart` (not in `main.dart`) so Wave 2 plans can import the provider without touching the app entrypoint.

4. **avoid_catches_without_on_clauses** — Suppressed at each `catch` clause with an inline explanation. The `DomainError.wrap(e, st)` boundary pattern intentionally catches `Object` (not just `Exception`) to handle Drift's `SqliteException` and Dart `Error` subtypes.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] TripsDao rewritten without @DriftAccessor**
- **Found during:** Task 2 (build_runner)
- **Issue:** `@DriftAccessor(tables: [Trips, TripPoints])` produced an empty mixin because Drift couldn't resolve table types across the circular import boundary (trips_dao.dart → app_database.dart → trips_dao.dart). Adding `daos: [TripsDao]` to @DriftDatabase broke compilation differently.
- **Fix:** Removed `@DriftAccessor` and `part` file; used plain `DatabaseAccessor<AppDatabase>` with `attachedDatabase.trips` / `attachedDatabase.tripPoints` getters. Functionally identical.
- **Files modified:** lib/features/trips/data/trips_dao.dart
- **Verification:** All 4 repository tests pass; flutter analyze clean

**2. [Rule 3 - Blocking] Stale trips_dao.g.dart with TripsDao reference**
- **Found during:** Task 2 (first test run)
- **Issue:** An intermediate build_runner run (during the daos:[TripsDao] experiment) embedded `late final TripsDao tripsDao` in app_database.g.dart, which failed to compile because app_database.dart had no import for TripsDao.
- **Fix:** Removed `daos: [TripsDao]` from annotation and re-ran build_runner; stale reference cleaned up automatically.
- **Files modified:** lib/core/db/app_database.dart (reverted daos removal), lib/core/db/app_database.g.dart (regenerated)
- **Verification:** flutter analyze and flutter test both clean after regeneration

---

**Total deviations:** 2 auto-fixed (1 bug, 1 blocking)
**Impact on plan:** Both deviations resolved by correct Dart/Drift pattern. No scope changes; all plan deliverables shipped.

## Issues Encountered

None beyond the deviations documented above.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `tripsRepositoryProvider` is ready for Wave 2 (Plan 03-04 TrackingNotifier)
- `appDatabaseProvider` is available for any Phase 3+ plan that needs a database reference
- `bluetooth_hint` column is NULL for all P3 writes — Phase 9 marker preserved
- Migration test and repository test both green; schema v2 JSON committed

---
*Phase: 03-tracking-mvp*
*Completed: 2026-07-05*
