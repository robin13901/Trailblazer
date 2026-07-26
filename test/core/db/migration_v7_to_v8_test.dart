import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v7 → v8 migration (heading column + way_region_attribution)', () {
    test('database upgrades from v7 to v8 without errors', () async {
      final connection = await verifier.startAt(7);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 8);
    });

    test('adds the nullable heading column to trip_points', () async {
      final connection = await verifier.startAt(7);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 8);

      final cols = await db
          .customSelect("SELECT name FROM pragma_table_info('trip_points')")
          .get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, contains('heading'));
    });

    test('creates the way_region_attribution table', () async {
      final connection = await verifier.startAt(7);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 8);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'way_region_attribution'",
          )
          .get();
      expect(tables, hasLength(1));
    });

    test('preserves existing trip_points and defaults heading to null',
        () async {
      // Seed at v7 via the raw schema DB so the insert does not open
      // AppDatabase and prematurely run the v8 migration.
      final schema = await verifier.schemaAt(7);

      schema.rawDatabase.execute(
        'INSERT INTO trips (id, started_at, status) '
        "VALUES (1, 1000, 'confirmed')",
      );
      schema.rawDatabase.execute(
        'INSERT INTO trip_points (trip_id, seq, ts, lat, lon, speed_kmh) '
        'VALUES (1, 0, 1000, 49.700, 9.000, 42.0)',
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 8);

      final rows = await db
          .customSelect(
            'SELECT lat, lon, speed_kmh, heading FROM trip_points',
          )
          .get();
      expect(rows, hasLength(1));
      // Pre-existing data survives.
      expect(rows[0].read<double>('lat'), 49.700);
      expect(rows[0].read<double>('lon'), 9.000);
      expect(rows[0].read<double>('speed_kmh'), 42.0);
      // New column is null on historical rows.
      expect(rows[0].read<double?>('heading'), isNull);
    });
  });
}
