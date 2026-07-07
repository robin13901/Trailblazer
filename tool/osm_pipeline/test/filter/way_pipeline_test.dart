import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/filter/way_pipeline.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Direct INSERT helper — bypasses the batched prepared statements so tests
/// can seed a minimal (id, node_ids) row without wiring the full column set.
void _seedWay(ScratchDb scratch, int wayId, List<int> nodeIds) {
  scratch.raw.execute(
    'INSERT INTO ways_raw '
    '(id, source, is_counting, is_directional, highway, node_ids) '
    "VALUES (?, 'kfz', 1, 0, 'primary', ?);",
    <Object?>[wayId, encodeNodeIds(nodeIds)],
  );
}

void _seedNode(ScratchDb scratch, int nodeId) {
  scratch.raw.execute(
    'INSERT INTO nodes_raw (id, lat, lng) VALUES (?, 0.0, 0.0);',
    <Object?>[nodeId],
  );
}

void main() {
  group('WayPipeline on tiny fixture', () {
    final fixture = File('test/fixtures/tiny.osm.pbf');
    late ScratchDb scratch;

    setUp(() {
      scratch = ScratchDb.openTempFile();
    });

    tearDown(() {
      scratch.close(deleteFile: true);
    });

    test('accepts 1 Kfz way + 1 Feldweg way + their nodes', () async {
      final stats = await const WayPipeline().run(
        pbf: fixture,
        scratch: scratch,
      );
      // Tiny fixture: way 1 = highway=primary (Kfz), way 2 = highway=track
      // (Feldweg), ways 3+4 = boundary=administrative (no highway → rejected).
      expect(stats.kfzWays, 1);
      expect(stats.feldwegWays, 1);
      // Kfz way 1 has 10 node refs (1..10), Feldweg way 2 has 4 refs (11..14).
      expect(stats.nodes, 14);
      expect(stats.rejected, 2, reason: 'ways 3 + 4 have no highway tag');
      expect(stats.highwayRoad, 0);
      expect(stats.deletedNodeRefs, 0);
      expect(stats.skippedLog.existsSync(), isTrue);
      final logText = stats.skippedLog.readAsStringSync();
      expect(logText, contains('no_highway_tag'));
    });

    test('Kfz way 1 is directional=0 (primary + no oneway) with 10 nodes',
        () async {
      await const WayPipeline().run(pbf: fixture, scratch: scratch);
      final row = scratch.raw
          .select("SELECT * FROM ways_raw WHERE source = 'kfz';")
          .first;
      expect(row['id'], 1);
      expect(row['highway'], 'primary');
      expect(row['is_directional'], 0);
      expect(row['name'], 'Musterstraße');
      expect(row['ref'], 'M1');
    });

    test('Feldweg way 2 is track with no directionality', () async {
      await const WayPipeline().run(pbf: fixture, scratch: scratch);
      final row = scratch.raw
          .select("SELECT * FROM ways_raw WHERE source = 'feldweg';")
          .first;
      expect(row['id'], 2);
      expect(row['highway'], 'track');
      expect(row['is_directional'], 0);
      expect(row['is_counting'], 0);
    });

    test('rejected admin ways (3+4) are logged to skipped.log', () async {
      final stats = await const WayPipeline().run(
        pbf: fixture,
        scratch: scratch,
      );
      final lines = stats.skippedLog
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(line, startsWith('no_highway_tag\t'));
      }
    });
  });

  group('runWayIntegrityCheck (JOIN rewrite)', () {
    late ScratchDb scratch;

    setUp(() {
      scratch = ScratchDb.openTempFile();
    });

    tearDown(() {
      scratch.close(deleteFile: true);
    });

    test('drops ways with any missing node reference', () {
      // Seed 3 ways.
      // way 100: nodes 1, 2, 3 — all present → kept
      // way 200: nodes 1, 99 — 99 missing → dropped
      // way 300: nodes 4, 5, 6 — all present → kept
      _seedNode(scratch, 1);
      _seedNode(scratch, 2);
      _seedNode(scratch, 3);
      _seedNode(scratch, 4);
      _seedNode(scratch, 5);
      _seedNode(scratch, 6);
      _seedWay(scratch, 100, <int>[1, 2, 3]);
      _seedWay(scratch, 200, <int>[1, 99]);
      _seedWay(scratch, 300, <int>[4, 5, 6]);

      final dropped = <int>[];
      final result = runWayIntegrityCheck(
        scratch: scratch,
        onDrop: dropped.add,
      );

      expect(result, <int>[200]);
      expect(dropped, <int>[200]);

      // ways_raw is post-DELETE.
      final rows = scratch.raw.select('SELECT id FROM ways_raw ORDER BY id;');
      expect(rows.map((r) => r['id'] as int), <int>[100, 300]);

      // filter_stats.deleted_node_ref bumped once per dropped way.
      expect(scratch.readStat('deleted_node_ref'), 1);
    });

    test('drops each way at most once when many nodes are missing', () {
      // way 100 references 4 nodes, ALL missing. DISTINCT in the JOIN
      // must collapse to a single dropped-row output.
      _seedWay(scratch, 100, <int>[10, 11, 12, 13]);

      final dropped = <int>[];
      final result = runWayIntegrityCheck(
        scratch: scratch,
        onDrop: dropped.add,
      );

      expect(result, <int>[100]);
      expect(dropped, <int>[100], reason: 'onDrop must fire exactly once');
      expect(scratch.readStat('deleted_node_ref'), 1);
    });

    test('no ways dropped when every node reference resolves', () {
      _seedNode(scratch, 1);
      _seedNode(scratch, 2);
      _seedWay(scratch, 100, <int>[1, 2]);
      _seedWay(scratch, 101, <int>[1, 2]);

      final dropped = <int>[];
      final result = runWayIntegrityCheck(
        scratch: scratch,
        onDrop: dropped.add,
      );

      expect(result, isEmpty);
      expect(dropped, isEmpty);
      expect(scratch.countRows('ways_raw'), 2);
      expect(scratch.readStat('deleted_node_ref'), 0);
    });

    test('temp table way_node_refs is cleaned up after the check', () {
      _seedNode(scratch, 1);
      _seedWay(scratch, 100, <int>[1]);

      runWayIntegrityCheck(scratch: scratch, onDrop: (_) {});

      // TEMP tables land in the `temp` schema — a follow-up run of the
      // check must not fail with "table already exists". Prove it by
      // running twice.
      _seedNode(scratch, 2);
      _seedWay(scratch, 200, <int>[2]);
      expect(
        () => runWayIntegrityCheck(scratch: scratch, onDrop: (_) {}),
        returnsNormally,
      );
    });

    test('empty ways_raw is a no-op (does not throw)', () {
      final dropped = <int>[];
      final result = runWayIntegrityCheck(
        scratch: scratch,
        onDrop: dropped.add,
      );
      expect(result, isEmpty);
      expect(dropped, isEmpty);
    });
  });
}

// Suppress the "unused import" warning without a comment: sqlite3 types are
// referenced transitively via `scratch.raw`, but a direct import keeps the
// test's call-sites analyser-friendly if we ever inline sqlite3 assertions.
// ignore: unused_element
Database _touchSqlite3(ScratchDb s) => s.raw;

// Silence the unused_import lint on Uint8List (encodeNodeIds returns one).
// ignore: unused_element
Uint8List _touchTypedData() => Uint8List(0);
