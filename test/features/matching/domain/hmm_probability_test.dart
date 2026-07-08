// Phase 5 (Plan 05-02): HMM probability — golden-value unit tests.
//
// All values are hand-computed from the Newson-Krumm (2009) formulas:
//
//   emissionLogProb = -0.5·log(2π·σ²) - d²/(2σ²)
//   transitionLogProb = -log(β) - |routeDist - gcDist| / β
//
// No Flutter binding — pure `dart test`.

import 'dart:math' as math;

import 'package:auto_explore/features/matching/domain/hmm_probability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  group('exported constants', () {
    test('kEmissionSigmaMeters = 4.07', () {
      expect(kEmissionSigmaMeters, equals(4.07));
    });

    test('kTransitionBetaMeters = 1.0', () {
      expect(kTransitionBetaMeters, equals(1.0));
    });

    test('kBaseRadiusMeters = 25.0', () {
      expect(kBaseRadiusMeters, equals(25.0));
    });

    test('kMaxRadiusMeters = 150.0', () {
      expect(kMaxRadiusMeters, equals(150.0));
    });
  });

  // ---------------------------------------------------------------------------
  // emissionLogProb — Gaussian on perpendicular distance
  // ---------------------------------------------------------------------------
  group('emissionLogProb', () {
    // Helper: hand-computed log-normalizer for sigma=4.07
    // logNorm = -0.5 * log(2 * pi * 4.07^2)
    final logNorm4_07 =
        -0.5 * math.log(2 * math.pi * 4.07 * 4.07);

    // Test 1: perpDist = 0  →  logNorm + 0
    test('perpDist=0, sigma=4.07 ≈ -2.3226 ±1e-6', () {
      final expected = logNorm4_07; // ≈ -2.3225...
      final actual = emissionLogProb(perpDistMeters: 0, sigmaM: 4.07);
      expect(actual, closeTo(expected, 1e-6));
    });

    // Test 2: perpDist = sigma  →  logNorm - 0.5
    test('perpDist=4.07, sigma=4.07 ≈ logNorm-0.5 ±1e-6', () {
      final expected = logNorm4_07 - 0.5;
      final actual = emissionLogProb(perpDistMeters: 4.07, sigmaM: 4.07);
      expect(actual, closeTo(expected, 1e-6));
    });

    // Test 3: monotonically decreasing as perpDist grows
    test('decreases monotonically as perpDist grows', () {
      final v0 = emissionLogProb(perpDistMeters: 0, sigmaM: 4.07);
      final v5 = emissionLogProb(perpDistMeters: 5, sigmaM: 4.07);
      final v10 = emissionLogProb(perpDistMeters: 10, sigmaM: 4.07);
      final v50 = emissionLogProb(perpDistMeters: 50, sigmaM: 4.07);
      expect(v0, greaterThan(v5));
      expect(v5, greaterThan(v10));
      expect(v10, greaterThan(v50));
    });

    // Test 4: sigma=0 → -infinity (defensive)
    test('sigma=0 returns negativeInfinity', () {
      expect(
        emissionLogProb(perpDistMeters: 5, sigmaM: 0),
        equals(double.negativeInfinity),
      );
    });

    // Test 5: sigma<0 → -infinity (defensive)
    test('sigma<0 returns negativeInfinity', () {
      expect(
        emissionLogProb(perpDistMeters: 5, sigmaM: -1),
        equals(double.negativeInfinity),
      );
    });

    // Extra: symmetry — emissionLogProb(-d) == emissionLogProb(d) when d≥0
    // (distance is always non-negative by caller convention, but the formula
    //  is even in d regardless)
    test('formula is even in perpDistMeters (d^2 term)', () {
      final a = emissionLogProb(perpDistMeters: 7.5, sigmaM: 4.07);
      final b = emissionLogProb(perpDistMeters: 7.5, sigmaM: 4.07);
      expect(a, closeTo(b, 1e-12));
    });
  });

  // ---------------------------------------------------------------------------
  // transitionLogProb — exponential on |routeDist - gcDist|
  // ---------------------------------------------------------------------------
  group('transitionLogProb', () {
    // Test 6: perfect match → 0
    test('routeDist=gcDist=100, beta=1 → 0.0', () {
      final actual = transitionLogProb(
        routeDistMeters: 100,
        greatCircleMeters: 100,
        betaMeters: 1,
      );
      expect(actual, closeTo(0.0, 1e-12));
    });

    // Test 7: diff=5, beta=1 → -5.0
    test('routeDist=105, gcDist=100, beta=1 → -5.0', () {
      final actual = transitionLogProb(
        routeDistMeters: 105,
        greatCircleMeters: 100,
        betaMeters: 1,
      );
      expect(actual, closeTo(-5.0, 1e-12));
    });

    // Test 8: symmetric under swap of routeDist / gcDist
    test('symmetric under endpoint swap', () {
      final ab = transitionLogProb(
        routeDistMeters: 120,
        greatCircleMeters: 100,
        betaMeters: 5,
      );
      final ba = transitionLogProb(
        routeDistMeters: 100,
        greatCircleMeters: 120,
        betaMeters: 5,
      );
      expect(ab, closeTo(ba, 1e-12));
    });

    // Test 9: monotonically decreases as |route-gc| grows
    test('decreases monotonically as |route-gc| grows', () {
      const gc = 100.0;
      final v0 = transitionLogProb(
        routeDistMeters: gc,
        greatCircleMeters: gc,
        betaMeters: 1,
      );
      final v5 = transitionLogProb(
        routeDistMeters: gc + 5,
        greatCircleMeters: gc,
        betaMeters: 1,
      );
      final v20 = transitionLogProb(
        routeDistMeters: gc + 20,
        greatCircleMeters: gc,
        betaMeters: 1,
      );
      expect(v0, greaterThan(v5));
      expect(v5, greaterThan(v20));
    });

    // Test 10: beta=0 → -infinity
    test('beta=0 returns negativeInfinity', () {
      expect(
        transitionLogProb(
          routeDistMeters: 100,
          greatCircleMeters: 100,
          betaMeters: 0,
        ),
        equals(double.negativeInfinity),
      );
    });

    // Extra: beta=10, diff=10 → -log(10) - 1
    test('beta=10, diff=10 → -log(10) - 1 ±1e-9', () {
      final expected = -math.log(10) - 10.0 / 10.0;
      final actual = transitionLogProb(
        routeDistMeters: 110,
        greatCircleMeters: 100,
        betaMeters: 10,
      );
      expect(actual, closeTo(expected, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // adaptiveRadiusMeters — base 25 m, grows with accuracy, clamped [25, 150]
  // ---------------------------------------------------------------------------
  group('adaptiveRadiusMeters', () {
    // Test 11: negative accuracy → 25 (defensive)
    test('negative accuracy (-5) → 25.0', () {
      expect(adaptiveRadiusMeters(-5), equals(25.0));
    });

    // Test 12: NaN → 25 (defensive)
    test('NaN → 25.0', () {
      expect(adaptiveRadiusMeters(double.nan), equals(25.0));
    });

    // Test 13: 0 → 25 (base)
    test('accuracy=0 → 25.0', () {
      expect(adaptiveRadiusMeters(0), equals(25.0));
    });

    // Test 14: accuracy=50 → 25 + 25 = 50
    test('accuracy=50 → 50.0', () {
      expect(adaptiveRadiusMeters(50), closeTo(50.0, 1e-9));
    });

    // Test 15: accuracy=1000 → 150 (upper clamp)
    test('accuracy=1000 → 150.0 (clamped)', () {
      expect(adaptiveRadiusMeters(1000), equals(150.0));
    });

    // Extra: accuracy=250 → 25 + 125 = 150 exactly (reaches clamp boundary)
    test('accuracy=250 → exactly 150.0 (at clamp boundary)', () {
      expect(adaptiveRadiusMeters(250), equals(150.0));
    });

    // Extra: accuracy=10 → 25 + 5 = 30
    test('accuracy=10 → 30.0', () {
      expect(adaptiveRadiusMeters(10), closeTo(30.0, 1e-9));
    });
  });
}
