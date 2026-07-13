import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v4 → v5 migration (per-trip coverage_path_json column)', () {
    test('database upgrades from v4 to v5 without errors', () async {
      final connection = await verifier.startAt(4);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 5);
    });

    test('existing trip data survives; coverage_path_json is added (nullable)',
        () async {
      // Seed at v4 via the raw schema DB so the insert does not open
      // AppDatabase and prematurely run the v5 migration.
      final schema = await verifier.schemaAt(4);
      schema.rawDatabase.execute(
        'INSERT INTO trips '
        '(started_at, status, manually_started, auto_stopped, distance_meters) '
        "VALUES (strftime('%s', 'now'), 'confirmed', 1, 0, 4321.0)",
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 5);

      // The trip row survived the addColumn migration with its data intact and
      // a null coverage path (backfilled later by the re-match migration).
      final rows = await db.customSelect('SELECT * FROM trips').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<double?>('distance_meters'), 4321.0);
      expect(rows.first.read<String?>('coverage_path_json'), isNull);

      // The new column exists on the trips table.
      final tripCols = await db
          .customSelect("SELECT name FROM pragma_table_info('trips')")
          .get();
      final colNames = tripCols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, contains('coverage_path_json'));
    });
  });
}
