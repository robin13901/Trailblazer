import 'package:osm_pipeline/measure/berlin_row_count_probe.dart';
import 'package:test/test.dart';

void main() {
  group('extrapolatedBerlinProbe', () {
    test('marks extrapolation mode and produces a recommendation', () {
      final r = extrapolatedBerlinProbe();
      expect(r.extrapolationMode, BerlinRowCountProbeMode.extrapolatedFromTiny);
      expect(r.strategyMb, hasLength(3));
      expect(r.strategyMb[SchemaStrategy.denormalizedFull], greaterThan(0));
      expect(r.strategyMb[SchemaStrategy.joinTableOnly], greaterThan(0));
      // Recommendation is one of the three enum members.
      expect(SchemaStrategy.values.contains(r.recommendation), isTrue);
    });

    test('naive model sizes scale with berlinKfzWays', () {
      // The slim model uses a fixed Germany Kfz-way count (4M per
      // 04-RESEARCH §7), so slim projections do NOT scale with berlinKfzWays.
      // The naive area-ratio model does. See 04-05-BERLIN-MEASUREMENT.md
      // for the reasoning behind that split.
      final small = extrapolatedBerlinProbe(berlinKfzWays: 10000);
      final big = extrapolatedBerlinProbe(berlinKfzWays: 1000000);
      final smallMb = small.strategyMbNaive[SchemaStrategy.denormalizedFull];
      final bigMb = big.strategyMbNaive[SchemaStrategy.denormalizedFull];
      expect(bigMb, greaterThan(smallMb ?? 0));
    });

    test('recommendation is one of the three variants + SC4 target is set',
        () {
      // Under the slim model, Germany projections do not fit 200 MB. The
      // negotiation logic therefore relaxes the target to 300 or 500 MB
      // (or leaves it at 500 if nothing fits any target — the recommendation
      // is still valid, the report just flags the overshoot).
      final r = extrapolatedBerlinProbe();
      expect(SchemaStrategy.values.contains(r.recommendation), isTrue);
      expect([200, 300, 500].contains(r.sc4TargetMb), isTrue);
      expect(r.projectedGermanyMb, greaterThan(0));
    });
  });

  group('renderBerlinMeasurementReport', () {
    test('contains all six admin levels + strategies + recommendation line',
        () {
      final r = extrapolatedBerlinProbe();
      final md = renderBerlinMeasurementReport(r);
      for (final lvl in [2, 4, 6, 8, 9, 10]) {
        expect(md, contains('Admin regions (level $lvl)'));
      }
      for (final s in SchemaStrategy.values) {
        expect(md, contains(s.label));
      }
      expect(md, contains('04-06 SHOULD use:'));
      expect(md, contains('not empirically verified'));
    });
  });

  group('SchemaStrategyLabel', () {
    test('labels are stable and non-empty', () {
      for (final s in SchemaStrategy.values) {
        expect(s.label.isNotEmpty, isTrue);
      }
    });
  });
}
