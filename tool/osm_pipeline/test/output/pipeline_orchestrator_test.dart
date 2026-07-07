import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/output/osm_sqlite_writer.dart';
import 'package:osm_pipeline/output/pipeline_orchestrator.dart';
import 'package:osm_pipeline/output/rtree_builder.dart';
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
        // v2 (2026-07-07 · Plan 04-10-1-02): osm.sqlite is Kfz-only. The
        // tiny fixture has 1 Kfz + 1 Feldweg way — the output must have
        // exactly 1 way row, all source='kfz'.
        expect(
          db.select('SELECT COUNT(*) AS c FROM ways;').first['c'] as int,
          1,
        );
        final sources = db
            .select('SELECT DISTINCT source FROM ways;')
            .map((r) => r['source'] as String)
            .toSet();
        expect(sources, {'kfz'});
        expect(
          db.select('SELECT COUNT(*) AS c FROM admin_regions;').first['c']
              as int,
          greaterThanOrEqualTo(1),
        );
        expect(
          db.select('SELECT COUNT(*) AS c FROM ways_rtree;').first['c'] as int,
          greaterThanOrEqualTo(1),
        );

        // Plan 04-10-1-03: default granularity is perWay → exactly 1 rtree
        // row per way. The tiny fixture yields 1 Kfz way after the
        // Feldweg-drop; ways_rtree row count must equal ways row count.
        final wayCount = db
            .select('SELECT COUNT(*) AS c FROM ways;')
            .first['c'] as int;
        final rtreeCount = db
            .select('SELECT COUNT(*) AS c FROM ways_rtree;')
            .first['c'] as int;
        expect(rtreeCount, wayCount);
        final segIdxRows = db
            .select('SELECT DISTINCT segment_idx FROM ways_rtree_lookup;')
            .map((r) => r['segment_idx'] as int)
            .toSet();
        expect(segIdxRows, {-1});

        // One way is Kfz Musterstraße with 10 nodes → 9 segments. Under the
        // perWay default we get 1 rtree row (asserted above); the geometry
        // still round-trips to 10 points.
        final kfz = db.select(
          "SELECT way_id, geometry_wkb FROM ways WHERE source='kfz';",
        ).first;
        final pts = decodeLineStringWkb(kfz['geometry_wkb'] as Uint8List);
        expect(pts.length, 10);
      } finally {
        db.dispose();
      }
    });

    test(
      'granularityOverride: perSegment produces > 1 rtree row per '
      'multi-segment way',
      () async {
        final result = await runPipeline(
          pbf: File(_tinyFixturePath),
          outDir: tmpOut,
          measurementFile: goodMeasurement,
          granularityOverride: RtreeGranularity.perSegment,
          gitShaResolver: () => 'fixture-sha',
          nowUtc: DateTime.utc(2026, 7, 6, 10),
        );
        final db = sqlite3.open(result.osmSqlitePath);
        try {
          final wayCount = db
              .select('SELECT COUNT(*) AS c FROM ways;')
              .first['c'] as int;
          final rtreeCount = db
              .select('SELECT COUNT(*) AS c FROM ways_rtree;')
              .first['c'] as int;
          // Tiny fixture Kfz way has 10 nodes → 9 segments per way.
          expect(rtreeCount, greaterThan(wayCount));
          final segs = db
              .select('SELECT DISTINCT segment_idx FROM ways_rtree_lookup;')
              .map((r) => r['segment_idx'] as int)
              .toSet();
          // Per-segment uses non-negative segment indices.
          expect(segs.every((s) => s >= 0), isTrue);
        } finally {
          db.dispose();
        }
      },
    );

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
