---
id: 04-14
phase: 04-osm-pipeline
plan: 14
type: execute
wave: 2
wave_ordering: serial-within-wave
wave_serial_order: 2  # runs after 04-13
depends_on: [04-13]
files_modified:
  - lib/core/db/app_database.dart
  - lib/core/db/tables/overpass_way_cache.dart
  - lib/core/db/tables/pending_road_fetches.dart
  - lib/core/db/daos/overpass_way_cache_dao.dart
  - lib/core/db/daos/pending_road_fetches_dao.dart
  - drift_schemas/drift_schema_v3.json
  - test/core/db/migration_v2_to_v3_test.dart
  - test/core/db/overpass_way_cache_dao_test.dart
  - test/core/db/pending_road_fetches_dao_test.dart
autonomous: true
requirements: [OSM-03, OSM-06]

must_haves:
  truths:
    - "App DB is at schema v3; migration v2→v3 creates `overpass_way_cache` + `pending_road_fetches` tables idempotently."
    - "SchemaVerifier test for v2→v3 exists and passes (mirrors the existing v1→v2 test pattern)."
    - "`overpass_way_cache` is keyed by (tileZ, tileX, tileY) slippy tile ID; payload column stores gzipped raw JSON blob; `fetched_at` timestamp drives TTL; LRU eviction budget = 50 MB."
    - "`pending_road_fetches` stores (trip_id, bbox, attempts, last_attempt_at) with cascade-on-trip-delete; supports enqueue + dequeue + retry-with-backoff by the Wave 2's flow layer (04-15)."
    - "DAOs expose the operations 04-15 needs: put/get by tile ID; TTL sweep; LRU eviction; enqueue/list pending; increment attempt count."
    - "`drift_schemas/drift_schema_v3.json` is committed (source of truth per project CLAUDE.md; `test/generated_migrations/` remains gitignored)."
    - "codegen (`build_runner build` + `drift_dev schema generate`) runs cleanly and generated files are current before `flutter analyze` (per project rule)."
  artifacts:
    - path: "lib/core/db/tables/overpass_way_cache.dart"
      provides: "Drift table definition — composite PK on (tileZ, tileX, tileY), payloadGzip BLOB, fetchedAt, wayCount, payloadBytes."
      min_lines: 30
    - path: "lib/core/db/tables/pending_road_fetches.dart"
      provides: "Drift table — FK trip_id (cascade), bbox floats, attempts, lastAttemptAt, createdAt."
      min_lines: 30
    - path: "lib/core/db/daos/overpass_way_cache_dao.dart"
      provides: "put/get/sweepTtl/enforceLruBudget with 50MB threshold."
      min_lines: 80
    - path: "lib/core/db/daos/pending_road_fetches_dao.dart"
      provides: "enqueue/dequeue/list/incrementAttempts/removeByTrip."
      min_lines: 60
    - path: "drift_schemas/drift_schema_v3.json"
      provides: "Schema JSON exported via drift_dev; commit-tracked. NOTE: 04-14 emits the structural v3 schema; 04-15 finalizes v3 by adding the `pendingRoadData` value to the TripStatus enum and re-running `drift_dev schema dump`, which overwrites this file. Both writes are intentional — v3 is a single logical schema."
    - path: "test/core/db/migration_v2_to_v3_test.dart"
      provides: "Seed a v2 DB, run migration, assert both new tables exist and are empty."
      min_lines: 40
  key_links:
    - from: "lib/core/db/app_database.dart"
      to: "lib/core/db/tables/overpass_way_cache.dart"
      via: "@DriftDatabase(tables: [..., OverpassWayCache, PendingRoadFetches])"
      pattern: "OverpassWayCache|PendingRoadFetches"
    - from: "lib/core/db/app_database.dart"
      to: "MigrationStrategy onUpgrade"
      via: "if (from < 3) createTable(overpassWayCache) + createTable(pendingRoadFetches)"
      pattern: "if \\(from < 3\\)"
---

## Goal

Ship App DB migration v2→v3 with the two new tables Wave 2 needs: `overpass_way_cache` (compressed JSON blob cache keyed by slippy z12 tile) and `pending_road_fetches` (offline-trip queue). DAOs expose put/get/sweep/LRU-evict for the cache and enqueue/list/retry for the queue. No app-integration wiring yet — 04-15 consumes these DAOs.

## Context

- **Wave-2 serial ordering:** 04-13 → 04-14 → 04-15 are all `wave: 2` but MUST run serially in plan-number order. 04-14 depends on 04-13. 04-15 consumes both 04-13 and 04-14 outputs. Not a parallel-wave. The `wave_ordering: serial-within-wave` frontmatter annotation makes this explicit for the orchestrator.

- Research: `.planning/phases/04-osm-pipeline/04-RESEARCH.md` §5 (Drift migration pattern, cache schema shape, LRU eviction, pending queue design).
- Existing pattern: `lib/core/db/app_database.dart:32-54` (v1→v2 migration). Mirror the shape exactly for v2→v3.
- Existing migration test: `test/core/db/migration_v1_to_v2_test.dart` — template for v2→v3.
- Cache design: raw gzipped JSON blob per z12 tile. Do NOT store parsed ways in a normalized table — Phase 5 can add that later if needed (see RESEARCH §5 "parse-and-store approach" note).
- Budget: 50 MB compressed; LRU evict oldest fetchedAt until under 40 MB when writes cross the threshold.
- TTL: 30 days (RESEARCH §2 recommendation).
- Project rule: `build_runner build` + `drift_dev schema generate` MUST run before `flutter analyze` (generated `.g.dart` files are gitignored).

## Tasks

<task type="auto">
  <name>Task 1: Define tables + wire into @DriftDatabase + migration + schema export</name>
  <files>
    lib/core/db/tables/overpass_way_cache.dart
    lib/core/db/tables/pending_road_fetches.dart
    lib/core/db/app_database.dart
    drift_schemas/drift_schema_v3.json
    test/core/db/migration_v2_to_v3_test.dart
  </files>
  <intent>Schema + migration + test — the DB skeleton.</intent>
  <action>
    **`lib/core/db/tables/overpass_way_cache.dart`:**
    ```dart
    import 'package:drift/drift.dart';

    class OverpassWayCache extends Table {
      IntColumn get tileZ => integer()();
      IntColumn get tileX => integer()();
      IntColumn get tileY => integer()();
      DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();
      IntColumn get wayCount => integer()();
      BlobColumn get payloadGzip => blob()();
      IntColumn get payloadBytes => integer()();

      @override
      Set<Column> get primaryKey => {tileZ, tileX, tileY};
    }
    ```

    **`lib/core/db/tables/pending_road_fetches.dart`:**
    ```dart
    import 'package:drift/drift.dart';
    import 'package:auto_explore/core/db/tables/trips.dart';

    class PendingRoadFetches extends Table {
      IntColumn get id => integer().autoIncrement()();
      IntColumn get tripId => integer()
          .references(Trips, #id, onDelete: KeyAction.cascade)();
      RealColumn get bboxMinLat => real()();
      RealColumn get bboxMinLon => real()();
      RealColumn get bboxMaxLat => real()();
      RealColumn get bboxMaxLon => real()();
      IntColumn get attempts => integer().withDefault(const Constant(0))();
      DateTimeColumn get lastAttemptAt => dateTime().nullable()();
      DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
    }
    ```
    Confirm the `Trips` table's ID column name is actually `#id` — if it's `#tripId` or similar, adjust the reference.

    **`lib/core/db/app_database.dart`:**
    - Update `schemaVersion` from 2 to 3.
    - Add both tables to `@DriftDatabase(tables: [...])` list.
    - Extend `onUpgrade`:
      ```dart
      if (from < 3) {
        await m.createTable(overpassWayCache);
        await m.createTable(pendingRoadFetches);
      }
      ```
    - `beforeOpen` block (WAL + FK pragmas) stays unchanged.

    **Regenerate:**
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    dart run drift_dev schema generate lib/core/db/app_database.dart drift_schemas/ --data-classes --companions
    dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/drift_schema_v3.json
    ```
    Commit `drift_schemas/drift_schema_v3.json`.

    **`test/core/db/migration_v2_to_v3_test.dart`:**
    Mirror `test/core/db/migration_v1_to_v2_test.dart`:
    - Use `test/generated_migrations/schema_v2.dart` (auto-generated from JSON) to seed a v2 DB in memory.
    - Run `SchemaVerifier` for v2→v3.
    - Assert both new tables exist post-migration.
    - Assert both are empty post-migration.
    - Assert existing v2 rows (trips, fixes) survive the migration unchanged.
  </action>
  <verify>
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    dart run drift_dev schema generate lib/core/db/app_database.dart drift_schemas/
    flutter analyze
    flutter test test/core/db/migration_v2_to_v3_test.dart
    test -f drift_schemas/drift_schema_v3.json
    ```
    Codegen clean; analyze clean; migration test green; schema JSON committed.
  </verify>
</task>

<task type="auto">
  <name>Task 2: OverpassWayCacheDao — put/get/sweepTtl/enforceLruBudget</name>
  <files>
    lib/core/db/daos/overpass_way_cache_dao.dart
    lib/core/db/app_database.dart
    test/core/db/overpass_way_cache_dao_test.dart
  </files>
  <intent>DAO surface Wave 2's flow (04-15) needs.</intent>
  <action>
    **`lib/core/db/daos/overpass_way_cache_dao.dart`:**
    ```dart
    @DriftAccessor(tables: [OverpassWayCache])
    class OverpassWayCacheDao extends DatabaseAccessor<AppDatabase>
        with _$OverpassWayCacheDaoMixin {
      OverpassWayCacheDao(super.db);

      static const _lruHighWaterBytes = 50 * 1024 * 1024;   // 50 MB
      static const _lruLowWaterBytes  = 40 * 1024 * 1024;   // 40 MB target after evict
      static const _ttl = Duration(days: 30);

      Future<OverpassWayCacheData?> getByTile(int z, int x, int y) async {
        return (select(overpassWayCache)
              ..where((t) => t.tileZ.equals(z) & t.tileX.equals(x) & t.tileY.equals(y)))
            .getSingleOrNull();
      }

      /// Upsert cache entry; enforces LRU budget after write.
      Future<void> put({
        required int z, required int x, required int y,
        required Uint8List payloadGzip,
        required int wayCount,
        DateTime? now,
      }) async {
        await into(overpassWayCache).insertOnConflictUpdate(
          OverpassWayCacheCompanion.insert(
            tileZ: z, tileX: x, tileY: y,
            fetchedAt: Value(now ?? DateTime.now()),
            wayCount: wayCount,
            payloadGzip: payloadGzip,
            payloadBytes: payloadGzip.length,
          ),
        );
        await _enforceLruBudget();
      }

      /// Removes rows older than TTL. Returns count deleted.
      Future<int> sweepTtl({DateTime? now}) async {
        final cutoff = (now ?? DateTime.now()).subtract(_ttl);
        return (delete(overpassWayCache)
              ..where((t) => t.fetchedAt.isSmallerThanValue(cutoff)))
            .go();
      }

      Future<int> totalBytes() async {
        final row = await customSelect(
          'SELECT COALESCE(SUM(payload_bytes), 0) AS bytes FROM overpass_way_cache',
          readsFrom: {overpassWayCache},
        ).getSingle();
        return row.read<int>('bytes');
      }

      Future<void> _enforceLruBudget() async {
        final total = await totalBytes();
        if (total <= _lruHighWaterBytes) return;

        // Delete oldest fetchedAt rows until <= low water.
        final target = _lruLowWaterBytes;
        var running = total;
        final oldest = await (select(overpassWayCache)
              ..orderBy([(t) => OrderingTerm.asc(t.fetchedAt)]))
            .get();
        for (final row in oldest) {
          if (running <= target) break;
          await (delete(overpassWayCache)
                ..where((t) =>
                    t.tileZ.equals(row.tileZ) &
                    t.tileX.equals(row.tileX) &
                    t.tileY.equals(row.tileY)))
              .go();
          running -= row.payloadBytes;
        }
      }
    }
    ```
    Wire `overpassWayCacheDao` accessor into `AppDatabase`.

    **Tests (`test/core/db/overpass_way_cache_dao_test.dart`):**
    1. `put + getByTile round-trip` — insert one row, read it back.
    2. `put upsert overwrites on same tile ID` — put same (z,x,y) twice; assert only one row exists.
    3. `sweepTtl removes rows older than 30 days` — inject `now`; seed with 31-day-old + 29-day-old rows; assert only old row deleted.
    4. `enforceLruBudget triggers on write above 50 MB` — seed 60 MB of rows (fake payloads), put one more; assert `totalBytes() <= 50MB` after put; assert LRU order (oldest deleted first).
    5. `totalBytes returns 0 on empty table`.

    Use in-memory Drift via `NativeDatabase.memory()`.
  </action>
  <verify>
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    flutter analyze
    flutter test test/core/db/overpass_way_cache_dao_test.dart
    ```
    All 5 tests green; analyze clean.
  </verify>
</task>

<task type="auto">
  <name>Task 3: PendingRoadFetchesDao — enqueue/list/dequeue/increment/removeByTrip</name>
  <files>
    lib/core/db/daos/pending_road_fetches_dao.dart
    lib/core/db/app_database.dart
    test/core/db/pending_road_fetches_dao_test.dart
  </files>
  <intent>Queue surface for offline-trip road-fetch retries.</intent>
  <action>
    **`lib/core/db/daos/pending_road_fetches_dao.dart`:**
    ```dart
    @DriftAccessor(tables: [PendingRoadFetches])
    class PendingRoadFetchesDao extends DatabaseAccessor<AppDatabase>
        with _$PendingRoadFetchesDaoMixin {
      PendingRoadFetchesDao(super.db);

      Future<int> enqueue({
        required int tripId,
        required double minLat, required double minLon,
        required double maxLat, required double maxLon,
      }) async {
        return into(pendingRoadFetches).insert(
          PendingRoadFetchesCompanion.insert(
            tripId: tripId,
            bboxMinLat: minLat, bboxMinLon: minLon,
            bboxMaxLat: maxLat, bboxMaxLon: maxLon,
          ),
        );
      }

      /// All pending fetches, oldest-first. Empty if none.
      Future<List<PendingRoadFetchData>> listPending() {
        return (select(pendingRoadFetches)
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
      }

      /// Fetches by trip ID.
      Future<PendingRoadFetchData?> getByTrip(int tripId) {
        return (select(pendingRoadFetches)
              ..where((t) => t.tripId.equals(tripId)))
            .getSingleOrNull();
      }

      Future<int> incrementAttempts(int id, {DateTime? now}) async {
        return (update(pendingRoadFetches)..where((t) => t.id.equals(id))).write(
          PendingRoadFetchesCompanion(
            attempts: const CustomExpression('attempts + 1'),
            lastAttemptAt: Value(now ?? DateTime.now()),
          ),
        );
      }

      Future<int> removeByTrip(int tripId) {
        return (delete(pendingRoadFetches)..where((t) => t.tripId.equals(tripId))).go();
      }
    }
    ```
    Wire the DAO into `AppDatabase`.

    **Tests (`test/core/db/pending_road_fetches_dao_test.dart`):**
    1. `enqueue + getByTrip round-trip`.
    2. `listPending returns oldest-first`.
    3. `incrementAttempts bumps count and updates lastAttemptAt` — inject fake `now`.
    4. `removeByTrip deletes matching rows` — enqueue for trip 1 + trip 2; remove trip 1; assert only trip 2 remains.
    5. `cascade delete when trip is deleted` — seed a trip via TripsDao, enqueue a pending, delete the trip; assert pending row is gone (FK cascade).

    Use in-memory Drift.
  </action>
  <verify>
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    flutter analyze
    flutter test test/core/db/pending_road_fetches_dao_test.dart
    ```
    All 5 tests green; analyze clean.
  </verify>
</task>

## Success Criteria

- App DB schemaVersion = 3.
- Both tables exist; migration v2→v3 test green.
- `drift_schemas/drift_schema_v3.json` committed.
- Both DAOs implemented with tests green.
- LRU eviction triggers at 50 MB; drains to 40 MB.
- TTL sweep at 30 days.
- FK cascade from trips → pending_road_fetches verified.
- `flutter analyze` clean; existing v1→v2 migration test still green (no regression).

## Ralph Loop

- Tight loop: `flutter analyze` after every change.
- Behavior-sensitive (DB migration + DAOs): `flutter test test/core/db/` after every task.
- Pre-push hook covers the rest.

## Deviations

- If `SchemaVerifier` for v2→v3 chokes because `test/generated_migrations/schema_v2.dart` doesn't yet exist, run `dart run drift_dev schema generate` first to produce it. If that regen unexpectedly modifies unrelated v1/v2 schema files, escalate — don't fight the tool.
- If the `Trips` table's ID column isn't `#id`, use whatever it actually is (grep the table definition first).
- If `CustomExpression('attempts + 1')` doesn't compile with the current drift version, fall back to `write(companion.copyWith(attempts: Value(row.attempts + 1)))` after a `select` — one extra read per attempt-bump is fine.

## Commit Strategy

- Task 1 commit: `feat(04-14): App DB v3 migration + overpass_way_cache + pending_road_fetches tables`
- Task 2 commit: `feat(04-14): OverpassWayCacheDao with LRU + TTL`
- Task 3 commit: `feat(04-14): PendingRoadFetchesDao with cascade + increment`
