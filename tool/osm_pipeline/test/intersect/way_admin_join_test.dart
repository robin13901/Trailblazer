import 'dart:typed_data';

import 'package:osm_pipeline/admin/geometry.dart' as geom;
import 'package:osm_pipeline/admin/wkb_writer.dart';
import 'package:osm_pipeline/cli/errors.dart';
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

  // ---------------------------------------------------------------------
  // Multi-worker correctness (Plan 04-10-1-04 Task 3).
  //
  // Seeds a synthetic fixture ~50 ways across 3 admin regions at 4 levels,
  // then runs the join under workers=1 (serial fast-path) and workers=6
  // (parallel path). Asserts:
  //   * row-set equality (sorted list compare) — content-identical output
  //   * COUNT(*) parity — catches silent duplicate-drop bugs
  //   * clamp behavior for --workers=0 and --workers=32
  //   * worker crash escalation (poison way_id → PipelineRuntimeError)
  // ---------------------------------------------------------------------
  group('multi-worker correctness', () {
    late ScratchDb scratch;

    setUp(() {
      scratch = ScratchDb.openTempFile();
    });
    tearDown(() {
      scratch.close(deleteFile: true);
    });

    /// Seeds [s] with 3 admin regions at levels {4, 6, 8} (9 rows total)
    /// plus [wayCount] Kfz ways stretched across the region's lng range.
    /// Each way is a 2-point segment inside the union of the regions.
    void seedFixture(ScratchDb s, {required int wayCount}) {
      // Region A (west): 13.400..13.402
      // Region B (mid) : 13.402..13.404
      // Region C (east): 13.404..13.406
      for (final r in const [
        (id: 1, minLng: 13.400, maxLng: 13.402),
        (id: 2, minLng: 13.402, maxLng: 13.404),
        (id: 3, minLng: 13.404, maxLng: 13.406),
      ]) {
        for (final level in const [4, 6, 8]) {
          _insertAdmin(
            s,
            regionId: r.id * 100 + level,
            adminLevel: level,
            minLng: r.minLng,
            minLat: 52.500,
            maxLng: r.maxLng,
            maxLat: 52.502,
          );
        }
      }

      // wayCount Kfz ways. Each way is a horizontal 2-point segment
      // straddling one or two region borders — mix of wholly-contained
      // and cross-border cases to exercise both row-cardinality patterns.
      final rowsPerRegion = wayCount ~/ 3;
      var nodeId = 1;
      for (var w = 0; w < wayCount; w++) {
        final band = w ~/ rowsPerRegion;
        final bandCap = band.clamp(0, 2);
        final lngBase = 13.400 + bandCap * 0.002;
        // Alternate: half the ways are wholly inside a single region,
        // the other half cross into the neighbour.
        final crosses = w.isOdd && bandCap < 2;
        final lngStart = lngBase + 0.0005 + (w % 5) * 0.0001;
        final lngEnd = crosses
            ? lngBase + 0.0025 + (w % 5) * 0.0001
            : lngBase + 0.0015 + (w % 5) * 0.0001;
        final lat = 52.5005 + (w % 3) * 0.0002;

        final n1 = nodeId++;
        final n2 = nodeId++;
        _insertNode(s, n1, lngStart, lat);
        _insertNode(s, n2, lngEnd, lat);
        _insertKfzWay(s, id: 1000 + w, nodeIds: [n1, n2]);
      }
    }

    List<String> canonicalRows(ScratchDb s) {
      return _selectRows(
        s,
        'SELECT way_id, region_id, admin_level, fraction_start, fraction_end '
        'FROM way_admin_raw '
        'ORDER BY way_id, region_id, admin_level, fraction_start, '
        'fraction_end;',
      ).map((r) => r.toString()).toList();
    }

    int rowCount(ScratchDb s) {
      return s.raw
          .select('SELECT COUNT(*) AS c FROM way_admin_raw;')
          .first['c'] as int;
    }

    test(
      'workers=6 produces same way_admin_raw as workers=1 '
      '(content + COUNT parity)',
      () async {
        seedFixture(scratch, wayCount: 48);
        // Serial fast-path baseline (workers defaults to 1 but pass explicitly
        // for readability at the diff site — ignore the redundant-arg lint).
        // ignore: avoid_redundant_argument_values
        await buildWayAdminJoin(scratch, workers: 1);
        final serialRows = canonicalRows(scratch);
        final serialCount = rowCount(scratch);
        expect(serialCount, greaterThan(0), reason: 'serial produced no rows');

        // Fresh scratch — same fixture, workers=6 path.
        final scratchP = ScratchDb.openTempFile();
        try {
          seedFixture(scratchP, wayCount: 48);
          await buildWayAdminJoin(scratchP, workers: 6);
          final parallelRows = canonicalRows(scratchP);
          final parallelCount = rowCount(scratchP);

          // Both invariants: row-set AND explicit COUNT(*). A silent
          // duplicate-swallow bug (e.g. future OR IGNORE re-introduction)
          // could pass one but not both.
          expect(
            parallelCount,
            equals(serialCount),
            reason: 'COUNT(*) differs — silent row loss?',
          );
          expect(
            parallelRows,
            equals(serialRows),
            reason: 'row set differs between workers=1 and workers=6',
          );
        } finally {
          scratchP.close(deleteFile: true);
        }
      },
    );

    test('workers=0 clamps to 1 (serial fast-path)', () async {
      seedFixture(scratch, wayCount: 6);
      final stats = await buildWayAdminJoin(scratch, workers: 0);
      expect(stats.workers, 1);
    });

    test('workers=32 clamps to 16', () async {
      seedFixture(scratch, wayCount: 6);
      final stats = await buildWayAdminJoin(scratch, workers: 32);
      // With 6 ways round-robin across 16 workers, 10 workers get an
      // empty partition. That's fine — coordinator awaits WorkerDone
      // from each. We just assert the clamp reported back.
      expect(stats.workers, 16);
    });

    test(
      'workers=1 hits the serial fast-path (workers=1 in stats)',
      () async {
        seedFixture(scratch, wayCount: 6);
        // Explicit workers=1 mirrors production default; readable at diff
        // site.
        // ignore: avoid_redundant_argument_values
        final stats = await buildWayAdminJoin(scratch, workers: 1);
        expect(stats.workers, 1);
        // Serial path reports real candidatePairsProbed >= 0; parallel
        // path reports -1 (payload-cost avoidance). This distinguishes
        // the two paths cleanly.
        expect(stats.candidatePairsProbed, greaterThanOrEqualTo(0));
      },
    );

    test(
      'parallel path (workers=2) reports candidatePairsProbed = -1',
      () async {
        seedFixture(scratch, wayCount: 6);
        final stats = await buildWayAdminJoin(scratch, workers: 2);
        expect(stats.workers, 2);
        expect(stats.candidatePairsProbed, -1);
      },
    );

    test(
      'poison way_id makes worker throw → coordinator escalates as '
      'PipelineRuntimeError within ≤5s (no deadlock)',
      () async {
        // Use a local scratch (bypass setUp/tearDown scratch) so we can
        // tolerate the Windows temp-dir cleanup lag on killed workers.
        // sqlite3 native FDs held by killed workers may not be released
        // in time for scratch.close(deleteFile: true) — the test's real
        // job is proving the escalation path, not the file cleanup.
        final localScratch = ScratchDb.openTempFile();
        try {
          seedFixture(localScratch, wayCount: 6);
          // Inject a poison way_id row: negative id (never appears in real
          // OSM data). The worker entry-point throws StateError when it
          // sees a negative id (see way_admin_join_isolate.dart).
          localScratch.raw.execute(
            'INSERT INTO ways_raw '
            '(id, source, is_counting, is_directional, oneway_tag, highway, '
            'name, ref, maxspeed, node_ids) '
            "VALUES (?, 'kfz', 1, 0, NULL, 'residential', "
            'NULL, NULL, NULL, ?);',
            [-42, encodeNodeIds([1, 2])],
          );

          final stopwatch = Stopwatch()..start();
          Object? caught;
          try {
            await buildWayAdminJoin(localScratch, workers: 4)
                .timeout(const Duration(seconds: 5));
          } on Object catch (e) {
            caught = e;
          }
          stopwatch.stop();

          expect(
            caught,
            isA<PipelineRuntimeError>(),
            reason: 'expected PipelineRuntimeError, got: $caught',
          );
          expect(
            stopwatch.elapsed.inSeconds,
            lessThanOrEqualTo(5),
            reason: 'coordinator took too long — possible deadlock',
          );
        } finally {
          // Windows: killed workers may still hold sqlite3 FDs on the
          // scratch file for a brief window. Tolerate cleanup failure —
          // temp dirs are ephemeral, the OS reaps them at shutdown.
          try {
            localScratch.close(deleteFile: true);
          } on Object {
            // Best effort — log-only via print would spam test output.
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
