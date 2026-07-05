---
id: 03-01
phase: 03-tracking-mvp
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/core/db/tables/trips_table.dart
  - lib/core/db/app_database.dart
  - lib/core/db/converters/trip_status_converter.dart
  - lib/features/trips/domain/trip_status.dart
  - lib/features/trips/domain/trip_summary.dart
  - lib/features/trips/data/trips_dao.dart
  - lib/features/trips/data/trips_repository.dart
  - lib/features/trips/data/trips_repository_providers.dart
  - drift_schemas/drift_schema_v2.json
  - test/core/db/migration_v1_to_v2_test.dart
  - test/features/trips/data/trips_repository_test.dart
autonomous: true
requirements_addressed: [TRK-05, TRK-07, TRK-08]

must_haves:
  truths:
    - "AppDatabase schemaVersion is 2 and a fresh app open runs onUpgrade(1→2) without data loss"
    - "A trip row can be opened (status=recording, endedAt=null), points appended, and closed with a full summary (bbox, distance, duration, avg/max speed, pointCount) written in one transaction"
    - "TripsRepository.activeTrip() returns the newest endedAt IS NULL row for cold-start hydration"
    - "TripStatus enum values persist as 'recording' | 'pending' | 'matched' | 'confirmed' | 'rejected' text — no drift between call sites"
    - "bluetooth_hint column exists, is nullable, and stays NULL for every P3 write (Phase 9 populates)"
  artifacts:
    - path: "lib/core/db/tables/trips_table.dart"
      provides: "Trips table with v2 summary columns"
      contains: "bboxMinLat"
    - path: "lib/features/trips/data/trips_dao.dart"
      provides: "@DriftAccessor exposing openTrip / appendPointsBatch / closeTrip / activeTrip / watchPoints"
      contains: "class TripsDao"
    - path: "lib/features/trips/data/trips_repository.dart"
      provides: "Domain-facing wrapper returning Result<T>"
      contains: "class TripsRepository"
    - path: "drift_schemas/drift_schema_v2.json"
      provides: "Committed v2 schema snapshot"
    - path: "test/core/db/migration_v1_to_v2_test.dart"
      provides: "SchemaVerifier v1→v2 test using generated migration helpers"
  key_links:
    - from: "lib/core/db/app_database.dart"
      to: "MigrationStrategy.onUpgrade"
      via: "if (from < 2) addColumn for each new bbox / pointCount column"
      pattern: "if \\(from < 2\\)"
    - from: "lib/features/trips/data/trips_dao.dart"
      to: "lib/core/db/tables/trips_table.dart, lib/core/db/tables/trip_points_table.dart"
      via: "@DriftAccessor(tables: [Trips, TripPoints])"
      pattern: "@DriftAccessor"
    - from: "lib/features/trips/data/trips_repository_providers.dart"
      to: "Riverpod dependency graph"
      via: "plain Provider<TripsRepository> (codegen OFF)"
      pattern: "Provider<TripsRepository>"
---

<objective>
Extend the App DB with the v2 summary columns needed to close a trip in one transaction, introduce a typed TripStatus enum, and land a Drift DAO + domain repository (with providers) that will be the sole write path in Wave 2.

Purpose: TRK-05 (per-trip captured metadata) and TRK-07 (manually_started/auto_stopped/bluetooth_hint booleans/string) require summary columns and a stable status contract. Wave 2's TrackingNotifier needs a single repository API so that FGB-side plumbing can stay thin and mockable.

Output: Drift v2 schema (bbox + pointCount added), TripsDao + TripsRepository + provider, committed schema v2 JSON, migration test, repository unit test.

Note on TRK-06 (Bluetooth fingerprint): DEFERRED to Phase 9 per 03-CONTEXT.md. The `bluetooth_hint TEXT NULL` column already exists in v1 (Plan 01-02) and stays NULL for every P3 write. Do not add BT plumbing here.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/REQUIREMENTS.md
@.planning/phases/03-tracking-mvp/03-CONTEXT.md
@.planning/phases/03-tracking-mvp/03-RESEARCH.md

# Phase 1 patterns to preserve
@lib/core/db/app_database.dart
@lib/core/db/tables/trips_table.dart
@lib/core/db/tables/trip_points_table.dart
@lib/core/errors/domain_error.dart
@lib/core/errors/result.dart

# Reference: how Phase 1 wrote its v1 migration test
@drift_schemas/drift_schema_v1.json

# Package name is `auto_explore` (see pubspec.yaml `name:` line) — use `package:auto_explore/…` in all imports.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Drift schema v2 — add summary columns + TripStatus converter</name>
  <files>
    - lib/core/db/tables/trips_table.dart
    - lib/features/trips/domain/trip_status.dart
    - lib/core/db/converters/trip_status_converter.dart
    - lib/core/db/app_database.dart
    - drift_schemas/drift_schema_v2.json
    - test/core/db/migration_v1_to_v2_test.dart
  </files>
  <action>
    1. Create `lib/features/trips/domain/trip_status.dart`:
       ```dart
       enum TripStatus { recording, pending, matched, confirmed, rejected }
       ```
       Nothing more — pure enum, no imports.

    2. Create `lib/core/db/converters/trip_status_converter.dart`:
       ```dart
       import 'package:drift/drift.dart';
       import 'package:auto_explore/features/trips/domain/trip_status.dart';

       class TripStatusConverter extends TypeConverter<TripStatus, String> {
         const TripStatusConverter();
         @override
         TripStatus fromSql(String fromDb) =>
             TripStatus.values.firstWhere((v) => v.name == fromDb);
         @override
         String toSql(TripStatus value) => value.name;
       }
       ```

    3. Edit `lib/core/db/tables/trips_table.dart`:
       - Keep the existing `status` `TextColumn` (default `'pending'`), but add `.map(const TripStatusConverter())` so Drift returns `TripStatus` in Dart while the SQLite column stays TEXT. This preserves v1-column compatibility (no ALTER on `status`).
       - After the existing columns, add five new nullable columns (v2):
         ```dart
         RealColumn get bboxMinLat => real().nullable()();
         RealColumn get bboxMinLon => real().nullable()();
         RealColumn get bboxMaxLat => real().nullable()();
         RealColumn get bboxMaxLon => real().nullable()();
         IntColumn get pointCount => integer().nullable()();
         ```
       - Alphabetize existing columns only if the file already does so; otherwise append new columns at the end (do not reorder unrelated lines — keeps diff auditable).

    4. Edit `lib/core/db/app_database.dart`:
       - Bump `int get schemaVersion => 2;` (was 1).
       - Extend `MigrationStrategy.onUpgrade`:
         ```dart
         onUpgrade: (m, from, to) async {
           if (from < 2) {
             await m.addColumn(trips, trips.bboxMinLat);
             await m.addColumn(trips, trips.bboxMinLon);
             await m.addColumn(trips, trips.bboxMaxLat);
             await m.addColumn(trips, trips.bboxMaxLon);
             await m.addColumn(trips, trips.pointCount);
           }
         },
         ```
       - Leave `beforeOpen` PRAGMAs (foreign_keys=ON, journal_mode=WAL) untouched — see STATE.md 01-02 decision.

    5. Regenerate codegen (run from repo root):
       ```bash
       dart run build_runner build --delete-conflicting-outputs
       dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/
       dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
       ```
       Verify `drift_schemas/drift_schema_v2.json` was created (this file is committed). `test/generated_migrations/` stays gitignored.

    6. Create `test/core/db/migration_v1_to_v2_test.dart` — copy the pattern from any existing v1 SchemaVerifier test. Use the generated `schema_v1.dart` + `schema_v2.dart` helpers from `test/generated_migrations/`, seed a `trips` row at v1, run the migration, assert the row is still there and that the new columns are NULL.

    Anti-patterns to avoid:
    - Do NOT rewrite existing columns' Dart types; only append the five new ones and attach the converter to `status`.
    - Do NOT touch `TripPoints` — its v1 shape is sufficient (see RESEARCH.md).
    - Do NOT bundle `test/generated_migrations/` into git (gitignored per Plan 01-02).
  </action>
  <verify>
    - `dart run build_runner build --delete-conflicting-outputs` completes with no errors
    - `dart run drift_dev schema generate drift_schemas/ test/generated_migrations/` completes
    - `flutter analyze` clean
    - `flutter test test/core/db/migration_v1_to_v2_test.dart` green
    - `drift_schemas/drift_schema_v2.json` exists and is committed
  </verify>
  <done>
    schemaVersion=2, five new nullable columns on Trips, TripStatus converter wired, migration test passes on v1-seeded DB, schema v2 JSON committed.
  </done>
</task>

<task type="auto">
  <name>Task 2: TripsDao + TripsRepository + provider + repository test</name>
  <files>
    - lib/features/trips/domain/trip_summary.dart
    - lib/features/trips/data/trips_dao.dart
    - lib/features/trips/data/trips_repository.dart
    - lib/features/trips/data/trips_repository_providers.dart
    - test/features/trips/data/trips_repository_test.dart
  </files>
  <action>
    1. Create `lib/features/trips/domain/trip_summary.dart` — a plain value class (no Drift dep):
       ```dart
       import 'package:meta/meta.dart';

       @immutable
       class TripSummary {
         const TripSummary({
           required this.startedAt,
           required this.endedAt,
           required this.durationSeconds,
           required this.distanceMeters,
           required this.avgSpeedKmh,
           required this.maxSpeedKmh,
           required this.pointCount,
           required this.bboxMinLat,
           required this.bboxMinLon,
           required this.bboxMaxLat,
           required this.bboxMaxLon,
           required this.autoStopped,
         });
         final DateTime startedAt;
         final DateTime endedAt;
         final int durationSeconds;
         final double distanceMeters;
         final double avgSpeedKmh;
         final double maxSpeedKmh;
         final int pointCount;
         final double bboxMinLat;
         final double bboxMinLon;
         final double bboxMaxLat;
         final double bboxMaxLon;
         final bool autoStopped;
       }
       ```

    2. Create `lib/features/trips/data/trips_dao.dart`:
       ```dart
       import 'package:drift/drift.dart';
       import 'package:auto_explore/core/db/app_database.dart';
       import 'package:auto_explore/features/trips/domain/trip_status.dart';
       import 'package:auto_explore/features/trips/domain/trip_summary.dart';

       part 'trips_dao.g.dart';

       @DriftAccessor(tables: [Trips, TripPoints])
       class TripsDao extends DatabaseAccessor<AppDatabase> with _$TripsDaoMixin {
         TripsDao(super.db);

         Future<int> openTrip({
           required DateTime startedAt,
           required bool manuallyStarted,
           int? vehicleId,
         }) => into(trips).insert(TripsCompanion.insert(
               startedAt: startedAt,
               status: const Value(TripStatus.recording),
               manuallyStarted: Value(manuallyStarted),
               vehicleId: Value(vehicleId),
             ));

         Future<void> appendPointsBatch(
           int tripId, List<TripPointsCompanion> points,
         ) => batch((b) => b.insertAll(tripPoints, points));

         Future<void> closeTrip(int tripId, TripSummary s) =>
             (update(trips)..where((t) => t.id.equals(tripId))).write(
               TripsCompanion(
                 endedAt: Value(s.endedAt),
                 durationSeconds: Value(s.durationSeconds),
                 distanceMeters: Value(s.distanceMeters),
                 avgSpeedKmh: Value(s.avgSpeedKmh),
                 maxSpeedKmh: Value(s.maxSpeedKmh),
                 pointCount: Value(s.pointCount),
                 bboxMinLat: Value(s.bboxMinLat),
                 bboxMinLon: Value(s.bboxMinLon),
                 bboxMaxLat: Value(s.bboxMaxLat),
                 bboxMaxLon: Value(s.bboxMaxLon),
                 autoStopped: Value(s.autoStopped),
                 status: const Value(TripStatus.pending),
               ),
             );

         Future<void> deleteTrip(int tripId) =>
             (delete(trips)..where((t) => t.id.equals(tripId))).go();

         Future<Trip?> activeTrip() =>
             (select(trips)
                   ..where((t) => t.endedAt.isNull())
                   ..orderBy([(t) => OrderingTerm.desc(t.id)])
                   ..limit(1))
                 .getSingleOrNull();

         Stream<List<TripPoint>> watchPoints(int tripId) =>
             (select(tripPoints)
                   ..where((p) => p.tripId.equals(tripId))
                   ..orderBy([(p) => OrderingTerm.asc(p.seq)]))
                 .watch();
       }
       ```
       Register the DAO on `AppDatabase` by adding it to the `daos: [TripsDao]` list of `@DriftDatabase(...)` in `app_database.dart` (or the equivalent property already declared). Re-run `build_runner` after.

    3. Create `lib/features/trips/data/trips_repository.dart`:
       ```dart
       import 'package:auto_explore/core/errors/domain_error.dart';
       import 'package:auto_explore/core/errors/result.dart';
       import 'package:auto_explore/features/trips/data/trips_dao.dart';
       import 'package:auto_explore/features/trips/domain/trip_summary.dart';
       // + drift companion imports as needed

       class TripsRepository {
         TripsRepository(this._dao);
         final TripsDao _dao;

         Future<Result<int>> openTrip({
           required DateTime startedAt,
           required bool manuallyStarted,
           int? vehicleId,
         }) async {
           try {
             final id = await _dao.openTrip(
               startedAt: startedAt,
               manuallyStarted: manuallyStarted,
               vehicleId: vehicleId,
             );
             return Ok(id);
           } catch (e, st) {
             return Err(DomainError.wrap(e, st));
           }
         }

         Future<Result<void>> appendPoints(int tripId, List<TripPointsCompanion> ps) async { ... }
         Future<Result<void>> closeTrip(int tripId, TripSummary s) async { ... }
         Future<Result<void>> deleteTrip(int tripId) async { ... }
         Future<Result<Trip?>> activeTrip() async { ... }
         Stream<List<TripPoint>> watchPoints(int tripId) => _dao.watchPoints(tripId);
       }
       ```
       All non-stream methods return `Result<T>`, wrap any non-DomainError throwable via `DomainError.wrap(e, st)` (STATE.md 01-04). Do NOT expose `TripsDao` types in the public repo API where you can help it — but re-exporting `TripPointsCompanion` from a small barrel is acceptable to avoid a copy-model in Wave 2.

    4. Create `lib/features/trips/data/trips_repository_providers.dart`:
       ```dart
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:auto_explore/core/db/app_database.dart';
       // AppDatabase provider location — check main.dart / existing providers file
       // (Plan 01-02 exposes AppDatabase; reuse that provider, do not construct a new one).
       import 'package:auto_explore/features/trips/data/trips_dao.dart';
       import 'package:auto_explore/features/trips/data/trips_repository.dart';

       final tripsDaoProvider = Provider<TripsDao>((ref) {
         return TripsDao(ref.watch(appDatabaseProvider));
       });

       final tripsRepositoryProvider = Provider<TripsRepository>((ref) {
         return TripsRepository(ref.watch(tripsDaoProvider));
       });
       ```
       Codegen OFF — plain `Provider<T>` (STATE.md 01-01).

    5. Create `test/features/trips/data/trips_repository_test.dart`:
       - Boot `AppDatabase` with `NativeDatabase.memory()` (Plan 01-02 pattern — `AppDatabase(executor: NativeDatabase.memory())`).
       - Test cases:
         - `openTrip → activeTrip returns opened row with status=recording, endedAt=null`
         - `appendPoints then close → activeTrip returns null` (row now has endedAt set + status=pending)
         - `close writes bbox + pointCount correctly`
         - `deleteTrip removes row + points (CASCADE per FK policy from Plan 01-02)`

    Anti-patterns to avoid:
    - Do NOT add a synthetic `AppDatabase.tripsDao` getter and use it — go through the provider so tests can override the DAO.
    - Do NOT use relative imports (STATE.md 01-01: package imports only).
    - Do NOT hand-roll a `Trip` domain model in this plan — return the Drift `Trip` row directly. Phase 6 (inbox) is where a domain model earns its keep.
  </action>
  <verify>
    - `dart run build_runner build --delete-conflicting-outputs` clean (generates `trips_dao.g.dart`)
    - `flutter analyze` clean (no `always_use_package_imports`, no `sort_pub_dependencies` violations)
    - `flutter test test/features/trips/data/trips_repository_test.dart` green — all 4+ cases pass
  </verify>
  <done>
    TripsDao + TripsRepository + tripsRepositoryProvider available for import by Wave 2. Repository test proves openTrip → appendPoints → closeTrip → activeTrip round-trip works against an in-memory DB.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` clean across the whole tree (Ralph Loop tight-loop gate)
- `flutter test test/core/db/migration_v1_to_v2_test.dart test/features/trips/data/trips_repository_test.dart` — all pass
- `drift_schemas/drift_schema_v2.json` present and committed
- No changes to pubspec.yaml in this plan (deps live in 03-03)
- Commit(s) follow project style: `feat(03-01): drift v2 migration + trips repository`
</verification>

<success_criteria>
- Schema v2 lands with additive migration and no v1 data loss
- TripsRepository is the sole documented write path for trips + trip_points
- Wave 2 (Plan 03-04) can pick up `tripsRepositoryProvider` without further schema work
- bluetooth_hint stays NULL in every P3 write (Phase 9 marker preserved)
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-01-SUMMARY.md`
</output>
