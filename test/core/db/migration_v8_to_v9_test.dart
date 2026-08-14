// Trailblazer 2026-08-13: v8 → v9 migration test.
// v9 adds the durable coverage_line_cache table (single-row clipped-line blob).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v8 → v9 migration (coverage_line_cache table)', () {
    test('database upgrades from v8 to v9 without errors', () async {
      final connection = await verifier.startAt(8);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 9);
    });

    test('creates the coverage_line_cache table', () async {
      final connection = await verifier.startAt(8);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 9);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'coverage_line_cache'",
          )
          .get();
      expect(tables, hasLength(1));
    });

    test('preserves existing trip data across the upgrade', () async {
      // Seed at v8 via the raw schema DB so the insert does not open
      // AppDatabase and prematurely run the v9 migration.
      final schema = await verifier.schemaAt(8);
      schema.rawDatabase.execute(
        'INSERT INTO trips (id, started_at, status) '
        "VALUES (1, 1000, 'confirmed')",
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 9);

      final rows = await db
          .customSelect('SELECT id, status FROM trips')
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.read<int>('id'), 1);
      expect(rows.first.read<String>('status'), 'confirmed');
    });
  });
}
