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

// ---------------------------------------------------------------------------
// Direction term (#11 dual-carriageway fix) — 2026-07-25
// ---------------------------------------------------------------------------

/// Weight (nats) on the travel-direction penalty scored against a candidate
/// segment's legal (oneway-aware) bearing. The penalty is
/// `kDirectionWeightLog * (1 - cos(Δθ))` so it is 0 at aligned headings and
/// peaks at `2 * kDirectionWeightLog = 5.0` nats when the travel direction is
/// 180° opposed to the segment's legal direction. This is what separates the
/// two carriageways of a dual carriageway: both are `oneway`, ~15 m apart, so
/// emission alone (perp distance) cannot tell them apart when GPS noise nudges
/// a fix toward the wrong carriageway — but the vehicle's heading agrees with
/// only one of them. `oneway=no` ways contribute NOTHING (single carriageways
/// and every existing `oneway=no` golden stay byte-identical).
const double kDirectionWeightLog = 2.5;

/// Minimum speed (km/h) for the OS-reported heading to be trusted as the
/// travel direction. Below this the heading is noise (jitter while nearly
/// stationary), so the direction term is skipped for that fix.
const double kDirMinSpeedKmh = 8;

/// Minimum inter-fix movement (meters) for a bearing DERIVED from two
/// consecutive fixes to be meaningful. Below this the derived bearing is
/// dominated by GPS noise, so the direction term is skipped.
const double kDirMinMoveMeters = 5;

/// Same-way stickiness bonus (nats) added to a transition that stays on the
/// same `wayId` as its predecessor. Default 0.0 = no-op (all goldens stay
/// byte-identical). Exposed as a tuning hook only; do NOT raise it without
/// deliberately regenerating the golden corpus.
const double kSameWayStickinessLog = 0;

/// Minimum peak excursion (meters) on a same-way run before an intra-way
/// direction reversal is allowed to SPLIT the run into two directional
/// intervals (#9 out-and-back). Guards against GPS jitter spuriously splitting
/// a monotonic run.
const double kReversalMinMeters = 10;

/// Maximum gap (meters) between two adjacent driven intervals that the
/// matcher-side auto-fill (#10) will bridge. Matches the short-connector /
/// `isFullyCovered` small-way floor used elsewhere in the matcher.
const double kMaxAutoFillGapMeters = 30;

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
