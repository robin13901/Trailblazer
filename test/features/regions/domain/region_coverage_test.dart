// Trailblazer Phase 8, Plan 08-01:
// Unit tests for region_coverage.dart — covers coveragePercent,
// formatPercent, and RegionCoverage value type derivations.

import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('coveragePercent', () {
    test('returns 0 when totalLengthM is 0', () {
      expect(coveragePercent(0, 0), 0.0);
    });

    test('returns 0 when totalLengthM is negative', () {
      expect(coveragePercent(5, -1), 0.0);
    });

    test('returns 0 when drivenLengthM is 0 but total > 0', () {
      expect(coveragePercent(0, 1000), 0.0);
    });

    test('returns 26.4 for 264m driven out of 1000m', () {
      expect(coveragePercent(264, 1000), closeTo(26.4, 1e-9));
    });

    test('clamps to 100 when driven exceeds total', () {
      expect(coveragePercent(1500, 1000), 100.0);
    });

    test('returns exactly 100 when driven equals total', () {
      expect(coveragePercent(1000, 1000), 100.0);
    });

    test('returns 50 for half coverage', () {
      expect(coveragePercent(500, 1000), 50.0);
    });

    test('never returns negative', () {
      // Negative driven is technically invalid, but clamp ensures 0 output.
      expect(coveragePercent(-100, 1000), 0.0);
    });
  });

  group('formatPercent', () {
    test('formats 26.4 as "26,4 %" (German locale)', () {
      expect(formatPercent(26.4), '26,4 %');
    });

    test('formats 0 as "0,0 %"', () {
      expect(formatPercent(0), '0,0 %');
    });

    test('formats 100 as "100,0 %"', () {
      expect(formatPercent(100), '100,0 %');
    });

    test('formats 25 as "25,0 %" (one decimal)', () {
      expect(formatPercent(25), '25,0 %');
    });

    test('formats 3.14159 as "3,1 %" (one decimal, truncated)', () {
      expect(formatPercent(3.14159), '3,1 %');
    });
  });

  group('formatKm (dynamic precision, 2026-07-17)', () {
    test('< 1000: one decimal, comma separator', () {
      expect(formatKm(3.2), '3,2');
      expect(formatKm(32.9), '32,9');
      expect(formatKm(950.3), '950,3');
    });

    test('boundary 999.x stays one-decimal', () {
      expect(formatKm(999.9), '999,9');
    });

    test('>= 1000: no decimals, dot thousands separators', () {
      expect(formatKm(1000), '1.000');
      expect(formatKm(1234.6), '1.235'); // rounds to whole
      expect(formatKm(148884), '148.884');
    });

    test('exactly 1000 crosses into thousands-separator branch', () {
      expect(formatKm(1000), '1.000');
    });
  });

  group('formatKmStats', () {
    test('both < 1000 → comma decimals', () {
      expect(formatKmStats(3.2, 32.9), '3,2 / 32,9 km');
    });

    test('total >= 1000 → dot thousands separators', () {
      expect(formatKmStats(1234.6, 148884), '1.235 / 148.884 km');
    });
  });

  group('RegionCoverage', () {
    const rc = RegionCoverage(
      osmId: 12345,
      adminLevel: 8,
      name: 'Test Landkreis',
      drivenLengthM: 500,
      totalLengthM: 2000,
    );

    test('percentLabel is "25,0 %"', () {
      expect(rc.percentLabel, '25,0 %');
    });

    test('drivenKm is 0.5', () {
      expect(rc.drivenKm, 0.5);
    });

    test('totalKm is 2.0', () {
      expect(rc.totalKm, 2.0);
    });

    test('percent is 25.0', () {
      expect(rc.percent, 25.0);
    });

    group('equality', () {
      test('equal when osmId, drivenLengthM, totalLengthM match', () {
        const rc2 = RegionCoverage(
          osmId: 12345,
          adminLevel: 6, // different level — does not affect equality
          name: 'Other Name', // different name — does not affect equality
          drivenLengthM: 500,
          totalLengthM: 2000,
        );
        expect(rc, equals(rc2));
      });

      test('not equal when osmId differs', () {
        const rc3 = RegionCoverage(
          osmId: 99999,
          adminLevel: 8,
          name: 'Test Landkreis',
          drivenLengthM: 500,
          totalLengthM: 2000,
        );
        expect(rc, isNot(equals(rc3)));
      });

      test('not equal when drivenLengthM differs', () {
        const rc4 = RegionCoverage(
          osmId: 12345,
          adminLevel: 8,
          name: 'Test Landkreis',
          drivenLengthM: 600,
          totalLengthM: 2000,
        );
        expect(rc, isNot(equals(rc4)));
      });

      test('hashCode matches for equal instances', () {
        const rc5 = RegionCoverage(
          osmId: 12345,
          adminLevel: 4,
          name: 'Renamed',
          drivenLengthM: 500,
          totalLengthM: 2000,
        );
        expect(rc.hashCode, equals(rc5.hashCode));
      });
    });

    group('zero-total guard', () {
      const empty = RegionCoverage(
        osmId: 1,
        adminLevel: 2,
        name: 'Deutschland',
        drivenLengthM: 0,
        totalLengthM: 0,
      );

      test('percent is 0 when totalLengthM is 0', () {
        expect(empty.percent, 0.0);
      });

      test('percentLabel is "0,0 %" when totalLengthM is 0', () {
        expect(empty.percentLabel, '0,0 %');
      });
    });

    group('clamp at 100', () {
      const overdriven = RegionCoverage(
        osmId: 2,
        adminLevel: 10,
        name: 'Overdriven Ort',
        drivenLengthM: 1500,
        totalLengthM: 1000,
      );

      test('percent is clamped to 100', () {
        expect(overdriven.percent, 100.0);
      });

      test('percentLabel is "100,0 %"', () {
        expect(overdriven.percentLabel, '100,0 %');
      });
    });
  });
}
