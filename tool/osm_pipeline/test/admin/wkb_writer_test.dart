import 'dart:typed_data';

import 'package:osm_pipeline/admin/geometry.dart';
import 'package:osm_pipeline/admin/wkb_writer.dart';
import 'package:test/test.dart';

// Minimal reference WKB decoder for MultiPolygon — used only in tests.
class _WkbDecoder {
  _WkbDecoder(this.bytes) : view = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData view;
  int offset = 0;

  int readByte() {
    final v = view.getUint8(offset);
    offset += 1;
    return v;
  }

  int readUint32() {
    final v = view.getUint32(offset, Endian.little);
    offset += 4;
    return v;
  }

  double readFloat64() {
    final v = view.getFloat64(offset, Endian.little);
    offset += 8;
    return v;
  }

  MultiPolygon decodeMultiPolygon() {
    expect(readByte(), 1, reason: 'byte-order flag = NDR');
    expect(readUint32(), 6, reason: 'type = MultiPolygon');
    final polyCount = readUint32();
    final polys = <Polygon>[];
    for (var i = 0; i < polyCount; i++) {
      expect(readByte(), 1);
      expect(readUint32(), 3, reason: 'type = Polygon');
      final ringCount = readUint32();
      List<Point> readRing() {
        final n = readUint32();
        final points = <Point>[];
        for (var k = 0; k < n; k++) {
          final lng = readFloat64();
          final lat = readFloat64();
          points.add(Point(lng, lat));
        }
        return points;
      }

      final outer = readRing();
      final holes = <List<Point>>[
        for (var r = 1; r < ringCount; r++) readRing(),
      ];
      polys.add(Polygon(outer: outer, holes: holes));
    }
    return MultiPolygon(polys);
  }
}

void main() {
  group('encodeMultiPolygon', () {
    test('unit square: byte-exact expected output', () {
      const mp = MultiPolygon([
        Polygon(
          outer: [
            Point(0, 0),
            Point(1, 0),
            Point(1, 1),
            Point(0, 1),
            Point(0, 0),
          ],
        ),
      ]);
      final wkb = encodeMultiPolygon(mp);

      // Hand-computed expected length:
      // 1 (order) + 4 (type) + 4 (polygon count) = 9
      // + 1 + 4 + 4 (polygon header) = 9
      // + 4 (ring count) + 5 * 16 (five points × 2 float64) = 4 + 80 = 84
      // Total: 9 + 9 + 84 = 102
      expect(wkb.length, 102);

      // Decode with the reference decoder to prove structural correctness.
      final round = _WkbDecoder(wkb).decodeMultiPolygon();
      expect(round.polygons.length, 1);
      expect(round.polygons[0].outer.length, 5);
      expect(round.polygons[0].holes, isEmpty);
      expect(round.polygons[0].outer[0].lng, 0);
      expect(round.polygons[0].outer[0].lat, 0);
      expect(round.polygons[0].outer[2].lng, 1);
      expect(round.polygons[0].outer[2].lat, 1);
    });

    test('MultiPolygon with two disjoint polygons has num_polygons=2', () {
      const mp = MultiPolygon([
        Polygon(
          outer: [
            Point(0, 0),
            Point(1, 0),
            Point(1, 1),
            Point(0, 1),
            Point(0, 0),
          ],
        ),
        Polygon(
          outer: [
            Point(10, 10),
            Point(11, 10),
            Point(11, 11),
            Point(10, 11),
            Point(10, 10),
          ],
        ),
      ]);
      final wkb = encodeMultiPolygon(mp);
      final view = ByteData.sublistView(wkb);
      // Bytes 5..8 hold the polygon count.
      expect(view.getUint32(5, Endian.little), 2);
      final round = _WkbDecoder(wkb).decodeMultiPolygon();
      expect(round.polygons.length, 2);
    });

    test('polygon with a hole: ring count = 2', () {
      const mp = MultiPolygon([
        Polygon(
          outer: [
            Point(0, 0),
            Point(10, 0),
            Point(10, 10),
            Point(0, 10),
            Point(0, 0),
          ],
          holes: [
            [
              Point(3, 3),
              Point(3, 6),
              Point(6, 6),
              Point(6, 3),
              Point(3, 3),
            ],
          ],
        ),
      ]);
      final wkb = encodeMultiPolygon(mp);
      final round = _WkbDecoder(wkb).decodeMultiPolygon();
      expect(round.polygons.length, 1);
      expect(round.polygons[0].holes.length, 1);
      expect(round.polygons[0].holes[0].length, 5);
    });

    test('deterministic: identical input → byte-identical output', () {
      const mp1 = MultiPolygon([
        Polygon(
          outer: [
            Point(1.1, 2.2),
            Point(3.3, 2.2),
            Point(3.3, 4.4),
            Point(1.1, 4.4),
            Point(1.1, 2.2),
          ],
        ),
      ]);
      const mp2 = MultiPolygon([
        Polygon(
          outer: [
            Point(1.1, 2.2),
            Point(3.3, 2.2),
            Point(3.3, 4.4),
            Point(1.1, 4.4),
            Point(1.1, 2.2),
          ],
        ),
      ]);
      expect(encodeMultiPolygon(mp1), orderedEquals(encodeMultiPolygon(mp2)));
    });

    test('round-trip: encode → decode preserves geometry', () {
      const mp = MultiPolygon([
        Polygon(
          outer: [
            Point(13.4, 52.5),
            Point(13.5, 52.5),
            Point(13.5, 52.6),
            Point(13.4, 52.6),
            Point(13.4, 52.5),
          ],
        ),
      ]);
      final wkb = encodeMultiPolygon(mp);
      final round = _WkbDecoder(wkb).decodeMultiPolygon();
      expect(round.polygons.length, mp.polygons.length);
      for (var i = 0; i < mp.polygons.length; i++) {
        final a = round.polygons[i].outer;
        final b = mp.polygons[i].outer;
        expect(a.length, b.length);
        for (var k = 0; k < a.length; k++) {
          expect(a[k].lng, b[k].lng);
          expect(a[k].lat, b[k].lat);
        }
      }
    });
  });
}
