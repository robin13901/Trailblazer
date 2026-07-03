---
phase: 01-scaffolding
plan: "02"
subsystem: database
tags: [drift, sqlite, migrations, schema, wal, foreign-keys]

requires:
  - phase: 01-scaffolding
    provides: pinned drift/drift_flutter/drift_dev deps + folder skeleton (Plan 01)
provides:
  - Seven Drift tables (trips, trip_points, driven_way_intervals, vehicles, bt_fingerprints, coverage_cache, app_prefs)
  - AppDatabase with schemaVersion=1 and MigrationStrategy (onCreate/onUpgrade/beforeOpen)
  - PRAGMA foreign_keys=ON and journal_mode=WAL enforced on every open
  - drift_schemas/drift_schema_v1.json committed for SchemaVerifier consumers
  - In-memory test helper + SchemaVerifier migration test + smoke open test
affects: [02-map-shell, 03-recording, 04-trip-persistence, 05-hmm-matching, 06-ci, 07-coverage, 09-vehicles]

tech-stack:
  added: [drift-schema-verifier, drift_dev-cli]
  patterns:
    - Domain-split table files under lib/core/db/tables/
    - AppDatabase accepts optional QueryExecutor for tests (constructor DI)
    - Generated drift artifacts (*.g.dart, test/generated_migrations/) are gitignored; drift_schemas/ is checked in
    - PRAGMAs live in beforeOpen so re-opens (WAL, FK) always re-apply

key-files:
  created:
    - lib/core/db/app_database.dart
    - lib/core/db/tables/trips_table.dart
    - lib/core/db/tables/trip_points_table.dart
    - lib/core/db/tables/driven_intervals_table.dart
    - lib/core/db/tables/vehicles_table.dart
    - lib/core/db/tables/bt_fingerprints_table.dart
    - lib/core/db/tables/coverage_cache_table.dart
    - lib/core/db/tables/app_prefs_table.dart
    - drift_schemas/drift_schema_v1.json
    - test/helpers/test_database.dart
    - test/core/db/app_database_open_test.dart
    - test/core/db/migration_test.dart
  modified: []

key-decisions:
  - "FK cascade policies: trip_points->trips ON DELETE CASCADE; driven_intervals->trips ON DELETE SET NULL (interval survives trip loss); bt_fingerprints->vehicles ON DELETE CASCADE"
  - "coverage_cache and app_prefs use business-key primary keys (regionId, key) — no synthetic id"
  - "AppDatabase constructor takes optional QueryExecutor to support NativeDatabase.memory() in tests"
  - "test/generated_migrations/ stays gitignored; CI regenerates it via `drift_dev schema generate` before flutter test in Plan 06"

patterns-established:
  - "Table naming: PascalCase class -> snake_case sqlite table (Drift default)"
  - "One table per file under lib/core/db/tables/, imported by package: URI (very_good_analysis always_use_package_imports)"
  - "MigrationStrategy PRAGMAs live in beforeOpen — never in onCreate"
  - "SchemaVerifier(GeneratedHelper()) is the canonical way to prove schema correctness for a given version"

duration: 19min
completed: 2026-07-03
---

# Phase 01 Plan 02: drift-app-db-schema Summary

**Full v1 App DB scaffold in Drift: 7 tables with FK cascade policies, MigrationStrategy enforcing foreign_keys ON + WAL journal mode, committed drift_schemas/ dump, and SchemaVerifier-backed migration test — all green.**

## Performance

- **Duration:** ~19 min
- **Started:** 2026-07-03T08:05:46Z
- **Completed:** 2026-07-03T08:25:09Z
- **Tasks:** 3
- **Files created:** 12 (7 tables + AppDatabase + schema dump + 3 test files)
- **Files modified:** 0

## Accomplishments

- All seven table definitions land under `lib/core/db/tables/`, one file per aggregate.
- `AppDatabase` wires them via `@DriftDatabase(tables: [...])` with schemaVersion=1 and a `MigrationStrategy` that enforces `PRAGMA foreign_keys = ON` and `PRAGMA journal_mode = WAL` in `beforeOpen`.
- Constructor accepts an optional `QueryExecutor` so tests can inject `NativeDatabase.memory()` without touching the filesystem.
- Drift codegen (`build_runner`) produces `lib/core/db/app_database.g.dart` (gitignored).
- `dart run drift_dev schema dump` produced `drift_schemas/drift_schema_v1.json` — committed as the canonical v1 shape.
- `SchemaVerifier(GeneratedHelper()).migrateAndValidate(db, 1)` passes.
- Smoke test proves all 7 tables exist by name and `PRAGMA foreign_keys` reads back as 1 after `beforeOpen`.
- `flutter analyze --fatal-infos` and `dart format --set-exit-if-changed` both clean.
- Full `flutter test` suite green (14 tests across the wave, 3 belong to this plan).

## Task Commits

1. **Task 2.1: Create the seven table definition files** — `90b4f05` (feat)
2. **Task 2.2: AppDatabase + MigrationStrategy + schema dump** — `307673b` (feat)
3. **Task 2.3: SchemaVerifier + in-memory open tests** — (see Deviations below; test files landed in `3341081` alongside a sibling Plan 04 commit)

**Plan metadata commit:** made after this SUMMARY.md is written (see final commit for hash).

## Files Created/Modified

- `lib/core/db/tables/trips_table.dart` — canonical trip record; nullable end fields until confirmed
- `lib/core/db/tables/trip_points_table.dart` — per-sample GPS/motion points; FK `trip_id -> trips.id ON DELETE CASCADE`; unique `(trip_id, seq)`
- `lib/core/db/tables/driven_intervals_table.dart` — matched OSM way intervals; FK `trip_id -> trips.id ON DELETE SET NULL` so historic coverage survives trip deletion
- `lib/core/db/tables/vehicles_table.dart` — vehicle registry with `is_default` + `counts_for_coverage`
- `lib/core/db/tables/bt_fingerprints_table.dart` — Bluetooth MAC -> vehicle map; FK `vehicle_id -> vehicles.id ON DELETE CASCADE`
- `lib/core/db/tables/coverage_cache_table.dart` — per-region coverage aggregate; PK on `region_id`; `invalidation_gen` counter for stale-cache detection
- `lib/core/db/tables/app_prefs_table.dart` — KV prefs table; PK on `key`
- `lib/core/db/app_database.dart` — `@DriftDatabase` with schemaVersion=1, migration strategy, and `driftDatabase(name: 'app_db')` for platform-native storage
- `drift_schemas/drift_schema_v1.json` — Drift's canonical v1 schema JSON (used by SchemaVerifier)
- `test/helpers/test_database.dart` — `createInMemoryDatabase()` helper
- `test/core/db/app_database_open_test.dart` — verifies all 7 tables + `PRAGMA foreign_keys` = 1
- `test/core/db/migration_test.dart` — `SchemaVerifier.migrateAndValidate(db, 1)`

Generated (gitignored, not files created for VCS purposes):
- `lib/core/db/app_database.g.dart`
- `test/generated_migrations/schema.dart`
- `test/generated_migrations/schema_v1.dart`

## Decisions Made

- **FK cascade choices** — `trip_points` cascades with its trip (points are meaningless without a trip); `driven_intervals` uses `SET NULL` (a rejected trip should not erase the coverage it earned); `bt_fingerprints` cascade with their vehicle (fingerprints without a vehicle are dead entries).
- **Constructor DI on AppDatabase** — added optional `QueryExecutor` param so `NativeDatabase.memory()` can be injected without exposing internals; matches Drift's own idiom in their migration test examples.
- **Business-key PKs on coverage_cache / app_prefs** — no synthetic `id` column. `region_id` and `key` are unique by domain definition; adding `id` would just create an extra index for no benefit.
- **`test/generated_migrations/` stays gitignored** — schemas are the source of truth (`drift_schemas/` IS committed). CI regenerates the helpers per Plan 06.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Lint fix] `Constant(0.0)` triggered `prefer_int_literals`**
- **Found during:** Task 2.1 (`coverage_cache_table.dart`)
- **Issue:** `withDefault(const Constant(0.0))` — very_good_analysis flags the `.0` literal.
- **Fix:** Switched to explicit `const Constant<double>(0)` — still a `double` (Drift infers RealColumn correctly), lint clean.
- **Files modified:** `lib/core/db/tables/coverage_cache_table.dart`
- **Verification:** `flutter analyze --fatal-infos lib/core/db/tables/` → 0 issues.
- **Committed in:** `90b4f05`

**2. [Rule 1 — Lint fix] `avoid_types_on_closure_parameters` on MigrationStrategy callbacks**
- **Found during:** Task 2.2 (`app_database.dart` after full-project analyze)
- **Issue:** The RESEARCH.md snippet types the closure params (`Migrator m`, `int from`, `int to`), which very_good_analysis rejects.
- **Fix:** Dropped explicit types on `onCreate`/`onUpgrade` closure parameters; the enclosing `MigrationStrategy` typedef supplies them.
- **Files modified:** `lib/core/db/app_database.dart`
- **Verification:** `flutter analyze --fatal-infos` → 0 issues.
- **Committed in:** `307673b`

**3. [Rule 1 — Lint fix] `prefer_single_quotes` + `unused_import` on open test**
- **Found during:** Task 2.3
- **Issue:** Test used double-quoted first line of SQL literal and imported `package:drift/drift.dart` without using it.
- **Fix:** Switched SQL literal to single quotes; removed the unused import.
- **Files modified:** `test/core/db/app_database_open_test.dart`
- **Verification:** analyzer clean; tests green.
- **Committed in:** `3341081` (see Wave-2 coordination note below)

### Wave-2 Coordination Note

The three Task 2.3 test files (`test/core/db/app_database_open_test.dart`, `test/core/db/migration_test.dart`, `test/helpers/test_database.dart`) ended up mixed into a sibling Plan 04 commit `3341081` ("feat(01-04): wire FlutterError + PlatformDispatcher error hooks in main"). This was almost certainly a `git add -A`/`git commit -a` from the parallel Wave-2 agent that swept my untracked files just before its own commit ran — an atomicity violation on the peer's side, not mine.

I decided **not** to rewrite history mid-wave to relocate the files (that would break the sibling agent's HEAD and could race with any orchestrator staging). Consequences accepted:
- The three test files are correctly tracked and pass `flutter test`.
- `git log --follow` on them attributes them to `3341081` rather than a dedicated `test(01-02)` commit.
- The functional/behavioral requirement (all Task 2.3 done criteria) is met.

Recommend the orchestrator flag Wave-2 hygiene for future waves: subagents must stage per file, never `git add .`.

---

**Total deviations:** 3 lint auto-fixes + 1 external coordination artifact
**Impact on plan:** All auto-fixes are cosmetic (very_good_analysis rules). Coordination artifact is history-only; no functional impact.

## Issues Encountered

- **Sibling Wave-2 agent captured my test files** — documented above; kept moving to avoid destabilizing peer branches.
- **Build_runner `--delete-conflicting-outputs` deprecation warning** — the flag is now ignored ("This flag has been removed and was ignored"). Non-blocking, output was still correct. Future plans can drop the flag.

## User Setup Required

None — Drift is pure-Dart at codegen time and drift_flutter handles the platform bootstrap.

## Next Phase Readiness

- **App DB is ready for consumption.** Phase 2+ plans can `AppDatabase()` and rely on `foreign_keys=ON` + WAL being set on every open.
- **DAO scaffolding intentionally deferred** — each future phase adds DAOs for tables it actually reads/writes, per CONTEXT.md.
- **Schema versioning is in place.** The moment any future phase changes a table, they must:
  1. Bump `schemaVersion` in `app_database.dart`
  2. Add an `onUpgrade` branch that migrates the old version.
  3. Re-run `dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/` — commit the new `drift_schema_vN.json`.
  4. Extend the migration test to cover the new step-up.
- **CI dependency for Plan 06:** must run `dart run drift_dev schema generate drift_schemas/ test/generated_migrations/` before `flutter test`, since generated migrations are gitignored.
- **Blockers/concerns:** none.

---
*Phase: 01-scaffolding*
*Completed: 2026-07-03*
