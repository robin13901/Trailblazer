// Phase 5 (Plan 05-02): HMM probability primitives.
//
// Newson & Krumm (2009), "Hidden Markov Map Matching Through Noise and
// Sparseness." All functions return LOG-space probabilities to avoid
// floating-point underflow on 3600-fix trips.
//
// No I/O, no state — these are pure functions. Testable with `dart test`.

import 'dart:math' as math;

/// Default emission sigma (Newson-Krumm 2009 empirical value, meters).
/// Runtime adaptive sigma is `max(kEmissionSigmaMeters, hDop/2)` —
/// computed at call site in the decoder, not here.
const double kEmissionSigmaMeters = 4.07;

/// Default transition beta (meters). Scale factor on the exponential
/// penalty for |route_dist - great_circle_dist|. Larger β = more
/// forgiving of route-vs-crow-fly discrepancies. Golden corpus (05-08)
/// will validate — expose as constructor param on the decoder.
const double kTransitionBetaMeters = 1;

/// Base R-Tree query radius (meters) — MMT-04.
const double kBaseRadiusMeters = 25;

/// Upper clamp on adaptive radius (meters).
const double kMaxRadiusMeters = 150;

/// Emission log-probability: log p(z | c) for GPS fix `z` observed at a
/// candidate whose perpendicular distance to the way segment is
/// [perpDistMeters]. Assumes zero-mean Gaussian error with std [sigmaM].
///
/// Returns `-infinity` if sigmaM <= 0.
double emissionLogProb({
  required double perpDistMeters,
  required double sigmaM,
}) {
  if (sigmaM <= 0) return double.negativeInfinity;
  // log(1 / (sqrt(2pi) * sigma)) - d^2 / (2 * sigma^2)
  final logNormalizer = -0.5 * math.log(2 * math.pi * sigmaM * sigmaM);
  final exponent =
      -(perpDistMeters * perpDistMeters) / (2 * sigmaM * sigmaM);
  return logNormalizer + exponent;
}

/// Transition log-probability: log p(c_j | c_i). Newson-Krumm
/// exponential on |route_dist - great_circle|. [betaMeters] scales the
/// penalty — see [kTransitionBetaMeters].
///
/// Returns `-infinity` if betaMeters <= 0.
double transitionLogProb({
  required double routeDistMeters,
  required double greatCircleMeters,
  required double betaMeters,
}) {
  if (betaMeters <= 0) return double.negativeInfinity;
  final diff = (routeDistMeters - greatCircleMeters).abs();
  // log(1/beta) - diff/beta
  return -math.log(betaMeters) - diff / betaMeters;
}

/// Adaptive R-Tree radius (meters) — MMT-04. 25 m base; grows with
/// GPS horizontal accuracy; clamped to [25, 150].
///
/// A non-positive or NaN [horizontalAccuracyMeters] yields the base
/// radius (25 m) — defensive against `double.nan` from some Android
/// providers.
double adaptiveRadiusMeters(double horizontalAccuracyMeters) {
  if (horizontalAccuracyMeters.isNaN || horizontalAccuracyMeters <= 0) {
    return kBaseRadiusMeters;
  }
  final r = kBaseRadiusMeters + horizontalAccuracyMeters / 2;
  return r.clamp(kBaseRadiusMeters, kMaxRadiusMeters);
}
