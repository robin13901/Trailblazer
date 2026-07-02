---
plan: "02"
name: "drift-app-db-schema"
wave: 2
depends_on: ["01"]
files_modified:
  - "lib/core/db/app_database.dart"
  - "lib/core/db/tables/trips_table.dart"
  - "lib/core/db/tables/trip_points_table.dart"
  - "lib/core/db/tables/driven_intervals_table.dart"
  - "lib/core/db/tables/vehicles_table.dart"
  - "lib/core/db/tables/bt_fingerprints_table.dart"
  - "lib/core/db/tables/coverage_cache_table.dart"
  - "lib/core/db/tables/app_prefs_table.dart"
  - "drift_schemas/drift_schema_v1.json"
  - "test/generated_migrations/schema.dart"
  - "test/core/db/migration_test.dart"
  - "test/core/db/app_database_open_test.dart"
autonomous: true
requirements: ["FND-08", "QUA-03"]
must_haves:
  truths:
    - "Opening `AppDatabase` in a test process creates all seven tables without SQL errors."
    - "`PRAGMA foreign_keys = ON` and `PRAGMA journal_mode = WAL` are executed in `beforeOpen`."
    - "`dart run drift_dev schema dump ...` produces `drift_schemas/drift_schema_v1.json`."
    - "`SchemaVerifier.migrateAndValidate(db, 1)` passes green in CI."
  artifacts:
    - path: "lib/core/db/app_database.dart"
      provides: "@DriftDatabase class with schemaVersion=1 + MigrationStrategy (onCreate/onUpgrade/beforeOpen)"
      contains: "class AppDatabase extends _\\$AppDatabase"
    - path: "lib/core/db/tables/"
      provides: "Seven table definitions covering all v1 App DB needs"
      min_files: 7
    - path: "drift_schemas/drift_schema_v1.json"
      provides: "Versioned schema dump used by SchemaVerifier"
    - path: "test/generated_migrations/schema.dart"
      provides: "Generated migration helper for SchemaVerifier"
    - path: "test/core/db/migration_test.dart"
      provides: "SchemaVerifier test that migrateAndValidate(db, 1) succeeds"
  key_links:
    - from: "lib/core/db/app_database.dart"
      to: "lib/core/db/tables/*.dart"
      via: "@DriftDatabase(tables: [Trips, TripPoints, ...])"
      pattern: "@DriftDatabase\\(tables:"
    - from: "test/core/db/migration_test.dart"
      to: "test/generated_migrations/schema.dart"
      via: "SchemaVerifier(GeneratedHelper())"
      pattern: "SchemaVerifier\\(GeneratedHelper"
---

<objective>
Scaffold the full v1 App DB using Drift: seven table groups (trips, trip_points, driven_intervals, vehicles, bt_fingerprints, coverage_cache, app_prefs), a `MigrationStrategy` with foreign keys + WAL, a versioned `drift_schemas/` dump, and `SchemaVerifier`-backed migration tests. DAOs remain out of scope — they land per-phase when their tables are used.
</objective>

<context>
- **Package versions:** `drift: ^2.34.0`, `drift_flutter: ^0.3.0`, `drift_dev: ^2.34.0` (all pinned in `pubspec.yaml` by Plan 01).
- **Table DSL snippets:** RESEARCH.md lines 374-478 (full source for all 7 tables). Copy verbatim.
- **AppDatabase class + MigrationStrategy:** RESEARCH.md lines 482-531.
- **SchemaVerifier test pattern:** RESEARCH.md lines 550-564 and 997-1013.
- **Schema dump + generate commands:** RESEARCH.md lines 535-544.
- **Pitfall 4 (foreign keys):** RESEARCH.md lines 930-936. `PRAGMA foreign_keys = ON` MUST be in `beforeOpen`.
- **CONTEXT.md decisions:** full schema upfront (all Phase 1); DAOs deferred; schema file organization = domain-split (7 files under `core/db/tables/`); migration test strategy = SchemaVerifier at minimum (Claude's discretion for per-step tests, but only v1 exists so a single SchemaVerifier test is enough for now).
</context>

<tasks>

<task id="2.1" type="auto">
  <name>Create the seven table definition files</name>
  <files>
    - `lib/core/db/tables/trips_table.dart`
    - `lib/core/db/tables/trip_points_table.dart`
    - `lib/core/db/tables/driven_intervals_table.dart`
    - `lib/core/db/tables/vehicles_table.dart`
    - `lib/core/db/tables/bt_fingerprints_table.dart`
    - `lib/core/db/tables/coverage_cache_table.dart`
    - `lib/core/db/tables/app_prefs_table.dart`
  </files>
  <action>
    Create each of the following files verbatim (each file starts with `import 'package:drift/drift.dart';`).

    **`lib/core/db/tables/trips_table.dart`:**
    ```dart
    import 'package:drift/drift.dart';

    class Trips extends Table {
      IntColumn get id => integer().autoIncrement()();
      DateTimeColumn get startedAt => dateTime()();
      DateTimeColumn get endedAt => dateTime().nullable()();
      IntColumn get durationSeconds => integer().nullable()();
      RealColumn get distanceMeters => real().nullable()();
      RealColumn get avgSpeedKmh => real().nullable()();
      RealColumn get maxSpeedKmh => real().nullable()();
      // status: 'pending' | 'confirmed' | 'rejected'
      TextColumn get status => text().withDefault(const Constant('pending'))();
      IntColumn get vehicleId => integer().nullable()();
      BoolColumn get manuallyStarted => boolean().withDefault(const Constant(false))();
      BoolColumn get autoStopped => boolean().withDefault(const Constant(false))();
      TextColumn get bluetoothHint => text().nullable()();
      DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
    }
    ```

    **`lib/core/db/tables/trip_points_table.dart`:**
    ```dart
    import 'package:drift/drift.dart';
    import 'trips_table.dart';

    class TripPoints extends Table {
      IntColumn get id => integer().autoIncrement()();
      IntColumn get tripId =>
          integer().references(Trips, #id, onDelete: KeyAction.cascade)();
      IntColumn get seq => integer()();
      DateTimeColumn get ts => dateTime()();
      RealColumn get lat => real()();
      RealColumn get lon => real()();
      RealColumn get speedKmh => real().nullable()();
      RealColumn get accuracyMeters => real().nullable()();
      RealColumn get altitudeMeters => real().nullable()();
      TextColumn get motionType => text().nullable()();

      @override
      List<Set<Column>> get uniqueKeys => [
            {tripId, seq},
          ];
    }
    ```

    **`lib/core/db/tables/driven_intervals_table.dart`:**
    ```dart
    import 'package:drift/drift.dart';
    import 'trips_table.dart';

    class DrivenWayIntervals extends Table {
      IntColumn get id => integer().autoIncrement()();
      IntColumn get wayId => integer()(); // OSM way ID
      IntColumn get tripId =>
          integer().references(Trips, #id, onDelete: KeyAction.setNull).nullable()();
      RealColumn get startMeters => real()();
      RealColumn get endMeters => real()();
      // direction: 'forward' | 'backward' | 'both'
      TextColumn get direction => text().withDefault(const Constant('forward'))();
      DateTimeColumn get matchedAt =>
          dateTime().withDefault(currentDateAndTime)();
    }
    ```

    **`lib/core/db/tables/vehicles_table.dart`:**
    ```dart
    import 'package:drift/drift.dart';

    class Vehicles extends Table {
      IntColumn get id => integer().autoIncrement()();
      TextColumn get name => text()();
      TextColumn get model => text().nullable()();
      TextColumn get colorHex => text().nullable()();
      BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
      BoolColumn get countsForCoverage =>
          boolean().withDefault(const Constant(true))();
      DateTimeColumn get createdAt =>
          dateTime().withDefault(currentDateAndTime)();
    }
    ```

    **`lib/core/db/tables/bt_fingerprints_table.dart`:**
    ```dart
    import 'package:drift/drift.dart';
    import 'vehicles_table.dart';

    class BtFingerprints extends Table {
      IntColumn get id => integer().autoIncrement()();
      IntColumn get vehicleId =>
          integer().references(Vehicles, #id, onDelete: KeyAction.cascade)();
      TextColumn get macAddress => text()();
      TextColumn get deviceName => text().nullable()();
      DateTimeColumn get createdAt =>
          dateTime().withDefault(currentDateAndTime)();
    }
    ```

    **`lib/core/db/tables/coverage_cache_table.dart`:**
    ```dart
    import 'package:drift/drift.dart';

    class CoverageCache extends Table {
      TextColumn get regionId => text()(); // OSM relation ID as string
      RealColumn get drivenLengthM =>
          real().withDefault(const Constant(0.0))();
      RealColumn get totalLengthM =>
          real().withDefault(const Constant(0.0))();
      DateTimeColumn get updatedAt =>
          dateTime().withDefault(currentDateAndTime)();
      TextColumn get extractVersion => text().nullable()();
      IntColumn get invalidationGen =>
          integer().withDefault(const Constant(0))();

      @override
      Set<Column> get primaryKey => {regionId};
    }
    ```

    **`lib/core/db/tables/app_prefs_table.dart`:**
    ```dart
    import 'package:drift/drift.dart';

    class AppPrefs extends Table {
      TextColumn get key => text()();
      TextColumn get value => text().nullable()();

      @override
      Set<Column> get primaryKey => {key};
    }
    ```
  </action>
  <verify>
    ```bash
    ls lib/core/db/tables/ | wc -l    # must be 7
    flutter analyze --fatal-infos lib/core/db/tables/
    ```
  </verify>
  <done>All seven table files exist and pass `flutter analyze`.</done>
</task>

<task id="2.2" type="auto">
  <name>Create AppDatabase class with MigrationStrategy, run codegen, dump schema</name>
  <files>
    - `lib/core/db/app_database.dart`
    - `lib/core/db/app_database.g.dart` (generated)
    - `drift_schemas/drift_schema_v1.json` (generated)
    - `test/generated_migrations/schema.dart` (generated — plus supporting files)
  </files>
  <action>
    **Create `lib/core/db/app_database.dart`:**

    ```dart
    import 'package:drift/drift.dart';
    import 'package:drift_flutter/drift_flutter.dart';

    import 'tables/app_prefs_table.dart';
    import 'tables/bt_fingerprints_table.dart';
    import 'tables/coverage_cache_table.dart';
    import 'tables/driven_intervals_table.dart';
    import 'tables/trip_points_table.dart';
    import 'tables/trips_table.dart';
    import 'tables/vehicles_table.dart';

    part 'app_database.g.dart';

    @DriftDatabase(tables: [
      Trips,
      TripPoints,
      DrivenWayIntervals,
      Vehicles,
      BtFingerprints,
      CoverageCache,
      AppPrefs,
    ])
    class AppDatabase extends _$AppDatabase {
      AppDatabase([QueryExecutor? executor])
          : super(executor ?? _openConnection());

      @override
      int get schemaVersion => 1;

      @override
      MigrationStrategy get migration => MigrationStrategy(
            onCreate: (Migrator m) async {
              await m.createAll();
            },
            onUpgrade: (Migrator m, int from, int to) async {
              // Future v1 -> v2 migrations go here in later phases.
            },
            beforeOpen: (details) async {
              // Enforce referential integrity — SQLite/Drift default is OFF.
              await customStatement('PRAGMA foreign_keys = ON');
              // WAL mode for concurrent reads (needed once OSM isolate exists).
              await customStatement('PRAGMA journal_mode = WAL');
            },
          );

      static QueryExecutor _openConnection() {
        return driftDatabase(name: 'app_db');
      }
    }
    ```

    **Run Drift codegen** to generate `app_database.g.dart`:

    ```bash
    dart run build_runner build --delete-conflicting-outputs
    ```

    **Dump the v1 schema JSON** (Drift needs this to power `SchemaVerifier`):

    ```bash
    mkdir -p drift_schemas
    dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/
    ```

    This produces `drift_schemas/drift_schema_v1.json`.

    **Generate migration test helpers:**

    ```bash
    mkdir -p test/generated_migrations
    dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
    ```

    This produces `test/generated_migrations/schema.dart` (plus per-version helper files if drift_dev decides — that's fine).

    Note: `test/generated_migrations/` is `.gitignore`d by Plan 01 — that's intentional; CI regenerates it as part of the test run in Plan 06 (add a step there).
  </action>
  <verify>
    ```bash
    test -f lib/core/db/app_database.g.dart
    test -f drift_schemas/drift_schema_v1.json
    test -f test/generated_migrations/schema.dart
    flutter analyze --fatal-infos
    ```
  </verify>
  <done>Codegen succeeds, schema dump exists, migration helpers generated, analyzer clean.</done>
</task>

<task id="2.3" type="auto">
  <name>Write SchemaVerifier + in-memory open tests</name>
  <files>
    - `test/core/db/migration_test.dart`
    - `test/core/db/app_database_open_test.dart`
    - `test/helpers/test_database.dart`
  </files>
  <action>

    **`test/helpers/test_database.dart`** — spins up an in-memory AppDatabase (no filesystem):

    ```dart
    import 'package:auto_explore/core/db/app_database.dart';
    import 'package:drift/native.dart';

    AppDatabase createInMemoryDatabase() {
      return AppDatabase(NativeDatabase.memory());
    }
    ```

    **`test/core/db/app_database_open_test.dart`** — verifies the DB opens, tables exist, and PRAGMAs applied:

    ```dart
    import 'package:drift/drift.dart';
    import 'package:flutter_test/flutter_test.dart';

    import '../../helpers/test_database.dart';

    void main() {
      test('AppDatabase opens in memory with all 7 tables', () async {
        final db = createInMemoryDatabase();
        addTearDown(db.close);

        // Reading Drift's internal table list via sqlite_master.
        final rows = await db
            .customSelect(
              "SELECT name FROM sqlite_master "
              "WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
            )
            .get();
        final tableNames = rows.map((r) => r.read<String>('name')).toSet();

        expect(tableNames, containsAll(<String>{
          'trips',
          'trip_points',
          'driven_way_intervals',
          'vehicles',
          'bt_fingerprints',
          'coverage_cache',
          'app_prefs',
        }));
      });

      test('foreign_keys pragma is ON after beforeOpen', () async {
        final db = createInMemoryDatabase();
        addTearDown(db.close);

        // Force beforeOpen by issuing any query first.
        await db.customSelect('SELECT 1').get();

        final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
        expect(row.read<int>('foreign_keys'), 1);
      });
    }
    ```

    **`test/core/db/migration_test.dart`** — SchemaVerifier v1 test:

    ```dart
    import 'package:auto_explore/core/db/app_database.dart';
    import 'package:drift_dev/api/migrations_native.dart';
    import 'package:flutter_test/flutter_test.dart';

    import '../../generated_migrations/schema.dart';

    void main() {
      final verifier = SchemaVerifier(GeneratedHelper());

      test('database at v1 has correct schema', () async {
        final connection = await verifier.startAt(1);
        final db = AppDatabase(connection);
        addTearDown(db.close);
        await verifier.migrateAndValidate(db, 1);
      });
    }
    ```

    Note: `test/generated_migrations/` was `.gitignore`d in Plan 01. That is intentional — its contents are reproducible from `drift_schemas/` (which IS committed). CI in Plan 06 must regenerate it before `flutter test` runs. **Verify locally now** so we can prove the tests pass end-to-end.
  </action>
  <verify>
    ```bash
    # Ensure test-time codegen artifacts are present
    dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
    flutter test test/core/db/
    ```
    Both tests must be green. `flutter analyze` also clean.
  </verify>
  <done>
    - `flutter test test/core/db/` shows both tests passing.
    - `SchemaVerifier.migrateAndValidate(db, 1)` returns without throwing.
    - `flutter analyze --fatal-infos` clean.
  </done>
</task>

</tasks>

<verification>
```bash
flutter analyze --fatal-infos
dart format --set-exit-if-changed .
dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
flutter test test/core/db/
```
All exit 0.

Regenerating the schema after edits:
```bash
dart run build_runner build --delete-conflicting-outputs
dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/
```
</verification>

<must_haves>
Contributes to phase Success Criterion 4 (App DB opens with migration infrastructure intact; SchemaVerifier passes for every defined step). Also indirectly to SC1 (analyzer must remain clean with generated files excluded).
</must_haves>
