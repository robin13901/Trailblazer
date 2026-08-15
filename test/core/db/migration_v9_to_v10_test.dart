// v9 → v10 migration test: driven_way_geometry table created.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v9 → v10 migration (driven_way_geometry table)', () {
    test('database upgrades from v9 to v10 without errors', () async {
      final connection = await verifier.startAt(9);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 10);
    });

    test('creates the driven_way_geometry table', () async {
      final connection = await verifier.startAt(9);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 10);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='driven_way_geometry'",
          )
          .get();
      expect(tables, hasLength(1));
    });

    test('preserves existing trip and interval data', () async {
      final schema = await verifier.schemaAt(9);
      schema.rawDatabase.execute(
        'INSERT INTO trips (id, started_at, status) '
        "VALUES (1, 1000, 'matched')",
      );
      schema.rawDatabase.execute(
        'INSERT INTO driven_way_intervals '
        '(way_id, trip_id, start_meters, end_meters) '
        'VALUES (100, 1, 0.0, 200.0)',
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 10);

      final rows = await db
          .customSelect(
            'SELECT way_id, start_meters FROM driven_way_intervals',
          )
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.read<int>('way_id'), 100);
    });
  });
}
