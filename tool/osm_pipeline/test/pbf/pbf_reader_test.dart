import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:osm_pipeline/pbf/pbf_reader.dart';
import 'package:test/test.dart';

import '../fixtures/build_tiny_pbf.dart';

void main() {
  final fixture = File('test/fixtures/tiny.osm.pbf');

  group('PbfReader on tiny fixture', () {
    setUpAll(() {
      // Sanity: the committed fixture must exist and be small.
      expect(
        fixture.existsSync(),
        isTrue,
        reason: 'run `dart run test/fixtures/build_tiny_pbf.dart` first',
      );
      expect(fixture.lengthSync(), lessThan(10 * 1024));
    });

    test('reads tiny fixture: 24 nodes, 4 ways, 1 relation', () async {
      final reader = PbfReader();
      var nodes = 0;
      var ways = 0;
      var relations = 0;
      await for (final e in reader.stream(fixture)) {
        if (e is OsmNode) {
          nodes++;
        } else if (e is OsmWay) {
          ways++;
        } else if (e is OsmRelation) {
          relations++;
        }
      }
      expect(nodes, 24);
      expect(ways, 4);
      expect(relations, 1);
    });

    test('way 1 has tag highway=primary and 10 node refs', () async {
      final reader = PbfReader();
      OsmWay? way1;
      await for (final e in reader.stream(fixture)) {
        if (e is OsmWay && e.id == 1) {
          way1 = e;
          break;
        }
      }
      expect(way1, isNotNull);
      expect(way1!.tags['highway'], 'primary');
      expect(way1.tags['name'], 'Musterstraße');
      expect(way1.tags['ref'], 'M1');
      expect(way1.nodeRefs.length, 10);
      expect(way1.nodeRefs.first, 1);
      expect(way1.nodeRefs.last, 10);
    });

    test('relation 1 has 2 members with roles outer, inner', () async {
      final reader = PbfReader();
      OsmRelation? rel;
      await for (final e in reader.stream(fixture)) {
        if (e is OsmRelation) {
          rel = e;
          break;
        }
      }
      expect(rel, isNotNull);
      expect(rel!.tags['type'], 'multipolygon');
      expect(rel.tags['admin_level'], '8');
      expect(rel.tags['name'], 'Testgemeinde');
      expect(rel.members.length, 2);
      expect(rel.members[0].refId, 3);
      expect(rel.members[0].type, OsmMemberType.way);
      expect(rel.members[0].role, 'outer');
      expect(rel.members[1].refId, 4);
      expect(rel.members[1].type, OsmMemberType.way);
      expect(rel.members[1].role, 'inner');
    });

    test('OSMHeader is parsed and reader.header is non-null after first entity',
        () async {
      final reader = PbfReader();
      final stream = reader.stream(fixture);
      // Pull exactly one entity; header must be set by then because it lives
      // in the first blob (OSMHeader) which is decoded before any OSMData.
      await stream.first;
      expect(reader.header, isNotNull);
      expect(reader.header!.requiredFeatures, contains('OsmSchema-V0.6'));
      expect(reader.header!.requiredFeatures, contains('DenseNodes'));
    });

    test('a node has plausible lat/lng in the fixture region', () async {
      final reader = PbfReader();
      OsmNode? firstNode;
      await for (final e in reader.stream(fixture)) {
        if (e is OsmNode) {
          firstNode = e;
          break;
        }
      }
      expect(firstNode, isNotNull);
      // Fixture nodes cluster around (52.5, 13.4).
      expect(firstNode!.lat, closeTo(52.5, 0.1));
      expect(firstNode.lng, closeTo(13.4, 0.1));
    });

    test('malformed truncated PBF throws PipelineParseError with sourceOffset',
        () async {
      final good = await fixture.readAsBytes();
      // Truncate mid-second blob: keep the first blob intact, chop the tail.
      // Cut at 3/4 of file length — well past the OSMHeader but inside OSMData.
      final truncated = Uint8List.sublistView(good, 0, (good.length * 3) ~/ 4);
      final tmp = File(
        '${Directory.systemTemp.createTempSync('osm_pbf_trunc').path}'
        '/truncated.osm.pbf',
      )..writeAsBytesSync(truncated);
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
        if (tmp.parent.existsSync()) tmp.parent.deleteSync(recursive: true);
      });

      final reader = PbfReader();
      Object? caught;
      try {
        await reader.stream(tmp).drain<void>();
      } on PipelineParseError catch (e) {
        caught = e;
      }
      expect(caught, isA<PipelineParseError>());
      expect((caught! as PipelineParseError).sourceOffset, isNotNull);
    });

    test('streaming: consuming 5 entities then breaking closes the file',
        () async {
      final reader = PbfReader();
      var count = 0;
      await for (final _ in reader.stream(fixture)) {
        count++;
        if (count >= 5) break;
      }
      expect(count, 5);
      // If the file were still open, deleting/replacing it would fail on
      // Windows. Regenerate over the same path — proves no dangling handle.
      final regenerated = buildTinyPbfBytes();
      fixture.writeAsBytesSync(regenerated);
      expect(fixture.existsSync(), isTrue);
    });
  });

  group('Fixture generator', () {
    test('regeneration is deterministic (byte-identical across two runs)',
        () async {
      final first = buildTinyPbfBytes();
      final second = buildTinyPbfBytes();
      expect(first, orderedEquals(second));
    });

    test('committed fixture bytes match a fresh regeneration', () async {
      final onDisk = fixture.readAsBytesSync();
      final rebuilt = buildTinyPbfBytes();
      expect(
        onDisk,
        orderedEquals(rebuilt),
        reason: 'run `dart run test/fixtures/build_tiny_pbf.dart` to '
            'refresh the committed fixture',
      );
    });
  });
}
