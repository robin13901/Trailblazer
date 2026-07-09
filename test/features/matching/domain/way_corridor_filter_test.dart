import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_corridor_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

GpsFix _fix(double lat, double lon) => GpsFix(
      lat: lat,
      lon: lon,
      accuracyMeters: 5,
      speedKmh: 50,
      ts: DateTime.fromMillisecondsSinceEpoch(0),
    );

WayCandidate _way(int id, List<LatLng> geom) => WayCandidate(
      wayId: id,
      geometry: geom,
      highwayClass: 'residential',
    );

void main() {
  group('filterWaysToTripCorridor', () {
    test('empty fixes → returns ways unchanged', () {
      final ways = [
        _way(1, [const LatLng(49.5, 9), const LatLng(49.51, 9.01)]),
      ];
      expect(filterWaysToTripCorridor(fixes: const [], ways: ways), ways);
    });

    test('empty ways → returns empty', () {
      expect(
        filterWaysToTripCorridor(fixes: [_fix(49.5, 9)], ways: const []),
        isEmpty,
      );
    });

    test('keeps a way on the trip path, drops a far-away way', () {
      // Trip runs a short line near (49.500, 9.000).
      final fixes = [
        _fix(49.5000, 9),
        _fix(49.5010, 9.0010),
        _fix(49.5020, 9.0020),
      ];
      final onPath = _way(1, [
        const LatLng(49.5005, 9.0005),
        const LatLng(49.5015, 9.0015),
      ]);
      // ~30 km away — well outside the corridor.
      final farAway = _way(2, [
        const LatLng(49.8000, 9.4000),
        const LatLng(49.8010, 9.4010),
      ]);

      final kept = filterWaysToTripCorridor(
        fixes: fixes,
        ways: [onPath, farAway],
      );
      expect(kept.map((w) => w.wayId), [1]);
    });

    test('keeps a long straight way whose midpoint crosses the corridor '
        'even when both endpoints are outside it', () {
      // Trip is a small cluster near (49.500, 9.000).
      final fixes = [
        _fix(49.5000, 9),
        _fix(49.5005, 9.0005),
        _fix(49.5010, 9.0010),
      ];
      // A ~4 km way running N–S whose endpoints are far above/below the trip
      // but whose middle passes right through it (simulates an autobahn run
      // with vertices ~km apart — the along-segment sampler must catch it).
      final longStraight = _way(3, [
        const LatLng(49.4800, 9.0005),
        const LatLng(49.5200, 9.0005),
      ]);
      final kept = filterWaysToTripCorridor(
        fixes: fixes,
        ways: [longStraight],
      );
      expect(kept.map((w) => w.wayId), [3]);
    });

    test('massively reduces a dense way-set to the corridor subset', () {
      // Simulate a straight-line trip; scatter 500 ways across a wide bbox,
      // only a handful of which sit on the path.
      final fixes = <GpsFix>[
        for (var i = 0; i < 50; i++) _fix(49.50 + i * 0.001, 9.00 + i * 0.001),
      ];
      final ways = <WayCandidate>[
        // On-path ways.
        _way(1, [const LatLng(49.505, 9.005), const LatLng(49.506, 9.006)]),
        _way(2, [const LatLng(49.520, 9.020), const LatLng(49.521, 9.021)]),
        // 498 scattered far-field ways in a big box but off the diagonal.
        for (var i = 0; i < 498; i++)
          _way(1000 + i, [
            LatLng(49.40 + (i % 20) * 0.01, 9.30 + (i ~/ 20) * 0.01),
            LatLng(49.40 + (i % 20) * 0.01 + 0.001, 9.30 + (i ~/ 20) * 0.01),
          ]),
      ];
      final kept = filterWaysToTripCorridor(fixes: fixes, ways: ways);
      // Only the two on-path ways survive; the 498 far-field ways are dropped.
      expect(kept.length, lessThan(10));
      expect(kept.map((w) => w.wayId), containsAll(<int>[1, 2]));
    });
  });
}
