import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v1 → v2 migration', () {
    test('database upgrades from v1 to v2 without errors', () async {
      final connection = await verifier.startAt(1);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 2);
    });

    test('v1 trip row survives upgrade with NULL bbox and pointCount', () async {
      // Seed at v1 via the raw schema DB (NOT the full AppDatabase) so the
      // insert does not open AppDatabase and prematurely run onUpgrade all the
      // way to the current schemaVersion. This became load-bearing at v4 —
      // the first destructive migration — where opening at the app version
      // would drop the vehicle schema before migrateAndValidate(db, 2) can
      // compare against the v2 snapshot. See drift `schemaAt` docs.
      final schema = await verifier.schemaAt(1);

      // Seed a trips row at schema v1 (only v1 columns).
      schema.rawDatabase.execute(
        // SQL string literals require double quotes for compatibility with
        // single-quoted SQL values; cannot use Dart single quotes here.
        // ignore: prefer_single_quotes
        "INSERT INTO trips (started_at, status, manually_started, auto_stopped) "
        "VALUES (strftime('%s', 'now'), 'pending', 0, 0)",
      );

      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);

      // Trigger the v1→v2 migration.
      await verifier.migrateAndValidate(db, 2);

      // After migration, the row must still exist.
      final rows = await db.customSelect('SELECT * FROM trips').get();
      expect(rows, hasLength(1));

      // New columns must be NULL (addColumn with nullable() — no DEFAULT).
      final row = rows.first;
      expect(row.read<double?>('bbox_min_lat'), isNull);
      expect(row.read<double?>('bbox_min_lon'), isNull);
      expect(row.read<double?>('bbox_max_lat'), isNull);
      expect(row.read<double?>('bbox_max_lon'), isNull);
      expect(row.read<int?>('point_count'), isNull);
    });
  });
}
