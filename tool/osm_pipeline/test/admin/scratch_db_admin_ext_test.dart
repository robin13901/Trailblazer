import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/admin/admin_pipeline.dart';
import 'package:osm_pipeline/scratch/admin_scratch_schema.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:osm_pipeline/scratch/scratch_db_admin_ext.dart';
import 'package:test/test.dart';

void main() {
  group('ScratchDbAdminWriter (real sqlite3)', () {
    late ScratchDb scratch;

    setUp(() {
      scratch = ScratchDb.openTempFile();
    });

    tearDown(() {
      scratch.close(deleteFile: true);
    });

    test('applyAdminSchema executes admin_scratch CREATE statements', () {
      final writer = ScratchDbAdminWriter(scratch)..applyAdminSchema();
      addTearDown(writer.dispose);
      final tables = scratch.raw.select(
        'SELECT name FROM sqlite_master '
        "WHERE type='table' AND name='admin_regions_raw';",
      );
      expect(tables.length, 1);
    });

    test('insertAdminRegion round-trips a full row', () async {
      final writer = ScratchDbAdminWriter(scratch)..applyAdminSchema();
      addTearDown(writer.dispose);
      final wkb = Uint8List.fromList([1, 6, 0, 0, 0, 1, 0, 0, 0]);
      await writer.insertAdminRegion(
        regionId: 42,
        osmRelationId: 51477,
        adminLevel: 8,
        name: 'Beispielgemeinde',
        geometryWkb: wkb,
        bboxMinLat: 51,
        bboxMaxLat: 51.5,
        bboxMinLng: 6,
        bboxMaxLng: 6.5,
      );
      final rows = scratch.raw.select(
        'SELECT * FROM admin_regions_raw WHERE region_id = 42;',
      );
      expect(rows.length, 1);
      final r = rows.first;
      expect(r['osm_relation_id'], 51477);
      expect(r['admin_level'], 8);
      expect(r['name'], 'Beispielgemeinde');
      expect(r['bbox_minlat'], 51.0);
      expect(r['bbox_maxlat'], 51.5);
      expect(r['bbox_minlng'], 6.0);
      expect(r['bbox_maxlng'], 6.5);
      final storedWkb = r['geometry_wkb'] as Uint8List;
      expect(storedWkb, orderedEquals(wkb));
    });

    test('extractAdminRegions writes 1 row for the tiny fixture', () async {
      final fixture = File('test/fixtures/tiny.osm.pbf');
      final writer = ScratchDbAdminWriter(scratch);
      final summary = await extractAdminRegions(
        pbf: fixture,
        writer: writer,
      );
      addTearDown(writer.dispose);
      expect(summary.regionsWritten, 1);
      final n = scratch.raw
          .select('SELECT COUNT(*) AS c FROM admin_regions_raw;')
          .first['c'] as int;
      expect(n, 1);
    });
  });

  group('admin_scratch_schema', () {
    test('kAdminScratchSchema contains a CREATE for admin_regions_raw', () {
      final joined = kAdminScratchSchema.join('\n');
      expect(joined, contains('admin_regions_raw'));
      expect(joined, contains('geometry_wkb'));
      expect(joined, contains('idx_admin_regions_raw_level'));
    });
  });
}
