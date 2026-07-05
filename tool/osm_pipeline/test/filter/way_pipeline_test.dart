import 'dart:io';

import 'package:osm_pipeline/filter/way_pipeline.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:test/test.dart';

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
}
