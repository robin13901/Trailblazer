import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/output/osm_sqlite_writer.dart';
import 'package:osm_pipeline/output/pipeline_orchestrator.dart';
import 'package:osm_pipeline/schema.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _tinyFixturePath = 'test/fixtures/tiny.osm.pbf';

void main() {
  group('runPipeline (tiny fixture end-to-end)', () {
    late Directory tmpOut;
    late File goodMeasurement;

    setUp(() {
      tmpOut = Directory.systemTemp.createTempSync('pipeline_e2e_');
      goodMeasurement = File('${tmpOut.path}/measurement.md')
        ..writeAsStringSync(
          '# Berlin measurement — real run, empirically verified.',
        );
    });
    tearDown(() {
      if (tmpOut.existsSync()) tmpOut.deleteSync(recursive: true);
    });

    test('produces osm.sqlite with all expected tables + metadata', () async {
      final result = await runPipeline(
        pbf: File(_tinyFixturePath),
        outDir: tmpOut,
        measurementFile: goodMeasurement,
        gitShaResolver: () => 'fixture-sha',
        nowUtc: DateTime.utc(2026, 7, 6, 10),
      );

      expect(File(result.osmSqlitePath).existsSync(), isTrue);
      expect(result.osmSqliteBytes, greaterThan(0));

      final db = sqlite3.open(result.osmSqlitePath);
      try {
        // user_version stamped to pipelineSchemaVersion.
        final uv = db.select('PRAGMA user_version;').first.values.first;
        expect(uv, pipelineSchemaVersion);
        // Metadata rows.
        final md = {
          for (final r in db.select('SELECT key, value FROM metadata;'))
            r['key'] as String: r['value'] as String,
        };
        expect(md['pipeline_git_sha'], 'fixture-sha');
        expect(md['generated_at'], '2026-07-06T10:00:00.000Z');
        expect(md['pbf_source'], 'tiny.osm.pbf');
        expect(md['pipeline_schema_version'], '$pipelineSchemaVersion');
        // Tables.
        final tables = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((r) => r['name'] as String)
            .toSet();
        expect(
          tables,
          containsAll([
            'ways',
            'admin_regions',
            'way_admin',
            'metadata',
            'ways_rtree_lookup',
          ]),
        );
        // Smoke counts.
        expect(
          db.select('SELECT COUNT(*) AS c FROM ways;').first['c'] as int,
          greaterThanOrEqualTo(1),
        );
        expect(
          db.select('SELECT COUNT(*) AS c FROM admin_regions;').first['c']
              as int,
          greaterThanOrEqualTo(1),
        );
        expect(
          db.select('SELECT COUNT(*) AS c FROM ways_rtree;').first['c'] as int,
          greaterThanOrEqualTo(1),
        );

        // One way is Kfz Musterstraße with 10 nodes → 9 segments → 9 rtree
        // rows for it (per-segment default).
        final kfz = db.select(
          "SELECT way_id, geometry_wkb FROM ways WHERE source='kfz';",
        ).first;
        final pts = decodeLineStringWkb(kfz['geometry_wkb'] as Uint8List);
        expect(pts.length, 10);
      } finally {
        db.dispose();
      }
    });

    test('preflight gate rejects when measurement file is a stub', () async {
      final stub = File('${tmpOut.path}/stub.md')
        ..writeAsStringSync('Not run yet: not empirically verified.');
      await expectLater(
        () => runPipeline(
          pbf: File(_tinyFixturePath),
          outDir: tmpOut,
          measurementFile: stub,
        ),
        throwsA(isA<PipelineError>()),
      );
    });

    test('--allow-unverified-measurement lets a stub through', () async {
      final stub = File('${tmpOut.path}/stub.md')
        ..writeAsStringSync('Not run: not empirically verified.');
      final result = await runPipeline(
        pbf: File(_tinyFixturePath),
        outDir: tmpOut,
        measurementFile: stub,
        allowUnverifiedMeasurement: true,
        gitShaResolver: () => 'unknown',
      );
      expect(File(result.osmSqlitePath).existsSync(), isTrue);
    });
  });
}
