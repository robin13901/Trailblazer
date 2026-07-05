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

    test('sizes scale with berlinKfzWays', () {
      final small = extrapolatedBerlinProbe(berlinKfzWays: 10000);
      final big = extrapolatedBerlinProbe(berlinKfzWays: 1000000);
      final smallMb = small.strategyMb[SchemaStrategy.denormalizedFull];
      final bigMb = big.strategyMb[SchemaStrategy.denormalizedFull];
      expect(bigMb, greaterThan(smallMb ?? 0));
    });

    test('recommendation follows the size thresholds', () {
      // Tiny Berlin → tiny Germany projection → all strategies fit → full.
      final tiny = extrapolatedBerlinProbe(berlinKfzWays: 100);
      expect(tiny.recommendation, SchemaStrategy.denormalizedFull);

      // Huge Berlin → huge Germany projection → all strategies blow out →
      // last resort.
      final huge = extrapolatedBerlinProbe(berlinKfzWays: 5000000);
      expect(huge.recommendation, SchemaStrategy.joinTableOnly);
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
