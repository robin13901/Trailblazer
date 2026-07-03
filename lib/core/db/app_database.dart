import 'package:auto_explore/core/db/tables/app_prefs_table.dart';
import 'package:auto_explore/core/db/tables/bt_fingerprints_table.dart';
import 'package:auto_explore/core/db/tables/coverage_cache_table.dart';
import 'package:auto_explore/core/db/tables/driven_intervals_table.dart';
import 'package:auto_explore/core/db/tables/trip_points_table.dart';
import 'package:auto_explore/core/db/tables/trips_table.dart';
import 'package:auto_explore/core/db/tables/vehicles_table.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Trips,
    TripPoints,
    DrivenWayIntervals,
    Vehicles,
    BtFingerprints,
    CoverageCache,
    AppPrefs,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
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
