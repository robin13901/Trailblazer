// Trailblazer 2026-08-13 (durable coverage-line cache):
// Round-trip tests for coverage_line_codec — encode(decode(x)) must reproduce
// the exact CoverageWay list (wayId, geometry, datum) so the durable blob is a
// lossless storage layer and the rendered line looks identical.

import 'package:auto_explore/features/coverage/data/coverage_line_codec.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

CoverageWay _way(
  int id,
  List<LatLng> geom, {
  double fraction = 1.0,
  bool isFull = true,
}) => CoverageWay(
  wayId: id,
  geometry: geom,
  datum: CoverageDatum(fraction: fraction, isFull: isFull),
);

void main() {
  group('coverage_line_codec', () {
    test('round-trips a single way losslessly', () {
      final ways = [
        _way(42, const [LatLng(49.1, 9.1), LatLng(49.2, 9.2), LatLng(49.3, 9.3)]),
      ];

      final decoded = decodeCoverageLine(encodeCoverageLine(ways));

      expect(decoded, hasLength(1));
      expect(decoded.first.wayId, 42);
      expect(decoded.first.geometry, hasLength(3));
      expect(decoded.first.geometry[0].latitude, closeTo(49.1, 1e-9));
      expect(decoded.first.geometry[0].longitude, closeTo(9.1, 1e-9));
      expect(decoded.first.geometry[2].latitude, closeTo(49.3, 1e-9));
      expect(decoded.first.datum.isFull, isTrue);
      expect(decoded.first.datum.fraction, closeTo(1.0, 1e-9));
    });

    test('round-trips multiple ways preserving order and data', () {
      final ways = [
        _way(1, const [LatLng(49.02, 9.03), LatLng(49.01, 9.04)], fraction: 0.5, isFull: false),
        _way(2, const [LatLng(50.02, 10.03), LatLng(50.01, 10.04)]),
      ];

      final decoded = decodeCoverageLine(encodeCoverageLine(ways));

      expect(decoded, hasLength(2));
      expect(decoded[0].wayId, 1);
      expect(decoded[0].datum.isFull, isFalse);
      expect(decoded[0].datum.fraction, closeTo(0.5, 1e-9));
      expect(decoded[1].wayId, 2);
      expect(decoded[1].datum.isFull, isTrue);
    });

    test('preserves coordinate precision (bit-for-bit line)', () {
      const lat = 49.123456789;
      const lon = 9.987654321;
      // Compare against the actual LatLng values (its constructor may store a
      // nearest-double representation) — the codec itself must round-trip
      // whatever LatLng holds without loss.
      final original = _way(9, const [
        LatLng(lat, lon),
        LatLng(lat + 0.001, lon + 0.001),
      ]);
      final ways = [original];

      final decoded = decodeCoverageLine(encodeCoverageLine(ways));

      expect(
        decoded.first.geometry[0].latitude,
        original.geometry[0].latitude,
      );
      expect(
        decoded.first.geometry[0].longitude,
        original.geometry[0].longitude,
      );
    });

    test('empty list round-trips to empty', () {
      expect(decodeCoverageLine(encodeCoverageLine(const [])), isEmpty);
    });

    test('null / empty / malformed input decodes to empty (never throws)', () {
      expect(decodeCoverageLine(null), isEmpty);
      expect(decodeCoverageLine(''), isEmpty);
      expect(decodeCoverageLine('not json'), isEmpty);
      expect(decodeCoverageLine('[]'), isEmpty); // list, not the {v,ways} map
      expect(decodeCoverageLine('{"v":1}'), isEmpty); // no ways key
      expect(decodeCoverageLine('{"v":1,"ways":"nope"}'), isEmpty);
    });

    test('drops degenerate (< 2 point) ways on encode', () {
      final ways = [
        _way(1, const [LatLng(49.02, 9.03)]), // 1 point — degenerate
        _way(2, const [LatLng(50.02, 10.03), LatLng(50.01, 10.04)]),
      ];

      final decoded = decodeCoverageLine(encodeCoverageLine(ways));

      expect(decoded, hasLength(1));
      expect(decoded.first.wayId, 2);
    });
  });
}
