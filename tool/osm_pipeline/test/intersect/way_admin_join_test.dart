import 'dart:typed_data';

import 'package:osm_pipeline/admin/geometry.dart' as geom;
import 'package:osm_pipeline/admin/wkb_writer.dart';
import 'package:osm_pipeline/intersect/way_admin_join.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Synthetic tiny fixture at ~52.5N. All ways/regions share the same lat/lng
// frame; distances are only used for the 1 m epsilon clip, so exact values
// don't need to be precisely tuned.
//
// Regions:
//   R1 (level=8): unit square 13.400..13.402 × 52.500..52.5015
//   R2 (level=8): sits east of R1: 13.402..13.404 × 52.500..52.5015 (shares
//        the border with R1 at lng=13.402)
//   R3 (level=6): a Landkreis covering both R1 and R2:
//        13.400..13.404 × 52.500..52.5015
//
// Same fixture is used across all six levels via [_seedAdminAtLevels] — a
// wholly-contained way then produces exactly one row per level.

/// Insert a way into `ways_raw` (Kfz).
void _insertKfzWay(
  ScratchDb scratch, {
  required int id,
  required List<int> nodeIds,
}) {
  scratch
    ..insertWayKfz(
      id: id,
      nodeIds: nodeIds,
      isDirectional: false,
      onewayTag: null,
      highway: 'residential',
      name: null,
      ref: null,
      maxspeed: null,
    )
    ..flush();
}

/// Insert a node into `nodes_raw`.
void _insertNode(ScratchDb scratch, int id, double lng, double lat) {
  scratch
    ..insertNode(id: id, lat: lat, lng: lng)
    ..flush();
}

/// Build a rectangular admin region as a WKB blob + bbox.
({Uint8List wkb, double minLat, double maxLat, double minLng, double maxLng})
    _rect(double minLng, double minLat, double maxLng, double maxLat) {
  final outer = <geom.Point>[
    geom.Point(minLng, minLat),
    geom.Point(maxLng, minLat),
    geom.Point(maxLng, maxLat),
    geom.Point(minLng, maxLat),
    geom.Point(minLng, minLat),
  ];
  final mp = geom.MultiPolygon([geom.Polygon(outer: outer)]);
  return (
    wkb: encodeMultiPolygon(mp),
    minLat: minLat,
    maxLat: maxLat,
    minLng: minLng,
    maxLng: maxLng,
  );
}

/// Insert a rectangular admin region row.
void _insertAdmin(
  ScratchDb scratch, {
  required int regionId,
  required int adminLevel,
  required double minLng,
  required double minLat,
  required double maxLng,
  required double maxLat,
}) {
  final r = _rect(minLng, minLat, maxLng, maxLat);
  // ensure the admin_regions_raw table exists — the schema is idempotent
  // under the guard in admin_scratch_schema, but we apply it directly here.
  scratch.raw.execute('''
CREATE TABLE IF NOT EXISTS admin_regions_raw (
  region_id       INTEGER PRIMARY KEY,
  osm_relation_id INTEGER NOT NULL,
  admin_level     INTEGER NOT NULL,
  name            TEXT NOT NULL,
  geometry_wkb    BLOB NOT NULL,
  bbox_minlat     REAL NOT NULL,
  bbox_maxlat     REAL NOT NULL,
  bbox_minlng     REAL NOT NULL,
  bbox_maxlng     REAL NOT NULL
);
''');
  scratch.raw.execute(
    'INSERT INTO admin_regions_raw '
    '(region_id, osm_relation_id, admin_level, name, geometry_wkb, '
    'bbox_minlat, bbox_maxlat, bbox_minlng, bbox_maxlng) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      regionId,
      regionId * 100,
      adminLevel,
      'R$regionId',
      r.wkb,
      r.minLat,
      r.maxLat,
      r.minLng,
      r.maxLng,
    ],
  );
}

/// Insert a MultiPolygon admin region with an inner-ring hole.
void _insertAdminWithHole(
  ScratchDb scratch, {
  required int regionId,
  required int adminLevel,
  required double minLng,
  required double minLat,
  required double maxLng,
  required double maxLat,
  required double holeMinLng,
  required double holeMinLat,
  required double holeMaxLng,
  required double holeMaxLat,
}) {
  final outer = <geom.Point>[
    geom.Point(minLng, minLat),
    geom.Point(maxLng, minLat),
    geom.Point(maxLng, maxLat),
    geom.Point(minLng, maxLat),
    geom.Point(minLng, minLat),
  ];
  final hole = <geom.Point>[
    geom.Point(holeMinLng, holeMinLat),
    geom.Point(holeMinLng, holeMaxLat),
    geom.Point(holeMaxLng, holeMaxLat),
    geom.Point(holeMaxLng, holeMinLat),
    geom.Point(holeMinLng, holeMinLat),
  ];
  final mp = geom.MultiPolygon([geom.Polygon(outer: outer, holes: [hole])]);
  final wkb = encodeMultiPolygon(mp);
  scratch.raw.execute('''
CREATE TABLE IF NOT EXISTS admin_regions_raw (
  region_id       INTEGER PRIMARY KEY,
  osm_relation_id INTEGER NOT NULL,
  admin_level     INTEGER NOT NULL,
  name            TEXT NOT NULL,
  geometry_wkb    BLOB NOT NULL,
  bbox_minlat     REAL NOT NULL,
  bbox_maxlat     REAL NOT NULL,
  bbox_minlng     REAL NOT NULL,
  bbox_maxlng     REAL NOT NULL
);
''');
  scratch.raw.execute(
    'INSERT INTO admin_regions_raw '
    '(region_id, osm_relation_id, admin_level, name, geometry_wkb, '
    'bbox_minlat, bbox_maxlat, bbox_minlng, bbox_maxlng) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      regionId,
      regionId * 100,
      adminLevel,
      'R$regionId-hole',
      wkb,
      minLat,
      maxLat,
      minLng,
      maxLng,
    ],
  );
}

List<Row> _selectRows(
  ScratchDb s,
  String sql, [
  List<Object?> args = const [],
]) {
  return s.raw.select(sql, args).toList();
}

void main() {
  group('buildWayAdminJoin', () {
    late ScratchDb scratch;

    setUp(() {
      scratch = ScratchDb.openTempFile();
    });
    tearDown(() {
      scratch.close(deleteFile: true);
    });

    test('way wholly inside one region at all six levels → 6 rows', () async {
      // A single admin region at every level covers the box; way sits inside.
      for (final lvl in [2, 4, 6, 8, 9, 10]) {
        _insertAdmin(
          scratch,
          regionId: lvl,
          adminLevel: lvl,
          minLng: 13.400,
          minLat: 52.500,
          maxLng: 13.402,
          maxLat: 52.5015,
        );
      }
      _insertNode(scratch, 1, 13.4005, 52.5005);
      _insertNode(scratch, 2, 13.4015, 52.5010);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2]);

      final stats = await buildWayAdminJoin(scratch);
      expect(stats.rowsWritten, 6);
      expect(stats.waysProcessed, 1);

      final rows = _selectRows(
        scratch,
        'SELECT admin_level, fraction_start, fraction_end '
        'FROM way_admin_raw ORDER BY admin_level;',
      );
      expect(rows, hasLength(6));
      for (final row in rows) {
        expect(row['fraction_start'] as double, closeTo(0.0, 1e-9));
        expect(row['fraction_end'] as double, closeTo(1.0, 1e-9));
      }
    });

    test('way crossing border between two L=8 regions → 2 rows at L=8',
        () async {
      _insertAdmin(
        scratch,
        regionId: 1,
        adminLevel: 8,
        minLng: 13.400,
        minLat: 52.500,
        maxLng: 13.402,
        maxLat: 52.5015,
      );
      _insertAdmin(
        scratch,
        regionId: 2,
        adminLevel: 8,
        minLng: 13.402,
        minLat: 52.500,
        maxLng: 13.404,
        maxLat: 52.5015,
      );
      // Way runs east through both.
      _insertNode(scratch, 1, 13.4010, 52.5008);
      _insertNode(scratch, 2, 13.4030, 52.5008);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2]);

      await buildWayAdminJoin(scratch);
      final rows = _selectRows(
        scratch,
        'SELECT region_id, fraction_start, fraction_end FROM way_admin_raw '
        'WHERE admin_level = 8 ORDER BY fraction_start;',
      );
      expect(rows, hasLength(2));
      expect(rows[0]['region_id'] as int, 1);
      expect(rows[0]['fraction_start'] as double, closeTo(0.0, 1e-9));
      expect(rows[0]['fraction_end'] as double, closeTo(0.5, 0.02));
      expect(rows[1]['region_id'] as int, 2);
      expect(rows[1]['fraction_start'] as double, closeTo(0.5, 0.02));
      expect(rows[1]['fraction_end'] as double, closeTo(1.0, 1e-9));
    });

    test('way entering and re-entering same region → 2 rows for that region',
        () async {
      _insertAdmin(
        scratch,
        regionId: 1,
        adminLevel: 8,
        minLng: 13.400,
        minLat: 52.500,
        maxLng: 13.402,
        maxLat: 52.5015,
      );
      // Way runs: outside → inside → outside → inside → outside (5 points).
      _insertNode(scratch, 1, 13.3990, 52.5008); // outside west
      _insertNode(scratch, 2, 13.4010, 52.5008); // inside
      _insertNode(scratch, 3, 13.4030, 52.5008); // outside east
      _insertNode(scratch, 4, 13.4010, 52.5008); // inside again (folds back)
      _insertNode(scratch, 5, 13.3990, 52.5008); // outside west again
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2, 3, 4, 5]);

      await buildWayAdminJoin(scratch);
      final rows = _selectRows(
        scratch,
        'SELECT fraction_start, fraction_end FROM way_admin_raw '
        'WHERE region_id = 1 ORDER BY fraction_start;',
      );
      expect(rows, hasLength(2));
      // Each hit should be a strict interior slice.
      for (final row in rows) {
        expect(row['fraction_start'] as double, greaterThan(0.0));
        expect(row['fraction_end'] as double, lessThan(1.0));
      }
    });

    test('way not intersecting any region → 0 rows', () async {
      _insertAdmin(
        scratch,
        regionId: 1,
        adminLevel: 8,
        minLng: 13.400,
        minLat: 52.500,
        maxLng: 13.402,
        maxLat: 52.5015,
      );
      _insertNode(scratch, 1, 14, 53);
      _insertNode(scratch, 2, 14.001, 53.001);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2]);

      final stats = await buildWayAdminJoin(scratch);
      expect(stats.rowsWritten, 0);
      expect(scratch.countRows('way_admin_raw'), 0);
    });

    test('multipolygon with hole: way crossing the hole → no row for hole',
        () async {
      // Outer 13.400..13.404 × 52.500..52.5015; hole in the middle:
      // 13.4015..13.4025 × 52.5006..52.5009.
      _insertAdminWithHole(
        scratch,
        regionId: 1,
        adminLevel: 8,
        minLng: 13.400,
        minLat: 52.500,
        maxLng: 13.404,
        maxLat: 52.5015,
        holeMinLng: 13.4015,
        holeMinLat: 52.5006,
        holeMaxLng: 13.4025,
        holeMaxLat: 52.5009,
      );
      // Way runs west→east across the region and passes through the hole.
      _insertNode(scratch, 1, 13.4005, 52.50075);
      _insertNode(scratch, 2, 13.4035, 52.50075);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2]);

      await buildWayAdminJoin(scratch);
      final rows = _selectRows(
        scratch,
        'SELECT fraction_start, fraction_end FROM way_admin_raw '
        'WHERE region_id = 1 ORDER BY fraction_start;',
      );
      // Expect two sub-segments: before hole and after hole.
      expect(rows, hasLength(2));
    });
  });
}
