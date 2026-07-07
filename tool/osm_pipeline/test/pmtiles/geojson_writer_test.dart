import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/admin/geometry.dart' as geom;
import 'package:osm_pipeline/admin/wkb_writer.dart';
import 'package:osm_pipeline/pmtiles/geojson_writer.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:test/test.dart';

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
  required String name,
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
      name,
      _rectWkb(minLng, minLat, maxLng, maxLat),
      minLat,
      maxLat,
      minLng,
      maxLng,
    ],
  );
}

/// Collect all output from [file] into a single string. The caller must
/// have already flushed and closed the underlying sink before reading.
Future<String> _readAllLines(File file) async {
  return file.readAsString();
}

void main() {
  group('writeRoads', () {
    late ScratchDb scratch;
    late Directory tmp;

    setUp(() {
      scratch = ScratchDb.openTempFile();
      tmp = Directory.systemTemp.createTempSync('geojson_test_');
    });

    tearDown(() {
      scratch.close(deleteFile: true);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test(
      'emits one feature per Kfz + Feldweg way with correct kind + oneway '
      '(v2 invariant: Feldweg MUST land in pmtiles roads.geojsonl even '
      'though it is dropped from osm.sqlite — REN-02)',
      () async {
        // Two nodes shared by both ways.
        scratch
          ..insertNode(id: 1, lat: 52.5, lng: 13.4)
          ..insertNode(id: 2, lat: 52.51, lng: 13.41)
          ..insertNode(id: 3, lat: 52.52, lng: 13.42)
          ..flush()
          ..insertWayKfz(
            id: 100,
            nodeIds: [1, 2],
            isDirectional: true,
            onewayTag: 'yes',
            highway: 'motorway',
            name: 'Autobahn 1',
            ref: 'A1',
            maxspeed: '130',
          )
          ..insertWayFeldweg(
            id: 200,
            nodeIds: [2, 3],
            highway: 'track',
            name: null,
            surface: 'gravel',
            motorVehicle: 'yes',
            service: null,
          )
          ..flush();

        final out = File('${tmp.path}/roads.geojsonl');
        final sink = out.openWrite();
        final n = await GeoJsonSeqWriter.writeRoads(scratch, sink);
        await sink.close();
        expect(n, 2);

        final lines = (await _readAllLines(out)).trim().split('\n');
        expect(lines, hasLength(2));

        final f1 = jsonDecode(lines[0]) as Map<String, Object?>;
        expect(f1['type'], 'Feature');
        final geom1 = f1['geometry']! as Map<String, Object?>;
        expect(geom1['type'], 'LineString');
        final coords1 = geom1['coordinates']! as List<Object?>;
        expect(coords1, hasLength(2));
        final firstPair = coords1.first! as List<Object?>;
        expect(firstPair[0], closeTo(13.4, 1e-9));
        expect(firstPair[1], closeTo(52.5, 1e-9));
        final props1 = f1['properties']! as Map<String, Object?>;
        expect(props1['kind'], 'motorway');
        expect(props1['name'], 'Autobahn 1');
        expect(props1['ref'], 'A1');
        expect(props1['oneway'], isTrue);

        final f2 = jsonDecode(lines[1]) as Map<String, Object?>;
        final props2 = f2['properties']! as Map<String, Object?>;
        expect(props2['kind'], 'track');
        expect(props2['oneway'], isFalse);
        expect(props2.containsKey('name'), isFalse);
      },
    );

    test('skips ways with fewer than 2 resolved node coordinates', () async {
      scratch
        ..insertNode(id: 1, lat: 52.5, lng: 13.4)
        ..flush()
        ..insertWayKfz(
          id: 300,
          nodeIds: [1, 999], // 999 unresolved
          isDirectional: false,
          onewayTag: null,
          highway: 'residential',
          name: null,
          ref: null,
          maxspeed: null,
        )
        ..flush();

      final out = File('${tmp.path}/roads.geojsonl');
      final sink = out.openWrite();
      final n = await GeoJsonSeqWriter.writeRoads(scratch, sink);
      await sink.close();
      expect(n, 0);
      expect(await out.readAsString(), isEmpty);
    });

    test('collapses residential to minor kind', () async {
      scratch
        ..insertNode(id: 1, lat: 52.5, lng: 13.4)
        ..insertNode(id: 2, lat: 52.51, lng: 13.41)
        ..flush()
        ..insertWayKfz(
          id: 400,
          nodeIds: [1, 2],
          isDirectional: false,
          onewayTag: null,
          highway: 'residential',
          name: 'Hauptstraße',
          ref: null,
          maxspeed: '50',
        )
        ..flush();

      final out = File('${tmp.path}/roads.geojsonl');
      final sink = out.openWrite();
      await GeoJsonSeqWriter.writeRoads(scratch, sink);
      await sink.close();

      final line = (await out.readAsString()).trim();
      final feature = jsonDecode(line) as Map<String, Object?>;
      final props = feature['properties']! as Map<String, Object?>;
      expect(props['kind'], 'minor');
    });

    test('JSON-escapes names with quotes and backslashes', () async {
      scratch
        ..insertNode(id: 1, lat: 52.5, lng: 13.4)
        ..insertNode(id: 2, lat: 52.51, lng: 13.41)
        ..flush()
        ..insertWayKfz(
          id: 500,
          nodeIds: [1, 2],
          isDirectional: false,
          onewayTag: null,
          highway: 'residential',
          name: r'Der "Nord" Weg\Süd',
          ref: null,
          maxspeed: null,
        )
        ..flush();

      final out = File('${tmp.path}/roads.geojsonl');
      final sink = out.openWrite();
      await GeoJsonSeqWriter.writeRoads(scratch, sink);
      await sink.close();

      final line = (await out.readAsString()).trim();
      // Must be parseable as JSON — this is the true escaping test.
      final feature = jsonDecode(line) as Map<String, Object?>;
      final props = feature['properties']! as Map<String, Object?>;
      expect(props['name'], r'Der "Nord" Weg\Süd');
    });
  });

  group('writeAdminBoundaries', () {
    late ScratchDb scratch;
    late Directory tmp;

    setUp(() {
      scratch = ScratchDb.openTempFile();
      _ensureAdminRawTable(scratch);
      tmp = Directory.systemTemp.createTempSync('geojson_test_');
    });

    tearDown(() {
      scratch.close(deleteFile: true);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('emits fill + outline features per admin region', () async {
      _insertAdmin(
        scratch,
        regionId: 1,
        adminLevel: 4,
        name: 'Berlin',
        minLng: 13,
        minLat: 52,
        maxLng: 14,
        maxLat: 53,
      );

      final out = File('${tmp.path}/admin.geojsonl');
      final sink = out.openWrite();
      final n = await GeoJsonSeqWriter.writeAdminBoundaries(scratch, sink);
      await sink.close();
      expect(n, 2);

      final lines = (await out.readAsString()).trim().split('\n');
      expect(lines, hasLength(2));

      final fill = jsonDecode(lines[0]) as Map<String, Object?>;
      final fillGeom = fill['geometry']! as Map<String, Object?>;
      expect(fillGeom['type'], 'MultiPolygon');
      final fillProps = fill['properties']! as Map<String, Object?>;
      expect(fillProps['admin_level'], 4);
      expect(fillProps['kind'], 'state');
      expect(fillProps['name'], 'Berlin');
      expect(fillProps['shape'], 'fill');

      final outline = jsonDecode(lines[1]) as Map<String, Object?>;
      final outlineGeom = outline['geometry']! as Map<String, Object?>;
      expect(outlineGeom['type'], 'MultiLineString');
      final outlineProps = outline['properties']! as Map<String, Object?>;
      expect(outlineProps['shape'], 'outline');
      expect(outlineProps['admin_level'], 4);
    });

    test('emits 0 features when admin_regions_raw is absent', () async {
      final scratch2 = ScratchDb.openTempFile();
      try {
        final out = File('${tmp.path}/admin.geojsonl');
        final sink = out.openWrite();
        final n = await GeoJsonSeqWriter.writeAdminBoundaries(scratch2, sink);
        await sink.close();
        expect(n, 0);
      } finally {
        scratch2.close(deleteFile: true);
      }
    });
  });

  group('writeWater / writeLabels on tiny fixture', () {
    late ScratchDb scratch;
    late Directory tmp;
    late File tinyPbf;

    setUp(() {
      scratch = ScratchDb.openTempFile();
      tmp = Directory.systemTemp.createTempSync('geojson_test_');
      tinyPbf = File('test/fixtures/tiny.osm.pbf');
    });

    tearDown(() {
      scratch.close(deleteFile: true);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('writeWater emits 0 features when fixture has no water', () async {
      final out = File('${tmp.path}/water.geojsonl');
      final sink = out.openWrite();
      final n = await GeoJsonSeqWriter.writeWater(tinyPbf, scratch, sink);
      await sink.close();
      expect(n, 0);
      expect(await out.readAsString(), isEmpty);
    });

    test('writeLabels emits shield labels for primary ways with ref', () async {
      // The tiny fixture has one primary way with ref=M1 → one road_shield.
      final out = File('${tmp.path}/labels.geojsonl');
      final sink = out.openWrite();
      final n = await GeoJsonSeqWriter.writeLabels(tinyPbf, scratch, sink);
      await sink.close();
      expect(n, 1);
      final lines = (await out.readAsString()).trim().split('\n');
      expect(lines, hasLength(1));
      final feature = jsonDecode(lines.first) as Map<String, Object?>;
      final props = feature['properties']! as Map<String, Object?>;
      expect(props['kind'], 'road_shield');
      expect(props['ref'], 'M1');
      final geometry = feature['geometry']! as Map<String, Object?>;
      expect(geometry['type'], 'Point');
    });
  });
}
