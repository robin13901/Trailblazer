import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v3 → v4 migration (Vehicles + Bluetooth removal)', () {
    // Note: validates at the CURRENT schema version (7), not 4. The v4 step
    // rebuilds `trips` via TableMigration from the current Dart definition,
    // which now includes later columns (`coverage_path_json` from v5 and the
    // v7 start/end endpoint columns) — so the migrated schema only matches the
    // current snapshot, not the frozen v4/v5 ones. Migrating straight to the
    // current version still exercises the from<4 vehicle-drop path and its
    // assertions.
    test('database upgrades from v3 through to current schema without errors',
        () async {
      final connection = await verifier.startAt(3);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 7);
    });

    test('trip data survives; vehicle_id + bluetooth_hint columns are dropped',
        () async {
      // Seed at v3 via the raw schema DB (NOT the full AppDatabase) so the
      // insert does not open AppDatabase and prematurely run the v4 migration.
      final schema = await verifier.schemaAt(3);

      // Seed a v3 trips row that populates vehicle_id + bluetooth_hint —
      // the exact columns the v4 migration removes. The row itself must
      // survive the destructive table rebuild.
      schema.rawDatabase.execute(
        'INSERT INTO trips '
        '(started_at, status, manually_started, auto_stopped, '
        'vehicle_id, bluetooth_hint, distance_meters) '
        "VALUES (strftime('%s', 'now'), 'confirmed', 1, 0, 7, 'AA:BB', 1234.5)",
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 7);

      // The trip row survived the TableMigration rebuild with its
      // non-vehicle data intact.
      final rows = await db.customSelect('SELECT * FROM trips').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<double?>('distance_meters'), 1234.5);

      // The dropped columns no longer exist on the trips table.
      final tripCols = await db
          .customSelect("SELECT name FROM pragma_table_info('trips')")
          .get();
      final colNames = tripCols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, isNot(contains('vehicle_id')));
      expect(colNames, isNot(contains('bluetooth_hint')));
    });

    test('vehicles + bt_fingerprints tables are dropped post-migration',
        () async {
      final connection = await verifier.startAt(3);
      final db = AppDatabase(connection);
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 7);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_schema WHERE type = 'table'",
          )
          .get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      expect(tableNames, isNot(contains('vehicles')));
      expect(tableNames, isNot(contains('bt_fingerprints')));
    });
  });
}
