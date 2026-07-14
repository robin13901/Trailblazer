import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v5 → v6 migration (coverage_cache.real_total_progress_json column)',
      () {
    test('database upgrades from v5 to v6 without errors', () async {
      final connection = await verifier.startAt(5);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 6);
    });

    test(
        'existing coverage_cache row survives; real_total_progress_json is '
        'added (nullable)', () async {
      // Seed at v5 via the raw schema DB so the insert does not open
      // AppDatabase and prematurely run the v6 migration.
      final schema = await verifier.schemaAt(5);
      schema.rawDatabase.execute(
        'INSERT INTO coverage_cache '
        '(region_id, driven_length_m, total_length_m, real_total_length_m) '
        "VALUES ('62428', 1234.5, 6789.0, 62638.061)",
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 6);

      // The cached row survived the addColumn migration with its data intact
      // and a null progress blob (only set mid-compute).
      final rows =
          await db.customSelect('SELECT * FROM coverage_cache').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<double?>('real_total_length_m'), 62638.061);
      expect(rows.first.read<String?>('real_total_progress_json'), isNull);

      // The new column exists on the coverage_cache table.
      final cols = await db
          .customSelect("SELECT name FROM pragma_table_info('coverage_cache')")
          .get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(colNames, contains('real_total_progress_json'));
    });
  });
}
