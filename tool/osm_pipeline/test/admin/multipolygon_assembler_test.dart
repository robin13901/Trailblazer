import 'dart:convert';
import 'dart:io';

import 'package:osm_pipeline/admin/geometry.dart';
import 'package:osm_pipeline/admin/multipolygon_assembler.dart';
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:test/test.dart';

// A minimal in-memory skipped-log sink that captures written lines.
class _CapturingSink implements IOSink {
  final List<String> lines = [];
  final _controller = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void writeln([Object? obj = '']) {
    lines.add(obj.toString());
  }

  // Unused parts of IOSink — no-op stubs.
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> flush() async {}
  @override
  Future<void> get done => Future.value();
  @override
  void write(Object? obj) {
    _controller.write(obj);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
}

OsmWay _way(int id, List<int> nodeRefs) =>
    OsmWay(id: id, tags: const {}, nodeRefs: nodeRefs);

NullableNodeLookup _lookup(Map<int, ({double lat, double lng})> nodes) {
  return (int nodeId) => nodes[nodeId];
}

OsmRelation _mpRelation(
  int id,
  List<({int wayId, String role})> members,
) =>
    OsmRelation(
      id: id,
      tags: const {
        'type': 'boundary',
        'boundary': 'administrative',
        'admin_level': '8',
      },
      members: [
        for (final m in members)
          RelationMember(
            refId: m.wayId,
            type: OsmMemberType.way,
            role: m.role,
          ),
      ],
    );

void main() {
  group('MultipolygonAssembler', () {
    test('single closed way as outer ring → 1-polygon MultiPolygon', () {
      final rel = _mpRelation(1, [(wayId: 1, role: 'outer')]);
      final waysById = {
        1: _way(1, const [10, 11, 12, 13, 10]),
      };
      final nodes = {
        10: (lat: 0.0, lng: 0.0),
        11: (lat: 0.0, lng: 1.0),
        12: (lat: 1.0, lng: 1.0),
        13: (lat: 1.0, lng: 0.0),
      };
      final sink = _CapturingSink();
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        _lookup(nodes),
        sink,
      );
      expect(mp, isNotNull);
      expect(mp!.polygons.length, 1);
      expect(mp.polygons[0].holes, isEmpty);
      // CCW-oriented (positive signed area) after correction.
      expect(isCounterClockwise(mp.polygons[0].outer), isTrue);
      expect(sink.lines, isEmpty);
    });

    test('two open fragments sharing endpoints → stitched into 1 closed ring',
        () {
      final rel = _mpRelation(2, [
        (wayId: 1, role: 'outer'),
        (wayId: 2, role: 'outer'),
      ]);
      final waysById = {
        1: _way(1, const [10, 11, 12]),
        2: _way(2, const [12, 13, 10]),
      };
      final nodes = {
        10: (lat: 0.0, lng: 0.0),
        11: (lat: 0.0, lng: 1.0),
        12: (lat: 1.0, lng: 1.0),
        13: (lat: 1.0, lng: 0.0),
      };
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        _lookup(nodes),
        null,
      );
      expect(mp, isNotNull);
      expect(mp!.polygons.length, 1);
      final outer = mp.polygons[0].outer;
      expect(outer.first.equalsCoord(outer.last), isTrue,
          reason: 'ring must close',);
      expect(outer.length, 5); // 4 unique + closing repeat
    });

    test('outer + one inner enclave → MultiPolygon with hole', () {
      final rel = _mpRelation(3, [
        (wayId: 1, role: 'outer'),
        (wayId: 2, role: 'inner'),
      ]);
      final waysById = {
        // Big square outer
        1: _way(1, const [10, 11, 12, 13, 10]),
        // Small square inner (enclave inside big square)
        2: _way(2, const [20, 21, 22, 23, 20]),
      };
      final nodes = {
        10: (lat: 0.0, lng: 0.0),
        11: (lat: 0.0, lng: 10.0),
        12: (lat: 10.0, lng: 10.0),
        13: (lat: 10.0, lng: 0.0),
        20: (lat: 3.0, lng: 3.0),
        21: (lat: 3.0, lng: 6.0),
        22: (lat: 6.0, lng: 6.0),
        23: (lat: 6.0, lng: 3.0),
      };
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        _lookup(nodes),
        null,
      );
      expect(mp, isNotNull);
      expect(mp!.polygons.length, 1);
      expect(mp.polygons[0].holes.length, 1);
      // Outer CCW, inner CW.
      expect(isCounterClockwise(mp.polygons[0].outer), isTrue);
      expect(isCounterClockwise(mp.polygons[0].holes[0]), isFalse);
    });

    test('missing member way → logs to skippedLog, does not throw', () {
      final rel = _mpRelation(4, [
        (wayId: 1, role: 'outer'),
        (wayId: 999, role: 'outer'), // does not exist
      ]);
      final waysById = {
        1: _way(1, const [10, 11, 12, 13, 10]),
      };
      final nodes = {
        10: (lat: 0.0, lng: 0.0),
        11: (lat: 0.0, lng: 1.0),
        12: (lat: 1.0, lng: 1.0),
        13: (lat: 1.0, lng: 0.0),
      };
      final sink = _CapturingSink();
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        _lookup(nodes),
        sink,
      );
      expect(mp, isNotNull);
      expect(mp!.polygons.length, 1);
      expect(sink.lines, isNotEmpty);
      expect(
        sink.lines.first,
        contains('missing member way 999'),
      );
    });

    test('self-intersecting outer ring → logged as pitfall #5, skipped', () {
      // Bowtie ring: (0,0) → (1,1) → (1,0) → (0,1) → (0,0)
      final rel = _mpRelation(5, [(wayId: 1, role: 'outer')]);
      final waysById = {
        1: _way(1, const [10, 11, 12, 13, 10]),
      };
      final nodes = {
        10: (lat: 0.0, lng: 0.0),
        11: (lat: 1.0, lng: 1.0),
        12: (lat: 0.0, lng: 1.0),
        13: (lat: 1.0, lng: 0.0),
      };
      final sink = _CapturingSink();
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        _lookup(nodes),
        sink,
      );
      expect(mp, isNull, reason: 'no valid outer rings remain');
      expect(
        sink.lines.any((l) => l.contains('self-intersecting outer ring')),
        isTrue,
      );
    });

    test('outer given as CW → reversed to CCW in output', () {
      // Explicitly CW ring: (0,0) → (1,0) → (1,1) → (0,1) → (0,0)
      final rel = _mpRelation(6, [(wayId: 1, role: 'outer')]);
      final waysById = {
        1: _way(1, const [10, 13, 12, 11, 10]),
      };
      final nodes = {
        10: (lat: 0.0, lng: 0.0),
        11: (lat: 0.0, lng: 1.0),
        12: (lat: 1.0, lng: 1.0),
        13: (lat: 1.0, lng: 0.0),
      };
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        _lookup(nodes),
        null,
      );
      expect(mp, isNotNull);
      expect(isCounterClockwise(mp!.polygons[0].outer), isTrue);
    });

    test('inner not inside any outer → logged and dropped', () {
      final rel = _mpRelation(7, [
        (wayId: 1, role: 'outer'),
        (wayId: 2, role: 'inner'),
      ]);
      final waysById = {
        1: _way(1, const [10, 11, 12, 13, 10]),
        // Inner far outside the outer's extent
        2: _way(2, const [30, 31, 32, 33, 30]),
      };
      final nodes = {
        10: (lat: 0.0, lng: 0.0),
        11: (lat: 0.0, lng: 1.0),
        12: (lat: 1.0, lng: 1.0),
        13: (lat: 1.0, lng: 0.0),
        30: (lat: 100.0, lng: 100.0),
        31: (lat: 100.0, lng: 101.0),
        32: (lat: 101.0, lng: 101.0),
        33: (lat: 101.0, lng: 100.0),
      };
      final sink = _CapturingSink();
      final mp = MultipolygonAssembler.assemble(
        rel,
        waysById,
        _lookup(nodes),
        sink,
      );
      expect(mp, isNotNull);
      expect(mp!.polygons[0].holes, isEmpty);
      expect(
        sink.lines.any(
          (l) => l.contains('inner ring lies outside every outer'),
        ),
        isTrue,
      );
    });
  });

  group('geometry helpers', () {
    test('signedRingArea distinguishes CCW vs CW', () {
      final ccw = [
        const Point(0, 0),
        const Point(1, 0),
        const Point(1, 1),
        const Point(0, 1),
        const Point(0, 0),
      ];
      expect(signedRingArea(ccw), greaterThan(0));
      expect(isCounterClockwise(ccw), isTrue);
      final cw = ccw.reversed.toList();
      expect(signedRingArea(cw), lessThan(0));
      expect(isCounterClockwise(cw), isFalse);
    });

    test('pointInRing on a unit square', () {
      final square = [
        const Point(0, 0),
        const Point(1, 0),
        const Point(1, 1),
        const Point(0, 1),
        const Point(0, 0),
      ];
      expect(pointInRing(const Point(0.5, 0.5), square), isTrue);
      expect(pointInRing(const Point(2, 2), square), isFalse);
    });

    test('MultiPolygon.bbox spans all rings', () {
      const mp = MultiPolygon([
        Polygon(
          outer: [
            Point(0, 0),
            Point(2, 0),
            Point(2, 2),
            Point(0, 2),
            Point(0, 0),
          ],
        ),
        Polygon(
          outer: [
            Point(5, 5),
            Point(7, 5),
            Point(7, 7),
            Point(5, 7),
            Point(5, 5),
          ],
        ),
      ]);
      final b = mp.bbox();
      expect(b.minLat, 0);
      expect(b.maxLat, 7);
      expect(b.minLng, 0);
      expect(b.maxLng, 7);
    });
  });
}
