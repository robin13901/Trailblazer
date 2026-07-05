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
}
