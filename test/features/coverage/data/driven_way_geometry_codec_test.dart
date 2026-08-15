// Codec round-trip tests for driven_way_geometry_codec.

import 'package:auto_explore/features/coverage/data/driven_way_geometry_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

void main() {
  group('encodeWayGeometry / decodeWayGeometry', () {
    test('round-trips a polyline losslessly', () {
      const geom = [
        LatLng(49.123, 9.456),
        LatLng(49.124, 9.457),
        LatLng(49.125, 9.458),
      ];
      final decoded = decodeWayGeometry(encodeWayGeometry(geom));
      expect(decoded, hasLength(3));
      expect(decoded[0].latitude, geom[0].latitude);
      expect(decoded[0].longitude, geom[0].longitude);
      expect(decoded[2].latitude, geom[2].latitude);
    });

    test('empty list round-trips to empty', () {
      expect(decodeWayGeometry(encodeWayGeometry(const [])), isEmpty);
    });

    test('null/malformed input → empty (never throws)', () {
      expect(decodeWayGeometry(null), isEmpty);
      expect(decodeWayGeometry(''), isEmpty);
      expect(decodeWayGeometry('not json'), isEmpty);
      expect(decodeWayGeometry('{}'), isEmpty);
    });
  });

  group('encodeNodeIds / decodeNodeIds', () {
    test('round-trips a node id list losslessly', () {
      const ids = [123456789, 987654321, 111222333];
      expect(decodeNodeIds(encodeNodeIds(ids)), ids);
    });

    test('empty list round-trips to empty', () {
      expect(decodeNodeIds(encodeNodeIds(const [])), isEmpty);
    });

    test('null/malformed input → empty (never throws)', () {
      expect(decodeNodeIds(null), isEmpty);
      expect(decodeNodeIds(''), isEmpty);
      expect(decodeNodeIds('not json'), isEmpty);
      expect(decodeNodeIds('{}'), isEmpty);
    });
  });
}
