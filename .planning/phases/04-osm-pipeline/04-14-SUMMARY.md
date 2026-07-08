---
phase: 04-osm-pipeline
plan: 14
subsystem: db-schema
tags: [drift, migration, dao, overpass-cache, pending-fetches, lru, ttl, cascade, wave-2]

# Dependency graph
requires:
  - phase: 04-osm-pipeline (Plan 04-13)
    provides: Overpass payload probe → MANDATORY tile-split verdict; validates the (tileZ, tileX, tileY) composite PK on `overpass_way_cache`
  - phase: 03-tracking-mvp (Plan 03-01)
    provides: schema-v2 `trips` table + AppDatabase optional-executor constructor pattern
  - phase: 01-scaffolding (Plan 01-02)
    provides: FK cascade policy (CASCADE on trip children), MigrationStrategy `beforeOpen` PRAGMA discipline, `drift_schemas/*.json` committed source-of-truth
provides:
  - AppDatabase schemaVersion=3 with migration v2→v3
  - OverpassWayCache table (composite PK on slippy z-tile) + OverpassWayCacheDao (put/get/sweepTtl/enforceLruBudget)
  - PendingRoadFetches table (FK cascade on trip) + PendingRoadFetchesDao (enqueue/list/getByTrip/incrementAttempts/removeByTrip)
  - drift_schemas/drift_schema_v3.json (structural v3; 04-15 will re-dump when adding `TripStatus.pendingRoadData`)
  - 4 migration tests + 10 DAO tests (all green)
affects:
  - 04-15-way-candidate-source-and-trip-flow (consumes both DAOs from the Wave 2 flow layer)
  - Phase 5 (matcher may read from `overpass_way_cache` payloads to reconstruct WayCandidate lists)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Composite-PK Drift table via `Set<Column<Object>> get primaryKey` (first in the codebase — trips/trip_points use synthetic auto-increment ids)"
    - "@DataClassName override on PendingRoadFetches — drift's default depluralization produces `PendingRoadFetche` (missing final 'h'); explicit override yields the clean `PendingRoadFetch` row-class name"
    - "select-then-update fallback for atomic column increments — `PendingRoadFetchesCompanion.attempts` takes `Value<int>`, not `Expression<int>`, so `CustomExpression('attempts + 1')` does not compile against drift ^2.34.0 (plan §Deviations authorised this)"
    - "@DriftAccessor DAOs wired via `daos:` on @DriftDatabase — first codebase use (Wave 1 TripsDao was plain DatabaseAccessor per STATE Plan 03-01 to avoid a circular-import failure)"
    - "gzipped raw JSON blob cache keyed by slippy z-tile — decouples storage format from parser evolution"

key-files:
  created:
    - lib/core/db/tables/overpass_way_cache_table.dart
    - lib/core/db/tables/pending_road_fetches_table.dart
    - lib/core/db/daos/overpass_way_cache_dao.dart
    - lib/core/db/daos/pending_road_fetches_dao.dart
    - drift_schemas/drift_schema_v3.json
    - test/core/db/migration_v2_to_v3_test.dart
    - test/core/db/overpass_way_cache_dao_test.dart
    - test/core/db/pending_road_fetches_dao_test.dart
  modified:
    - lib/core/db/app_database.dart
    - test/core/db/app_database_open_test.dart

key-decisions:
  - "schemaVersion bumped 2 → 3; `beforeOpen` block unchanged (PRAGMAs foreign_keys=ON + journal_mode=WAL). `if (from < 2)` v1→v2 branch preserved; `if (from < 3)` branch adds the two new tables via `m.createTable(...)`."
  - "OverpassWayCache primary key is the composite (tileZ, tileX, tileY) — validates the 04-13 payload-probe verdict that mandatory tile-splitting for v1 is essential, not optional. The (z, x, y) shape is the natural key; no synthetic id column."
  - "LRU eviction: high water = 50 MB (`_lruHighWaterBytes`), low water = 40 MB (`_lruLowWaterBytes`), oldest-`fetchedAt` first. Test asserts steady state in [40, 48] MB after a 30x 2 MB seed (eviction fires once at insert #26 draining 6 rows). O(N) delete loop is acceptable for the ~30-60-tile working set."
  - "TTL = 30 days (RESEARCH §2 recommendation) via `sweepTtl({DateTime? now})` — injectable clock for deterministic tests."
  - "PendingRoadFetches uses `references(Trips, #id, onDelete: KeyAction.cascade)` — same shape as `TripPoints -> Trips` (Plan 01-02 STATE decision). Trip delete cascades; drain-success is manual via `removeByTrip`."
  - "`incrementAttempts` fell back to select-then-update per plan §Deviations. Drift ^2.34.0 rejects `CustomExpression('attempts + 1')` for column companions (Value<int> vs Expression<int> mismatch). One extra read per attempt-bump is acceptable."
  - "@DataClassName('PendingRoadFetch') on the table — drift's auto-depluralization yielded `PendingRoadFetche` (drops final 'h' from 'fetches'), which is ugly and confusing. Explicit override fixes the row-class name."
  - "DateTime fixtures in DAO tests use local time (not `DateTime.utc(...)`). Drift's default DateTime persistence is int-epoch, which drops the UTC flag on round-trip; asserting on `millisecondsSinceEpoch` (not equality) is the durable pattern."
  - "app_database_open_test.dart's containsAll assertion widened from 7 to 9 tables — folded into Task 3's commit as downstream hygiene from the schema expansion."

patterns-established:
  - "Composite-PK Drift table via `Set<Column<Object>> get primaryKey` — first codebase example. Downstream: any future tile-keyed table (matched-segment cache, etc.) can copy this shape."
  - "@DataClassName override discipline: check the drift-generated row-class name after codegen when the plural-table-name → singular-row-name transform is non-obvious. `Fetches → Fetche` is the trap this plan hit."
  - "Migration test template pattern: 4 tests per migration branch — (a) clean upgrade, (b) existing-row survival, (c) new-tables-are-empty, (d) at-least-one-write-round-trip on a new table's PK. Mirrors the v1→v2 template with the compsite-PK write added."

# Metrics
duration: 20min
completed: 2026-07-08
---

# Phase 4 Plan 14: Drift Migration v3 and DAOs Summary

**App DB v3: `overpass_way_cache` (gzipped JSON per slippy z-tile, 50 MB LRU / 30-day TTL) + `pending_road_fetches` (FK-cascade trip queue). Two DAOs surfacing the exact operations 04-15's Wave 2 flow layer needs. Zero touch to the `beforeOpen` PRAGMA block; migration is a 2-line `m.createTable(...)` branch guarded by `from < 3`.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-07-08T11:54:45Z
- **Completed:** 2026-07-08T12:14:32Z
- **Tasks:** 3 (all `type="auto"`; no checkpoints)
- **Files created:** 8
- **Files modified:** 2

## Accomplishments

- **Schema v3 with two new tables.** `overpass_way_cache` is keyed by the composite (tileZ, tileX, tileY) slippy tile — no synthetic id column. Payload is a gzipped raw-Overpass-JSON blob (`BlobColumn get payloadGzip`), with `payloadBytes` denormalized for cheap `SUM()` in the LRU enforcer. `pending_road_fetches` mirrors the trip-child cascade policy (Plan 01-02) — `references(Trips, #id, onDelete: KeyAction.cascade)` drops queued fetches whenever their parent trip is deleted.
- **OverpassWayCacheDao (5 operations).** `put()` upserts via `insertOnConflictUpdate` and immediately runs `_enforceLruBudget()`. `getByTile(z, x, y)` returns null on miss (04-15's cache lookup surface). `sweepTtl({DateTime? now})` deletes rows with `fetchedAt < now - 30d`. `totalBytes()` runs the `COALESCE(SUM(payload_bytes), 0)` aggregate. `_enforceLruBudget()` is a two-step drain — check `total > 50 MB` high water; if triggered, walk oldest-fetchedAt-first and delete until running total falls to ≤40 MB low water. O(N) delete loop, acceptable for the ~30-60-tile working set.
- **PendingRoadFetchesDao (5 operations).** `enqueue(...)` inserts a bbox for a trip; returns row id. `getByTrip(tripId)` / `listPending()` are the drain worker's read paths (oldest-createdAt-first). `incrementAttempts(id, {DateTime? now})` does select-then-update to bump `attempts` and stamp `lastAttemptAt` — fallback per plan §Deviations, drift ^2.34.0 rejects `CustomExpression('attempts + 1')` inside a companion (`Value<int>` vs `Expression<int>`). `removeByTrip(tripId)` cleans up after a successful drain; FK cascade handles trip-delete case implicitly.
- **Migration test (4 assertions).** `SchemaVerifier` for v2→v3 verifies the migration runs clean, existing v2 trip rows survive unchanged, both new tables are empty post-migration, and the composite (z, x, y) primary key accepts inserts.
- **DAO tests (10 total, all green).** OverpassWayCacheDao: round-trip, upsert-collapse on same tile ID, TTL sweep with injected clock, LRU drain window in [40, 48] MB after 30× 2 MB seed, empty-table `totalBytes`. PendingRoadFetchesDao: round-trip, oldest-first ordering, attempts bump + `lastAttemptAt` stamp, `removeByTrip` preserves other trips, FK cascade on trip delete.
- **`drift_schemas/drift_schema_v3.json` committed.** Structural v3; 04-15 will re-dump this file when it adds the `TripStatus.pendingRoadData` enum value (per plan frontmatter). Both writes are intentional — the schema JSON is a Dart-side data-shape snapshot; 04-15's diff is an enum widening on an existing `trips.status` column, not a structural change.
- **Downstream test hygiene.** `app_database_open_test.dart` was asserting `containsAll` over the pre-04-14 seven-table set. Bumped to nine tables (adds `overpass_way_cache` and `pending_road_fetches`) and retitled `all 7 tables` → `all 9 tables` — folded into Task 3's commit as downstream hygiene from the schema expansion (the test would still pass because `containsAll` is subset-checking, but the title lied about coverage).

## Task Commits

Each task committed atomically per project CLAUDE.md rules (files staged individually — no `git add -A` / `git commit -a`, per Wave-hygiene STATE decisions 2026-07-03 / 2026-07-06 / 04-15-parallel-hygiene 03-1-02 reinforcement):

1. **Task 1: v3 tables + migration + drift_schema_v3.json + migration test** — `cb0a6d6` (feat)
2. **Task 2: OverpassWayCacheDao with LRU + TTL** — `28e42c6` (feat)
3. **Task 3: PendingRoadFetchesDao with cascade + increment** — `e16351c` (feat)

Plan metadata commit follows this SUMMARY.

## Files Created/Modified

**Created (8):**

- `lib/core/db/tables/overpass_way_cache_table.dart` — Drift table, composite (z, x, y) PK, gzip BLOB, wayCount, payloadBytes, fetchedAt with `currentDateAndTime` default.
- `lib/core/db/tables/pending_road_fetches_table.dart` — Drift table with `@DataClassName('PendingRoadFetch')`, FK cascade on `tripId`, four bbox floats, `attempts` with default `0`, nullable `lastAttemptAt`, `createdAt`.
- `lib/core/db/daos/overpass_way_cache_dao.dart` — @DriftAccessor DAO with put/get/sweepTtl/enforceLruBudget/totalBytes.
- `lib/core/db/daos/pending_road_fetches_dao.dart` — @DriftAccessor DAO with enqueue/list/getByTrip/incrementAttempts/removeByTrip.
- `drift_schemas/drift_schema_v3.json` — schema dump via `drift_dev schema dump`.
- `test/core/db/migration_v2_to_v3_test.dart` — 4-test migration verification.
- `test/core/db/overpass_way_cache_dao_test.dart` — 5-test DAO surface coverage.
- `test/core/db/pending_road_fetches_dao_test.dart` — 5-test DAO + FK cascade coverage.

**Modified (2):**

- `lib/core/db/app_database.dart` — schemaVersion 2→3, tables list widened by 2, `daos: [OverpassWayCacheDao, PendingRoadFetchesDao]`, `if (from < 3)` migration branch. `beforeOpen` block untouched.
- `test/core/db/app_database_open_test.dart` — `containsAll` widened from 7 to 9 tables; test title bumped.

## Decisions Made

- **Composite-PK on OverpassWayCache is essential, not optional.** 04-13's payload probe (Nuremberg 100×100 km → 294.76 MiB uncompressed / 3.7 s parse) validated the plan's design decision. A single z12 slippy tile covers ~9.7 × 9.7 km at Berlin latitude, so a Kfz-density urban tile fits comfortably under the 5 MB / 3 s thresholds. `Set<Column<Object>> get primaryKey => {tileZ, tileX, tileY}` is the natural key — no synthetic id, no secondary index.
- **LRU high water / low water = 50 MB / 40 MB.** Plan-specified. The 10 MB gap between water marks is the drain amortization budget — reduces the frequency of eviction runs relative to a naïve "keep total under 50 MB" strategy.
- **TTL 30 days (RESEARCH §2).** OSM data churn on driven roads is ~monthly. Longer TTL bloats the cache with stale data; shorter TTL re-hits Overpass unnecessarily. Injectable `now` in `sweepTtl` for deterministic tests.
- **`incrementAttempts` fell back to select-then-update.** Plan authorised this in §Deviations. `PendingRoadFetchesCompanion.attempts` is typed `Value<int>`; the `CustomExpression<int>('attempts + 1')` idiom would need `Expression<int>` on the companion field to compile. One extra read per attempt-bump is acceptable — retry cadence is minutes-to-hours, not milliseconds.
- **@DataClassName('PendingRoadFetch') override.** Drift's default table-name → data-class name transform depluralized `PendingRoadFetches` to `PendingRoadFetche` (drops final 'h', not final 's'). Explicit `@DataClassName('PendingRoadFetch')` fixes the row-class name to `PendingRoadFetch`.
- **Local DateTime, not UTC, in tests.** Drift persists `DateTime` as int-epoch which drops the UTC flag on round-trip. `expect(row.fetchedAt, now)` fails with a UTC/local mismatch; `expect(row.fetchedAt.millisecondsSinceEpoch, now.millisecondsSinceEpoch)` is the durable pattern (or just use local time both sides).
- **`@DriftAccessor(tables: [...])` DAOs wired via `daos:` on @DriftDatabase.** First codebase use. Wave 1 `TripsDao` was plain `DatabaseAccessor` per STATE Plan 03-01 (@DriftAccessor + cross-feature table imports hit a circular-import failure). Here both DAOs' tables are in the same directory (`lib/core/db/tables/`), so the annotation resolves cleanly. Future DAOs should prefer @DriftAccessor unless the circular-import trap resurfaces.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `dart run drift_dev schema generate lib/core/db/app_database.dart drift_schemas/` fails ("input directory does not exist")**

- **Found during:** Task 1 codegen
- **Issue:** The plan's exact command uses `--data-classes --companions` after `drift_schemas/`, but drift_dev's `schema generate` subcommand expects `<input_json_dir> <output_dart_dir>` as positional args, and reads schema JSONs from the input. When called with only one directory, it errors with "input directory does not exist."
- **Fix:** Split into two invocations — `drift_dev schema dump <app_database.dart> <drift_schemas/drift_schema_v3.json>` (write the schema JSON) followed by `drift_dev schema generate <drift_schemas/> <test/generated_migrations/>` (regenerate `schema.dart` + `schema_v1.dart` + `schema_v2.dart` + `schema_v3.dart` in the gitignored migrations dir).
- **Files affected:** none committed (the fix is in the invocation ordering, not code); both artifacts are gitignored except `drift_schemas/drift_schema_v3.json` (committed in Task 1).
- **Commit:** folded into Task 1 (`cb0a6d6`) — no code change; the working artifacts are correct.

**2. [Rule 1 - Bug] `CustomExpression('attempts + 1')` did not compile against drift ^2.34.0**

- **Found during:** Task 3 `flutter analyze`
- **Issue:** `error - The argument type 'CustomExpression<int>' can't be assigned to the parameter type 'Value<int>'.` `PendingRoadFetchesCompanion.attempts` takes `Value<int>`, not `Expression<int>`. The plan sketch used the CustomExpression idiom that would work in a raw `update.write(customExpression, ...)` but not inside a companion field assignment.
- **Fix:** Switched to select-then-update — `getSingleOrNull` on the id, return 0 if row missing, otherwise `write(companion with Value(row.attempts + 1))`. Plan §Deviations explicitly authorised this fallback ("one extra read per attempt-bump is fine").
- **Files modified:** `lib/core/db/daos/pending_road_fetches_dao.dart`
- **Commit:** Task 3 (`e16351c`)

**3. [Rule 1 - Bug] Drift's default depluralization produced ugly `PendingRoadFetche` row class**

- **Found during:** Task 3 DAO write
- **Issue:** Drift codegen tried to singularize `PendingRoadFetches` by stripping the trailing 's' → `PendingRoadFetche` (drops final 'h', not final 'es'). Any consumer signature `Future<PendingRoadFetche?>` reads as a typo.
- **Fix:** Added `@DataClassName('PendingRoadFetch')` above the `PendingRoadFetches` table class, then re-ran `dart run build_runner build`. Re-dumped `drift_schemas/drift_schema_v3.json`; verified no diff (the DataClassName annotation is Dart-side only, doesn't affect SQL schema).
- **Files modified:** `lib/core/db/tables/pending_road_fetches_table.dart`
- **Commit:** Task 3 (`e16351c`)

**4. [Rule 1 - Bug] Round-trip DateTime assertion failed with UTC vs local timezone mismatch**

- **Found during:** Task 2 first test run — `Expected: DateTime:<2026-07-08 12:00:00.000Z>, Actual: DateTime:<2026-07-08 14:00:00.000>`
- **Issue:** Drift stores `DateTime` as int-epoch milliseconds (seconds when `storeDateTimeAsText: false`, which is the default). On read, drift constructs a local-timezone `DateTime` from that int. `DateTime.utc(2026, 7, 8, 12)` written in, `DateTime(2026, 7, 8, 14)` local read out (dev box is UTC+2 CEST).
- **Fix:** Switched all test fixtures to `DateTime(...)` (local); assertions use `millisecondsSinceEpoch` on both sides to be timezone-agnostic.
- **Files modified:** `test/core/db/overpass_way_cache_dao_test.dart` (also propagated to `test/core/db/pending_road_fetches_dao_test.dart` before its first run — no failing test in that file).
- **Commit:** Task 2 (`28e42c6`)

**5. [Rule 1 - Bug] LRU test's low-water assertion mismatched the seed pattern's steady state**

- **Found during:** Task 2 first LRU test run — `Expected: a value less than or equal to <41943040>, Actual: <50331648>` (initial), then `Expected: a value less than or equal to <44040192>, Actual: <50331648>` (tightened)
- **Issue:** With 2 MB rows and a 30-row seed, eviction fires exactly once — at insert #26 (26 × 2 MB = 52 MB, which exceeds the 50 MB high water). The drain removes 6 rows (52 → 40 MB), then inserts #27..#30 add 4 more rows for a steady state of **24 rows × 2 MB = 48 MB**, not the 40-42 MB the naïve "drain to low water" mental model would predict.
- **Fix:** Bounded the assertion to `[40 MB, 48 MB]` with a docstring explaining the arithmetic. The invariant under test is unchanged (total ≤ 50 MB, eviction did occur, oldest rows gone, newest rows survive) — only the tolerance widened to match the actual algorithm's steady state.
- **Files modified:** `test/core/db/overpass_way_cache_dao_test.dart`
- **Commit:** Task 2 (`28e42c6`)

### Non-blocking follow-ups (not auto-fixes)

**6. drift_dev schema generate produced no unrelated file changes.**

- Plan §Deviations warned: "if `drift_dev schema generate` unexpectedly modifies unrelated v1/v2 schema files, escalate." Actual behavior: writes `schema.dart` + `schema_v1.dart` + `schema_v2.dart` + `schema_v3.dart` in `test/generated_migrations/` (all gitignored per project `.gitignore`), and `drift_schema_v3.json` in `drift_schemas/`. v1/v2 JSONs untouched. No escalation needed.

**7. Cross-plan confirmation: 04-13 payload probe validates the composite-PK schema shape.**

- 04-13 established MANDATORY tile-splitting for v1 (Berlin→Munich 504'd; 100×100 km Nuremberg → 294 MiB / 3.7 s parse — both plan thresholds fail decisively). The composite (tileZ, tileX, tileY) primary key on `overpass_way_cache` is the schema-level realization of that decision — 04-15 will implement the tile-bbox math and populate the cache one slippy tile at a time. This plan makes the schema ready to receive that traffic.

---

**Total deviations:** 5 auto-fixes (3× Rule 1 bugs — DAO codegen name, LRU-arithmetic-off-by-one, DateTime UTC/local mismatch; 1× Rule 1 bug — drift companion Expression-vs-Value type mismatch; 1× Rule 3 blocking — `drift_dev schema generate` invocation ordering). No architectural checkpoints.
**Impact on plan:** None — plan executed to spec; the deviations are routine Ralph-Loop cleanup + one plan-authorized fallback (incrementAttempts).

## Authentication Gates

None. Everything runs offline (Drift in-memory tests + local schema dump).

## Issues Encountered

- **drift_dev `schema generate` positional-arg confusion** — see Deviation 1. First-time drift-schema-generate call in this codebase; the syntax split (dump vs generate) is worth noting for future migration plans.
- **`unnecessary_ignore` + `prefer_single_quotes`** — routine Ralph tight-loop cleanup on the migration test's SQL literal.
- **`unnecessary_import` on `dart:typed_data` + `matching_super_parameters` on `super.db`** — routine Ralph cleanup on the OverpassWayCacheDao first draft.

## Success Criteria

| # | Criterion | Status |
| ---- | ---- | ---- |
| 1 | App DB schemaVersion = 3 | PASS (`grep schemaVersion` → line 39 returns `3`) |
| 2 | Both tables exist; migration v2→v3 test green | PASS (4 migration tests green) |
| 3 | `drift_schemas/drift_schema_v3.json` committed | PASS (Task 1 commit `cb0a6d6`) |
| 4 | Both DAOs implemented with tests green | PASS (5 + 5 = 10 DAO tests green) |
| 5 | LRU eviction triggers at 50 MB; drains to 40 MB | PASS (steady-state test asserts total ∈ [40, 48] MB post-eviction) |
| 6 | TTL sweep at 30 days | PASS (`sweepTtl` test with 31-day-old + 29-day-old rows) |
| 7 | FK cascade from trips → pending_road_fetches verified | PASS (`cascade delete when trip is deleted` test) |
| 8 | `flutter analyze` clean; existing v1→v2 migration test still green | PASS (analyze: `No issues found!`; full suite: 229/229 green) |

## User Setup Required

None new. Wave 2 continues.

## Downstream implications

**For 04-15 (way-candidate source + trip flow):**

- **WayCandidateSource consumes OverpassWayCacheDao.** `getByTile(z, x, y)` is the cache-hit path; on miss, call `OverpassClient.fetchWaysInBbox(...)` (04-13) and `put(z, x, y, payloadGzip, wayCount)` to populate the cache. Slippy tile ID computation lives in 04-15 — this plan just makes the schema ready.
- **Trip-start bbox pre-fetch coordinator uses PendingRoadFetchesDao.** On network failure during pre-fetch, `enqueue(tripId, bbox)` queues for retry. Drain worker walks `listPending()` (oldest first), attempts each, calls `incrementAttempts(id)` on failure with exponential backoff, `removeByTrip(tripId)` on success.
- **`TripStatus.pendingRoadData` enum value.** Per this plan's frontmatter note, 04-15 will add this enum value to `TripStatus`, which triggers a re-dump of `drift_schemas/drift_schema_v3.json`. That re-dump is a legitimate 04-15 commit — do NOT preemptively add the enum value here.

**For Phase 5 (matcher):**

- **OverpassWayCache payload format is stable across parser evolution.** Storing gzipped raw JSON (not parsed WayCandidate objects) means Phase 5 can rev the parser without invalidating the cache — the matcher decodes on read.

## Next Phase Readiness

**Ready for 04-15 (WayCandidateSource + trip flow).** No blockers. Verified:

- `git status --porcelain` clean (only `.idea/` untracked)
- `flutter analyze` clean
- `flutter test` 229/229 green (previously 216 in 04-13; net +13 new tests here: 4 migration + 5 + 5 DAO — actually +14 minus 1 title change on `app_database_open_test`)

**Grep tripwires post-04-14:**

- `schemaVersion => 3` — in `lib/core/db/app_database.dart:39`
- `OverpassWayCache`, `PendingRoadFetches` — both in `@DriftDatabase(tables: [...])` list
- `if (from < 3)` — in migration `onUpgrade`
- `daos: [OverpassWayCacheDao, PendingRoadFetchesDao]` — on @DriftDatabase
- `drift_schemas/drift_schema_v3.json` — committed
- `test/generated_migrations/schema_v3.dart` — gitignored, regenerated on-demand
- `@DataClassName('PendingRoadFetch')` — on the pending table (guards against the Fetche/Fetch drift-codegen trap)

---
*Phase: 04-osm-pipeline*
*Completed: 2026-07-08*
