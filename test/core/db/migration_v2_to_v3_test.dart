import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../generated_migrations/schema.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  group('v2 → v3 migration', () {
    test('database upgrades from v2 to v3 without errors', () async {
      final connection = await verifier.startAt(2);
      final db = AppDatabase(connection);
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 3);
    });

    test('v2 trip row survives upgrade unchanged', () async {
      final connection = await verifier.startAt(2);
      final db = AppDatabase(connection);
      addTearDown(db.close);

      // Seed a trips row at schema v2 (includes v2 bbox/pointCount columns).
      await db.customStatement(
        'INSERT INTO trips (started_at, status, manually_started, auto_stopped) '
        "VALUES (strftime('%s', 'now'), 'pending', 0, 0)",
      );

      await verifier.migrateAndValidate(db, 3);

      // Existing v2 row must still be there.
      final rows = await db.customSelect('SELECT * FROM trips').get();
      expect(rows, hasLength(1));
    });

    test('new tables exist and are empty post-migration', () async {
      final connection = await verifier.startAt(2);
      final db = AppDatabase(connection);
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 3);

      final cache = await db
          .customSelect('SELECT COUNT(*) AS c FROM overpass_way_cache')
          .getSingle();
      expect(cache.read<int>('c'), 0);

      final pending = await db
          .customSelect('SELECT COUNT(*) AS c FROM pending_road_fetches')
          .getSingle();
      expect(pending.read<int>('c'), 0);
    });

    test(
        'overpass_way_cache accepts inserts on the composite (z,x,y) primary key',
        () async {
      final connection = await verifier.startAt(2);
      final db = AppDatabase(connection);
      addTearDown(db.close);

      await verifier.migrateAndValidate(db, 3);

      await db.customStatement(
        'INSERT INTO overpass_way_cache '
        '(tile_z, tile_x, tile_y, fetched_at, way_count, payload_gzip, '
        'payload_bytes) '
        "VALUES (12, 100, 200, strftime('%s', 'now'), 5, X'0102', 2)",
      );
      final rows = await db
          .customSelect('SELECT * FROM overpass_way_cache')
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.read<int>('tile_z'), 12);
      expect(rows.first.read<int>('way_count'), 5);
    });
  });
}
