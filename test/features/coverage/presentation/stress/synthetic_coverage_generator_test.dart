// Trailblazer Phase 7, Plan 07-07:
// Unit tests for synthetic_coverage_generator.dart
//
// Tests use count: 100 (NOT 50k) to keep CI fast.
// Covers: count, bbox, geometry length, determinism.

import 'package:auto_explore/features/coverage/presentation/stress/synthetic_coverage_generator.dart';
import 'package:flutter_test/flutter_test.dart';

// Germany bounding box — mirrors constants in the generator.
const _kLatMin = 47.27;
const _kLatMax = 55.06;
const _kLonMin = 5.87;
const _kLonMax = 15.04;

void main() {
  group('syntheticCoverageWays', () {
    test('returns exactly count ways', () {
      final ways = syntheticCoverageWays(count: 100);
      expect(ways.length, equals(100));
    });

    test('all wayIds equal their index', () {
      final ways = syntheticCoverageWays(count: 100);
      for (var i = 0; i < ways.length; i++) {
        expect(ways[i].wayId, equals(i),
            reason: 'wayId at index $i should be $i');
      }
    });

    test('all points are within Germany bounding box', () {
      final ways = syntheticCoverageWays(count: 100);
      for (final way in ways) {
        for (final pt in way.geometry) {
          expect(
            pt.latitude,
            inInclusiveRange(_kLatMin, _kLatMax),
            reason:
                'lat ${pt.latitude} out of Germany bbox [$_kLatMin..$_kLatMax]',
          );
          expect(
            pt.longitude,
            inInclusiveRange(_kLonMin, _kLonMax),
            reason:
                'lon ${pt.longitude} out of Germany bbox [$_kLonMin..$_kLonMax]',
          );
        }
      }
    });

    test('each way has between 3 and 8 geometry points', () {
      final ways = syntheticCoverageWays(count: 100, seed: 7);
      for (final way in ways) {
        expect(
          way.geometry.length,
          inInclusiveRange(3, 8),
          reason: 'way ${way.wayId} has ${way.geometry.length} points',
        );
      }
    });

    test('deterministic: same seed produces identical results', () {
      final a = syntheticCoverageWays(count: 100, seed: 99);
      final b = syntheticCoverageWays(count: 100, seed: 99);

      expect(a.length, equals(b.length));
      for (var i = 0; i < a.length; i++) {
        expect(a[i].wayId, equals(b[i].wayId));
        expect(a[i].datum, equals(b[i].datum));
        expect(a[i].geometry.length, equals(b[i].geometry.length));
        for (var p = 0; p < a[i].geometry.length; p++) {
          expect(a[i].geometry[p].latitude,
              closeTo(b[i].geometry[p].latitude, 1e-10));
          expect(a[i].geometry[p].longitude,
              closeTo(b[i].geometry[p].longitude, 1e-10));
        }
      }
    });

    test('different seeds produce different results', () {
      final a = syntheticCoverageWays(count: 100, seed: 1);
      final b = syntheticCoverageWays(count: 100, seed: 2);
      // Very unlikely all first-point latitudes match across different seeds.
      final aLats = a.map((w) => w.geometry[0].latitude).toList();
      final bLats = b.map((w) => w.geometry[0].latitude).toList();
      expect(aLats, isNot(equals(bLats)));
    });

    test('datum fraction is in [0.0, 1.0] for all ways', () {
      final ways = syntheticCoverageWays(count: 100);
      for (final way in ways) {
        expect(
          way.datum.fraction,
          inInclusiveRange(0, 1),
          reason: 'fraction ${way.datum.fraction} out of [0, 1]',
        );
      }
    });

    test('default parameters: count=50000 and seed=42 compiles without error',
        () {
      // Smoke-test the default parameter signature — do NOT actually call with
      // 50k in a unit test. Calling with count: 1 exercises the path.
      expect(syntheticCoverageWays(count: 1).length, equals(1));
    });
  });

  group('syntheticCoverageWaysArgs', () {
    test('record-arg variant produces same output as named-param function', () {
      const args = (count: 50, seed: 17);
      final direct = syntheticCoverageWays(count: 50, seed: 17);
      final viaArgs = syntheticCoverageWaysArgs(args);

      expect(viaArgs.length, equals(direct.length));
      for (var i = 0; i < direct.length; i++) {
        expect(viaArgs[i].wayId, equals(direct[i].wayId));
        expect(viaArgs[i].datum, equals(direct[i].datum));
      }
    });
  });
}
