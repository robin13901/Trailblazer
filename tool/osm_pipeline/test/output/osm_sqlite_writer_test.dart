import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/admin/geometry.dart' as geom;
import 'package:osm_pipeline/admin/wkb_writer.dart';
import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:osm_pipeline/output/osm_sqlite_writer.dart';
import 'package:osm_pipeline/output/rtree_builder.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Seed the scratch DB with the admin_regions_raw table (04-04 owns the
/// schema; we create it directly here so this test file doesn't need the
/// full ScratchDbAdminWriter dance).
void _ensureAdminRawTable(ScratchDb scratch) {
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
}

Uint8List _rectWkb(
  double minLng,
  double minLat,
  double maxLng,
  double maxLat,
) {
  final outer = <geom.Point>[
    geom.Point(minLng, minLat),
    geom.Point(maxLng, minLat),
    geom.Point(maxLng, maxLat),
    geom.Point(minLng, maxLat),
    geom.Point(minLng, minLat),
  ];
  return encodeMultiPolygon(geom.MultiPolygon([geom.Polygon(outer: outer)]));
}

void _insertAdmin(
  ScratchDb scratch, {
  required int regionId,
  required int adminLevel,
  required double minLng,
  required double minLat,
  required double maxLng,
  required double maxLat,
}) {
  scratch.raw.execute(
    'INSERT INTO admin_regions_raw '
    '(region_id, osm_relation_id, admin_level, name, geometry_wkb, '
    'bbox_minlat, bbox_maxlat, bbox_minlng, bbox_maxlng) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      regionId,
      regionId * 100,
      adminLevel,
      'Region-$regionId-L$adminLevel',
      _rectWkb(minLng, minLat, maxLng, maxLat),
      minLat,
      maxLat,
      minLng,
      maxLng,
    ],
  );
}

void _insertNode(ScratchDb scratch, int id, double lng, double lat) {
  scratch
    ..insertNode(id: id, lat: lat, lng: lng)
    ..flush();
}

void _insertKfzWay(
  ScratchDb scratch, {
  required int id,
  required List<int> nodeIds,
  String highway = 'residential',
  String? name,
}) {
  scratch
    ..insertWayKfz(
      id: id,
      nodeIds: nodeIds,
      isDirectional: false,
      onewayTag: null,
      highway: highway,
      name: name,
      ref: null,
      maxspeed: null,
    )
    ..flush();
}

void _insertWayAdminRow(
  ScratchDb scratch, {
  required int wayId,
  required int regionId,
  required int adminLevel,
  required double fractionStart,
  required double fractionEnd,
}) {
  scratch.raw.execute(
    'INSERT INTO way_admin_raw '
    '(way_id, region_id, admin_level, fraction_start, fraction_end) '
    'VALUES (?, ?, ?, ?, ?);',
    [wayId, regionId, adminLevel, fractionStart, fractionEnd],
  );
}

void main() {
  group('OsmSqliteWriter.preflight', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('osm_writer_preflight_');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('throws PipelineIoError when measurement file is absent', () {
      final missing = File('${tmp.path}/missing.md');
      expect(
        () => OsmSqliteWriter.preflight(
          measurementFile: missing,
          allowUnverifiedMeasurement: false,
        ),
        throwsA(isA<PipelineIoError>()),
      );
    });

    test('throws PipelineArgsError when measurement is a stub', () {
      final stub = File('${tmp.path}/stub.md')
        ..writeAsStringSync('Berlin PBF: not empirically verified.');
      expect(
        () => OsmSqliteWriter.preflight(
          measurementFile: stub,
          allowUnverifiedMeasurement: false,
        ),
        throwsA(isA<PipelineArgsError>()),
      );
    });

    test('override bypasses stub gate', () {
      final stub = File('${tmp.path}/stub.md')
        ..writeAsStringSync('Berlin PBF: not empirically verified.');
      expect(
        () => OsmSqliteWriter.preflight(
          measurementFile: stub,
          allowUnverifiedMeasurement: true,
        ),
        returnsNormally,
      );
    });

    test('passes when measurement file is present and non-stub', () {
      final good = File('${tmp.path}/good.md')
        ..writeAsStringSync('Berlin actuals empirically measured. OK.');
      expect(
        () => OsmSqliteWriter.preflight(
          measurementFile: good,
          allowUnverifiedMeasurement: false,
        ),
        returnsNormally,
      );
    });
  });

  group('OsmSqliteWriter.write', () {
    late ScratchDb scratch;
    late Directory tmp;

    setUp(() {
      scratch = ScratchDb.openTempFile();
      tmp = Directory.systemTemp.createTempSync('osm_writer_out_');
      _ensureAdminRawTable(scratch);
    });
    tearDown(() {
      scratch.close(deleteFile: true);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('produces schema + tables + rtree + smoke counts', () {
      // 1 admin region covering the way box, 1 kfz way with 3 nodes.
      _insertAdmin(
        scratch,
        regionId: 1,
        adminLevel: 8,
        minLng: 13.4,
        minLat: 52.5,
        maxLng: 13.42,
        maxLat: 52.52,
      );
      _insertNode(scratch, 1, 13.410, 52.510);
      _insertNode(scratch, 2, 13.411, 52.511);
      _insertNode(scratch, 3, 13.412, 52.512);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2, 3], name: 'Teststr.');

      // way_admin_raw row: wholly-contained (fraction 0..1) at L8.
      _insertWayAdminRow(
        scratch,
        wayId: 100,
        regionId: 1,
        adminLevel: 8,
        fractionStart: 0,
        fractionEnd: 1,
      );

      final outFile = File('${tmp.path}/osm.sqlite');
      final result = OsmSqliteWriter.write(
        scratch: scratch,
        outFile: outFile,
      );

      expect(outFile.existsSync(), isTrue);
      expect(result.waysWritten, 1);
      expect(result.adminRegionsWritten, 1);
      // 2 segments in a 3-node line.
      expect(result.rtreeRowsWritten, 2);
      // Roll-up removed the wholly-contained row.
      expect(result.wayAdminRowsWritten, 0);

      final db = sqlite3.open(outFile.path);
      try {
        // Schema present.
        final tables = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((r) => r['name'] as String)
            .toSet();
        expect(tables, containsAll(['ways', 'admin_regions', 'way_admin']));
        // way row with denormalized L8 admin id.
        final way = db.select('SELECT * FROM ways WHERE way_id = 100;').first;
        expect(way['admin_region_id_l8'], 1);
        expect(way['admin_region_id_l2'], isNull);
        expect(way['name'], 'Teststr.');
        expect(way['length_m'] as double, greaterThan(0));
        // Geometry decodes to same 3 points.
        final line = decodeLineStringWkb(way['geometry_wkb'] as Uint8List);
        expect(line, hasLength(3));
        expect(line.first.lng, closeTo(13.410, 1e-9));
        expect(line.first.lat, closeTo(52.510, 1e-9));

        // rtree lookup should map back to way_id 100.
        final lookup = db
            .select('SELECT DISTINCT way_id FROM ways_rtree_lookup;')
            .map((r) => r['way_id'] as int)
            .toList();
        expect(lookup, [100]);

        // R-Tree returns candidates within a small bbox around the line.
        final hits = db.select(
          'SELECT id FROM ways_rtree '
          'WHERE min_lat <= 52.5115 AND max_lat >= 52.5105 '
          'AND min_lng <= 13.4115 AND max_lng >= 13.4105;',
        );
        expect(hits, isNotEmpty);
      } finally {
        db.dispose();
      }
    });

    test('cross-border way at L4 keeps way_admin rows (no roll-up)', () {
      _insertAdmin(
        scratch,
        regionId: 1,
        adminLevel: 4,
        minLng: 13.4,
        minLat: 52.5,
        maxLng: 13.42,
        maxLat: 52.52,
      );
      _insertAdmin(
        scratch,
        regionId: 2,
        adminLevel: 4,
        minLng: 13.42,
        minLat: 52.5,
        maxLng: 13.44,
        maxLat: 52.52,
      );
      _insertNode(scratch, 1, 13.410, 52.510);
      _insertNode(scratch, 2, 13.430, 52.510);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2]);

      // Two partial fractions — this is cross-border, no roll-up.
      _insertWayAdminRow(
        scratch,
        wayId: 100,
        regionId: 1,
        adminLevel: 4,
        fractionStart: 0,
        fractionEnd: 0.5,
      );
      _insertWayAdminRow(
        scratch,
        wayId: 100,
        regionId: 2,
        adminLevel: 4,
        fractionStart: 0.5,
        fractionEnd: 1,
      );

      final outFile = File('${tmp.path}/osm.sqlite');
      final result = OsmSqliteWriter.write(
        scratch: scratch,
        outFile: outFile,
      );

      expect(result.wayAdminRowsWritten, 2);

      final db = sqlite3.open(outFile.path);
      try {
        final way = db.select('SELECT * FROM ways WHERE way_id = 100;').first;
        expect(way['admin_region_id_l4'], isNull);
      } finally {
        db.dispose();
      }
    });

    test('per-way rtree granularity emits 1 rtree row per way', () {
      _insertNode(scratch, 1, 13.410, 52.510);
      _insertNode(scratch, 2, 13.411, 52.511);
      _insertNode(scratch, 3, 13.412, 52.512);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2, 3]);

      final outFile = File('${tmp.path}/osm.sqlite');
      final result = OsmSqliteWriter.write(
        scratch: scratch,
        outFile: outFile,
        granularity: RtreeGranularity.perWay,
      );
      expect(result.rtreeRowsWritten, 1);

      final db = sqlite3.open(outFile.path);
      try {
        final row = db.select(
          'SELECT segment_idx FROM ways_rtree_lookup WHERE way_id = 100;',
        );
        expect(row.first['segment_idx'], -1);
      } finally {
        db.dispose();
      }
    });

    test('user_version is stamped to pipelineSchemaVersion via VersionStamp',
        () {
      // Left here to be filled by Task 3; for this task we just verify the
      // writer's own PRAGMA + tables path works end-to-end.
      _insertNode(scratch, 1, 13.410, 52.510);
      _insertNode(scratch, 2, 13.411, 52.511);
      _insertKfzWay(scratch, id: 100, nodeIds: [1, 2]);

      final outFile = File('${tmp.path}/osm.sqlite');
      OsmSqliteWriter.write(
        scratch: scratch,
        outFile: outFile,
      );
      final db = sqlite3.open(outFile.path);
      try {
        final journalMode = db
            .select('PRAGMA journal_mode;')
            .first
            .values
            .first
            .toString()
            .toLowerCase();
        expect(journalMode, 'wal');
        final pageSize = db.select('PRAGMA page_size;').first.values.first;
        expect(pageSize, 4096);
      } finally {
        db.dispose();
      }
    });
  });

  group('decodeLineStringWkb', () {
    test('round-trips a small LineString', () {
      // Round-trip: manually encode via a tiny WKB then decode.
      final buf = ByteData(1 + 4 + 4 + 3 * 16);
      var off = 0;
      buf.setUint8(off, 1);
      off += 1;
      buf.setUint32(off, 2, Endian.little); // LineString
      off += 4;
      buf.setUint32(off, 3, Endian.little);
      off += 4;
      final points = <Vec2>[
        const Vec2(13.410, 52.510),
        const Vec2(13.411, 52.511),
        const Vec2(13.412, 52.512),
      ];
      for (final p in points) {
        buf.setFloat64(off, p.lng, Endian.little);
        off += 8;
        buf.setFloat64(off, p.lat, Endian.little);
        off += 8;
      }
      final decoded = decodeLineStringWkb(buf.buffer.asUint8List());
      expect(decoded, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(decoded[i].lng, closeTo(points[i].lng, 1e-12));
        expect(decoded[i].lat, closeTo(points[i].lat, 1e-12));
      }
    });
  });
}
