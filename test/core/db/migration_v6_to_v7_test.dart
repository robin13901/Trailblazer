import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v6 → v7 migration (denormalized trip start/end coords)', () {
    test('database upgrades from v6 to v7 without errors', () async {
      final connection = await verifier.startAt(6);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 7);
    });

    test('adds the four nullable endpoint columns to trips', () async {
      final connection = await verifier.startAt(6);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 7);

      final cols = await db
          .customSelect("SELECT name FROM pragma_table_info('trips')")
          .get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      expect(
        colNames,
        containsAll(<String>['start_lat', 'start_lon', 'end_lat', 'end_lon']),
      );
    });

    test('backfills endpoints from surviving trip_points (first/last by seq)',
        () async {
      // Seed at v6 via the raw schema DB so the insert does not open
      // AppDatabase and prematurely run the v7 migration.
      final schema = await verifier.schemaAt(6);

      // A trip with three points — the backfill must pick seq 0 (start) and
      // seq 2 (end), NOT insertion order.
      schema.rawDatabase.execute(
        'INSERT INTO trips (id, started_at, status) '
        "VALUES (1, 1000, 'confirmed')",
      );
      schema.rawDatabase.execute(
        'INSERT INTO trip_points (trip_id, seq, ts, lat, lon) VALUES '
        '(1, 2, 1200, 49.900, 9.200), '
        '(1, 0, 1000, 49.700, 9.000), '
        '(1, 1, 1100, 49.800, 9.100)',
      );

      // A trip with NO points — its endpoints must stay null.
      schema.rawDatabase.execute(
        'INSERT INTO trips (id, started_at, status) '
        "VALUES (2, 2000, 'matched')",
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 7);

      final rows = await db
          .customSelect('SELECT id, start_lat, start_lon, end_lat, end_lon '
              'FROM trips ORDER BY id')
          .get();
      expect(rows, hasLength(2));

      // Trip 1: start = seq 0, end = seq 2.
      expect(rows[0].read<double?>('start_lat'), 49.700);
      expect(rows[0].read<double?>('start_lon'), 9.000);
      expect(rows[0].read<double?>('end_lat'), 49.900);
      expect(rows[0].read<double?>('end_lon'), 9.200);

      // Trip 2: no points → all null.
      expect(rows[1].read<double?>('start_lat'), isNull);
      expect(rows[1].read<double?>('start_lon'), isNull);
      expect(rows[1].read<double?>('end_lat'), isNull);
      expect(rows[1].read<double?>('end_lon'), isNull);
    });
  });
}
