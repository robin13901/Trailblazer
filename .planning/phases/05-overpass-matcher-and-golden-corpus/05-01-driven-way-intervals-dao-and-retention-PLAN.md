---
id: 05-01
phase: 05-overpass-matcher-and-golden-corpus
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/core/db/daos/driven_way_intervals_dao.dart
  - lib/core/db/app_database.dart
  - lib/features/trips/data/trips_dao.dart
  - lib/features/trips/data/trips_repository.dart
  - test/core/db/daos/driven_way_intervals_dao_test.dart
  - test/features/trips/data/trips_dao_retention_test.dart
autonomous: true
requirements: [MMT-06, MMT-10]

must_haves:
  truths:
    - "`DrivenWayIntervalsDao` exists in `lib/core/db/daos/` and is registered in `@DriftDatabase(daos: [...])`; `AppDatabase.drivenWayIntervalsDao` compiles."
    - "DAO exposes `insertBatch(List<DrivenWayIntervalsCompanion>)`, `getByTrip(int tripId)`, and `deleteByTrip(int tripId)`; all three round-trip through an in-memory Drift DB in tests."
    - "`TripsDao.deleteTripPointsForMatchedTripsOlderThan(DateTime cutoff)` deletes `trip_points` rows whose parent trip has at least one `driven_way_intervals` row with `matched_at < cutoff` and returns the count deleted."
    - "Retention sweep is idempotent: running it twice with the same cutoff deletes the same set once (second call is a no-op)."
    - "Schema version stays at 3 — no migration is added; the `driven_way_intervals` table is already defined in schema v3 and the retention sweep is a DELETE query, not a schema change."
  artifacts:
    - path: "lib/core/db/daos/driven_way_intervals_dao.dart"
      provides: "DAO for `driven_way_intervals` with batch insert, per-trip read, per-trip delete."
      min_lines: 60
    - path: "test/core/db/daos/driven_way_intervals_dao_test.dart"
      provides: "In-memory Drift test covering insertBatch/getByTrip/deleteByTrip + FK-SET-NULL survival on trip deletion."
      min_lines: 80
    - path: "test/features/trips/data/trips_dao_retention_test.dart"
      provides: "Retention sweep test: seeds two trips (one with matched intervals older than cutoff, one recent) + trip_points; asserts old points gone, recent points intact."
      min_lines: 60
  key_links:
    - from: "lib/core/db/app_database.dart"
      to: "lib/core/db/daos/driven_way_intervals_dao.dart"
      via: "@DriftDatabase(daos: [OverpassWayCacheDao, PendingRoadFetchesDao, DrivenWayIntervalsDao]) — codegen exposes `AppDatabase.drivenWayIntervalsDao` getter"
      pattern: "DrivenWayIntervalsDao"
    - from: "lib/features/trips/data/trips_dao.dart"
      to: "lib/core/db/tables/driven_intervals_table.dart"
      via: "correlated DELETE on trip_points using EXISTS subquery over driven_way_intervals"
      pattern: "deleteTripPointsForMatchedTripsOlderThan|driven_way_intervals"
---

## Goal

Ship the DB seam Phase 5 writes into: a `DrivenWayIntervalsDao` on the existing schema-v3 `driven_way_intervals` table, plus the raw-GPS retention sweep entry point that Plan 05-07 will call from `AppLifecycleState.resumed`. No schema migration — the table is already defined in v3 (`lib/core/db/tables/driven_intervals_table.dart` + `drift_schemas/drift_schema_v3.json`).

Resolves research §11 open question #2 (DAO lives under `lib/core/db/daos/`, matching the existing pattern) and #3 (retention sweep is a plain SQL delete callable from the resume hook — no WorkManager in Phase 5).

## Context

- Table exists already: `lib/core/db/tables/driven_intervals_table.dart` (id, way_id, trip_id, start_meters, end_meters, direction, matched_at). FK `trip_id → trips.id ON DELETE SET NULL` — intervals survive trip deletion by design.
- Existing DAO conventions: `lib/core/db/daos/overpass_way_cache_dao.dart` and `lib/core/db/daos/pending_road_fetches_dao.dart`. Both extend `DatabaseAccessor<AppDatabase>` and use `@DriftAccessor(tables: [...])` + a `part '..._dao.g.dart'` declaration.
- AppDatabase daos list already contains `[OverpassWayCacheDao, PendingRoadFetchesDao]` (line 33 of `app_database.dart`). Just append.
- TripsDao is under `lib/features/trips/data/trips_dao.dart` (not `lib/core/db/daos/` — inherited layout from Phase 1). It already has `transitionToPendingRoadData`, `transitionToPending`, `activeTrip`, `watchPoints`. Extend it in place.
- `TripsRepository` (`lib/features/trips/data/trips_repository.dart`) wraps every DAO call in `Result<T>` and `DomainError.wrap`. Follow that pattern for the new retention method.
- Existing test scaffold: `test/helpers/test_database.dart` gives in-memory Drift setups. Both DAO tests use it.
- MMT-06 defines the output shape (`way_id, start_m, end_m, direction, trip_id, timestamp`). The table already has all of these; `matched_at` is the "timestamp" column (naming is intentional — see driven_intervals_table.dart).
- MMT-10 defines the 30-day retention default. Phase 5 ships the mechanism, not the settings UI (that's Phase 10). Default is a compile-time constant here; a future `AppPrefs` override can override at call sites.

## Tasks

<task type="auto">
  <name>Task 1: DrivenWayIntervalsDao + register in AppDatabase</name>
  <files>
    lib/core/db/daos/driven_way_intervals_dao.dart
    lib/core/db/app_database.dart
    test/core/db/daos/driven_way_intervals_dao_test.dart
  </files>
  <intent>New DAO wired into Drift; three CRUD methods + tests.</intent>
  <action>
    **`lib/core/db/daos/driven_way_intervals_dao.dart`:**
    ```dart
    import 'package:auto_explore/core/db/app_database.dart';
    import 'package:auto_explore/core/db/tables/driven_intervals_table.dart';
    import 'package:drift/drift.dart';

    part 'driven_way_intervals_dao.g.dart';

    /// DAO for the `driven_way_intervals` table (schema v3).
    ///
    /// Consumed by the Phase 5 matcher isolate coordinator (Plan 05-07):
    /// * [insertBatch] — bulk-write the intervals produced by one HmmMatcher run.
    /// * [getByTrip] — read intervals for a trip (used by the golden corpus
    ///   test harness + Phase 6 inbox).
    /// * [deleteByTrip] — cancel path: user deletes an in-flight trip; the
    ///   coordinator drops any intervals already written.
    ///
    /// FK on `trip_id` is `ON DELETE SET NULL` (Phase-1 decision), so
    /// deleting a Trip row does NOT cascade to intervals; the coordinator
    /// must call [deleteByTrip] explicitly when cleaning up cancelled trips.
    @DriftAccessor(tables: [DrivenWayIntervals])
    class DrivenWayIntervalsDao extends DatabaseAccessor<AppDatabase>
        with _$DrivenWayIntervalsDaoMixin {
      DrivenWayIntervalsDao(super.attachedDatabase);

      Future<void> insertBatch(List<DrivenWayIntervalsCompanion> rows) {
        if (rows.isEmpty) return Future.value();
        return batch((b) => b.insertAll(drivenWayIntervals, rows));
      }

      Future<List<DrivenWayInterval>> getByTrip(int tripId) {
        return (select(drivenWayIntervals)
              ..where((t) => t.tripId.equals(tripId))
              ..orderBy([(t) => OrderingTerm.asc(t.matchedAt)]))
            .get();
      }

      Future<int> deleteByTrip(int tripId) {
        return (delete(drivenWayIntervals)
              ..where((t) => t.tripId.equals(tripId)))
            .go();
      }
    }
    ```

    **`lib/core/db/app_database.dart` (register):**
    - Add `import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';` at the top (alphabetized with other DAO imports).
    - Append `DrivenWayIntervalsDao` to the `daos: [...]` list on the `@DriftDatabase` annotation. Order (alphabetical): `[DrivenWayIntervalsDao, OverpassWayCacheDao, PendingRoadFetchesDao]`.

    **Codegen after edits:**
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    ```
    This regenerates `app_database.g.dart` and creates `driven_way_intervals_dao.g.dart` (the `_$DrivenWayIntervalsDaoMixin` mixin). Both are gitignored — do NOT commit `.g.dart` files.

    **Tests (`test/core/db/daos/driven_way_intervals_dao_test.dart`):**
    Use `test/helpers/test_database.dart` for the in-memory DB.
    1. `insertBatch writes N rows and getByTrip returns them ordered by matchedAt` — insert 3 rows spanning 2 trips; getByTrip(tripId=1) returns 2 rows.
    2. `insertBatch on empty list is a no-op` — no exception, count unchanged.
    3. `deleteByTrip removes only the target trip's rows` — insert for trips 1 + 2; deleteByTrip(1); assert trip 2's intervals intact.
    4. `intervals survive parent trip deletion (FK SET NULL)` — insert a trip + interval; delete the trip via `TripsDao.deleteTrip`; assert the interval row still exists with `trip_id IS NULL`.
    5. `direction default is 'forward'` — insert a companion without direction; read back; assert `direction == 'forward'`.
  </action>
  <verify>
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    flutter analyze
    flutter test test/core/db/daos/driven_way_intervals_dao_test.dart
    ```
    Analyze clean; 5 DAO tests green; `app_database.g.dart` regenerated without diffs to committed files.
  </verify>
  <done>DAO exists, is registered, all 5 tests pass, analyzer clean.</done>
</task>

<task type="auto">
  <name>Task 2: TripsDao retention sweep + repository wrapper</name>
  <files>
    lib/features/trips/data/trips_dao.dart
    lib/features/trips/data/trips_repository.dart
    test/features/trips/data/trips_dao_retention_test.dart
  </files>
  <intent>SQL DELETE for the 30-day retention sweep + Result-wrapped repository API.</intent>
  <action>
    **`lib/features/trips/data/trips_dao.dart`:** Add a new method (do NOT change existing methods).
    ```dart
    /// Delete `trip_points` rows for trips whose matched intervals are all
    /// older than [cutoff]. Returns the number of point rows deleted.
    ///
    /// A trip is eligible for point-sweep only if it has AT LEAST ONE row in
    /// `driven_way_intervals` (i.e. it has been matched). Unmatched trips
    /// retain their points indefinitely — the matcher must run first before
    /// the 30-day clock starts.
    ///
    /// Implemented as a correlated DELETE:
    ///
    ///   DELETE FROM trip_points
    ///   WHERE trip_id IN (
    ///     SELECT DISTINCT d.trip_id
    ///     FROM driven_way_intervals d
    ///     WHERE d.matched_at < ? AND d.trip_id IS NOT NULL
    ///   );
    ///
    /// The `matched_at < ?` predicate uses the OLDEST interval — we sweep
    /// only when every interval on that trip is stale. To keep the SQL
    /// simple, we use `MAX(matched_at)` in a HAVING clause:
    Future<int> deleteTripPointsForMatchedTripsOlderThan(
      DateTime cutoff,
    ) async {
      final rows = await customUpdate(
        'DELETE FROM trip_points '
        'WHERE trip_id IN ('
        '  SELECT d.trip_id FROM driven_way_intervals d '
        '  WHERE d.trip_id IS NOT NULL '
        '  GROUP BY d.trip_id '
        '  HAVING MAX(d.matched_at) < ?'
        ')',
        variables: [Variable.withDateTime(cutoff)],
        updates: {tripPoints},
        updateKind: UpdateKind.delete,
      );
      return rows;
    }
    ```

    **`lib/features/trips/data/trips_repository.dart`:** Add a `Result<int>`-wrapped call.
    ```dart
    /// 30-day raw-GPS retention sweep (MMT-10). Delegates to
    /// [TripsDao.deleteTripPointsForMatchedTripsOlderThan]. Wraps
    /// throwables in [DomainError] per the repository contract.
    ///
    /// [retention] defaults to 30 days; Phase 10 will override this from
    /// AppPrefs when the settings UI ships.
    Future<Result<int>> sweepRawGpsRetention({
      Duration retention = const Duration(days: 30),
      DateTime? now,
    }) async {
      try {
        final cutoff = (now ?? DateTime.now()).subtract(retention);
        final n = await _dao.deleteTripPointsForMatchedTripsOlderThan(cutoff);
        return Ok(n);
        // ignore: avoid_catches_without_on_clauses
      } catch (e, st) {
        return Err(DomainError.wrap(e, st));
      }
    }
    ```

    **Tests (`test/features/trips/data/trips_dao_retention_test.dart`):**
    1. `sweep with no matched trips returns 0 and deletes nothing`.
    2. `sweep deletes points for a trip whose only interval is older than cutoff` — insert trip + 3 trip_points + 1 driven_way_interval with matched_at = now - 40d; cutoff = now - 30d; assert 3 points deleted; trip row itself intact.
    3. `sweep KEEPS points for a trip with a recent matched interval` — insert trip + points + interval with matched_at = now - 10d; assert points untouched.
    4. `sweep KEEPS points for a trip with mixed-age intervals (max is still recent)` — insert trip + points + 2 intervals (matched_at = now-40d AND now-5d); MAX(matched_at) > cutoff so trip should be RETAINED. Assert points untouched.
    5. `sweep is idempotent` — call twice; second call returns 0 (points already gone).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/trips/data/trips_dao_retention_test.dart
    ```
    Analyze clean; all 5 retention tests green.
  </verify>
  <done>TripsDao retention method + repository wrapper both work; sweep respects MAX(matched_at) so partially-matched trips are preserved.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- `DrivenWayIntervalsDao` exists, is registered in `AppDatabase`, is reachable as `db.drivenWayIntervalsDao`.
- All 10 tests in the two new test files green.
- Schema version still 3 (unchanged); no new `.json` in `drift_schemas/`.
- `.g.dart` files regenerated but NOT committed.

## Ralph Loop

- Tight loop: `flutter analyze` after each task.
- Behavior-sensitive (both tasks touch DB): `flutter test` inside the loop for the two new test files.

## Commit Strategy

- Task 1 commit: `feat(05-01): DrivenWayIntervalsDao + AppDatabase registration`
- Task 2 commit: `feat(05-01): TripsDao retention sweep for matched-trip points`
