import 'package:auto_explore/core/db/converters/trip_status_converter.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/db/daos/overpass_way_cache_dao.dart';
import 'package:auto_explore/core/db/daos/pending_road_fetches_dao.dart';
import 'package:auto_explore/core/db/tables/app_prefs_table.dart';
import 'package:auto_explore/core/db/tables/coverage_cache_table.dart';
import 'package:auto_explore/core/db/tables/driven_intervals_table.dart';
import 'package:auto_explore/core/db/tables/overpass_way_cache_table.dart';
import 'package:auto_explore/core/db/tables/pending_road_fetches_table.dart';
import 'package:auto_explore/core/db/tables/trip_points_table.dart';
import 'package:auto_explore/core/db/tables/trips_table.dart';
// TripStatus is referenced by the Drift-generated app_database.g.dart (part of
// this library) — the type must be in scope for the part file to compile.
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Trips,
    TripPoints,
    DrivenWayIntervals,
    CoverageCache,
    AppPrefs,
    OverpassWayCache,
    PendingRoadFetches,
  ],
  daos: [DrivenWayIntervalsDao, OverpassWayCacheDao, PendingRoadFetchesDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(trips, trips.bboxMinLat);
        await m.addColumn(trips, trips.bboxMinLon);
        await m.addColumn(trips, trips.bboxMaxLat);
        await m.addColumn(trips, trips.bboxMaxLon);
        await m.addColumn(trips, trips.pointCount);
      }
      if (from < 3) {
        await m.createTable(overpassWayCache);
        await m.createTable(pendingRoadFetches);
      }
      if (from < 4 && to >= 4) {
        // v4: vehicle feature removed entirely. Drop the vehicles +
        // bt_fingerprints tables and the two now-orphaned trips columns
        // (vehicle_id, bluetooth_hint). All trip/point/coverage data is
        // preserved — TableMigration recreates `trips` copying only the
        // surviving columns.
        //
        // Guarded by `to >= 4` (not just `from < 4`) so the stepped-migration
        // verifier tests that upgrade an old DB only as far as v2/v3 do NOT
        // execute this destructive step — those intermediate snapshots still
        // contain the vehicle schema. The drop runs only when the migration
        // actually targets v4+.
        await customStatement('DROP TABLE IF EXISTS bt_fingerprints');
        await customStatement('DROP TABLE IF EXISTS vehicles');
        // `coveragePathJson` (added in the current Dart schema for v5) does not
        // exist on a v3 `trips` table, so declare it as a new column here — the
        // rebuild creates it fresh (nullable, default null) instead of trying
        // to SELECT it from the old table. When the DB is being upgraded
        // straight to v5 the `from < 5` block below is a no-op for trips
        // (the column already exists); a v3→v4-only stepped upgrade leaves it
        // present and null, which is correct.
        await m.alterTable(
          TableMigration(trips, newColumns: [trips.coveragePathJson]),
        );
      }
      if (from < 5 && to >= 5) {
        // v5: persistent per-trip coverage polyline (the on-road-trimmed raw
        // GPS trail). Only add the column when it doesn't already exist — the
        // v4 TableMigration above already creates it when upgrading through v4
        // (from < 4). So this runs only for a DB that is already at exactly v4.
        if (from == 4) {
          await m.addColumn(trips, trips.coveragePathJson);
        }
        // v5: real per-region total road length (tiled area-clipped Overpass
        // sum), computed once in the background and cached forever. Nullable
        // = not yet computed → the region browser shows a spinner.
        await m.addColumn(coverageCache, coverageCache.realTotalLengthM);
        await m.addColumn(coverageCache, coverageCache.realTotalUpdatedAt);
      }
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
