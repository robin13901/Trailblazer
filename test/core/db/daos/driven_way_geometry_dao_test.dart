// DrivenWayGeometryDao tests against in-memory Drift DB.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_geometry_dao.dart';
import 'package:auto_explore/features/coverage/data/driven_way_geometry_codec.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

void main() {
  late AppDatabase db;
  late DrivenWayGeometryDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = DrivenWayGeometryDao(db);
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async => db.close());

  test('getCachedWayIds returns empty set initially', () async {
    expect(await dao.getCachedWayIds(), isEmpty);
  });

  test('upsertBatch + getCachedWayIds', () async {
    await dao.upsertBatch([
      DrivenWayGeometryCompanion.insert(
        wayId: const Value(1),
        geometryJson: encodeWayGeometry(
          const [LatLng(49.01, 9.01), LatLng(49.02, 9.02)],
        ),
      ),
      DrivenWayGeometryCompanion.insert(
        wayId: const Value(2),
        geometryJson: encodeWayGeometry(
          const [LatLng(50.01, 10.01), LatLng(50.02, 10.02)],
        ),
      ),
    ]);

    expect(await dao.getCachedWayIds(), {1, 2});
    final rows = await dao.getAllRows();
    expect(rows, hasLength(2));
  });

  test('upsertBatch is idempotent (INSERT OR REPLACE)', () async {
    final geom1 = encodeWayGeometry(
      const [LatLng(49.01, 9.01), LatLng(49.02, 9.02)],
    );
    final geom2 = encodeWayGeometry(
      const [LatLng(49.03, 9.03), LatLng(49.04, 9.04)],
    );
    await dao.upsertBatch([
      DrivenWayGeometryCompanion.insert(
        wayId: const Value(1),
        geometryJson: geom1,
      ),
    ]);
    await dao.upsertBatch([
      DrivenWayGeometryCompanion.insert(
        wayId: const Value(1),
        geometryJson: geom2,
      ),
    ]);

    final rows = await dao.getAllRows();
    expect(rows, hasLength(1));
    expect(rows.first.geometryJson, geom2);
  });

  test('deleteAll clears all rows', () async {
    await dao.upsertBatch([
      DrivenWayGeometryCompanion.insert(
        wayId: const Value(1),
        geometryJson: encodeWayGeometry(
          const [LatLng(49.01, 9.01), LatLng(49.02, 9.02)],
        ),
      ),
    ]);
    expect(await dao.deleteAll(), 1);
    expect(await dao.getAllRows(), isEmpty);
  });

  test('watchRevision advances on upsert', () async {
    final emissions = <int>[];
    final sub = dao.watchRevision().listen(emissions.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    expect(emissions, [0]);

    await dao.upsertBatch([
      DrivenWayGeometryCompanion.insert(
        wayId: const Value(42),
        geometryJson: encodeWayGeometry(
          const [LatLng(49.01, 9.01), LatLng(49.02, 9.02)],
        ),
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(emissions.last, 1);
  });
}
