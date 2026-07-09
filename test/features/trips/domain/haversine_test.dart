import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('haversineMeters', () {
    test(
      'Frankfurt → Grebenhain ≈ 63.7 km within 0.5% tolerance',
      () {
        // Frankfurt Hauptbahnhof: 50.1109, 8.6821
        // Grebenhain (Vogelsberg): 50.5013, 9.3389
        // Hard-coded from Haversine formula: ≈ 63 719 m (~63.7 km).
        // Cross-checked with manual spherical-geometry calculation.
        const expected = 63720;
        final result = haversineMeters(50.1109, 8.6821, 50.5013, 9.3389);
        expect(
          result,
          closeTo(expected, expected * 0.005),
          reason: 'Frankfurt→Grebenhain must be within 0.5% of $expected m',
        );
      },
    );

    test('same-point distance is 0', () {
      final result = haversineMeters(50.1109, 8.6821, 50.1109, 8.6821);
      expect(result, equals(0));
    });

    test(
      '1 arc-second latitude ≈ 30.9 m, measured within 5% tolerance',
      () {
        // 1 arc-second ≈ 1/3600 degree ≈ 30.87 m at equator / ~30.9 m at mid-lat
        const oneDegLat = 1 / 3600;
        const expectedM = 30.9;
        final result = haversineMeters(
          50,
          9,
          50 + oneDegLat,
          9,
        );
        expect(
          result,
          closeTo(expectedM, expectedM * 0.05),
          reason: '1 arc-second lat should be within 5% of $expectedM m',
        );
      },
    );

    test('symmetry: A→B equals B→A', () {
      final ab = haversineMeters(50.1109, 8.6821, 50.5013, 9.3389);
      final ba = haversineMeters(50.5013, 9.3389, 50.1109, 8.6821);
      expect(ab, closeTo(ba, 0.001));
    });
  });

  group('bearingDegrees', () {
    // Small offsets around a mid-latitude origin so the cardinal directions
    // land close to their exact compass bearings (great-circle bearing
    // drifts slightly over long east/west spans; short hops stay tight).
    const lat = 50.0;
    const lon = 9.0;
    const d = 0.001; // ~111 m north / ~72 m east at this latitude

    test('due north ≈ 0°', () {
      expect(bearingDegrees(lat, lon, lat + d, lon), closeTo(0, 0.5));
    });

    test('due east ≈ 90°', () {
      expect(bearingDegrees(lat, lon, lat, lon + d), closeTo(90, 0.5));
    });

    test('due south ≈ 180°', () {
      expect(bearingDegrees(lat, lon, lat - d, lon), closeTo(180, 0.5));
    });

    test('due west ≈ 270°', () {
      expect(bearingDegrees(lat, lon, lat, lon - d), closeTo(270, 0.5));
    });

    test('result is always in 0..360', () {
      // A south-west hop lands in the third quadrant (180..270). The exact
      // bearing is not 225° because a degree of longitude is shorter than a
      // degree of latitude at 50°N, so the vector leans more southward.
      final bearing = bearingDegrees(lat, lon, lat - d, lon - d);
      expect(bearing, greaterThan(180));
      expect(bearing, lessThan(270));
    });

    test('same point returns 0 (degenerate)', () {
      expect(bearingDegrees(lat, lon, lat, lon), equals(0));
    });
  });
}
