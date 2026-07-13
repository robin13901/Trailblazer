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
  int get schemaVersion => 4;

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
        await m.alterTable(TableMigration(trips));
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
