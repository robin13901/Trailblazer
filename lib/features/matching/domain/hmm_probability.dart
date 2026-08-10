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

/// FIX C emission/collapse proximity guard (2026-07-27): the maximum distance
/// (meters) a SAMPLE of a collapsed interval's own painted geometry may sit
/// from the raw GPS track before that sample counts as "far". See
/// [kMaxFarGeometryFraction] for how the far-fraction is used. Set at
/// ~2*[kEmissionSigmaMeters] plus GPS-noise headroom.
const double kMaxMatchedGeometryToFixMeters = 15;

/// FIX C: an interval is dropped as a parallel-offset over-match when MORE than
/// this fraction of its sampled geometry is farther than
/// [kMaxMatchedGeometryToFixMeters] from the raw GPS track. Measured on live
/// data the separation is stark: correctly-driven ways have ~0 % of their
/// geometry far (max ~14 m), while parallel emission over-matches (Obrigheim
/// Panoramaweg/Münchbergweg, B469 Stockstadt frontage) have 50-100 % far. 0.35
/// sits well below the 50 % floor of every observed over-match and far above
/// the 0 % of every genuine drive, so it removes the false positives without
/// clipping any real (even short/partway) drive.
const double kMaxFarGeometryFraction = 0.35;

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

/// HARD-GATE angle (degrees) for the #11 dual-carriageway fix. When the
/// vehicle's travel direction is known (see [kDirMinSpeedKmh] /
/// [kDirMinMoveMeters]) AND a candidate is a `oneway`, the candidate is DROPPED
/// from the trellis outright — not merely down-weighted — if its legal travel
/// bearing differs from the vehicle's by MORE than this. The soft
/// `kDirectionWeightLog` reweighting caps at ~5 nats, which cannot overcome the
/// ~11 nat emission advantage the WRONG (nearer) carriageway of a divided road
/// enjoys when GPS noise nudges a fix toward it; the hard gate removes the
/// opposing carriageway (Δθ ≈ 180°) from contention regardless of perp
/// distance. Set to 120° (not 90°) so derived-bearing noise and legitimate
/// curves on a single oneway ramp survive — only genuinely near-opposite
/// candidates are dropped. INERT when the travel bearing is unknown and on
/// `oneway=no` ways (single carriageways untouched).
const double kOnewayOppositeGateDegrees = 120;

/// Same-way stickiness bonus (nats) added to a transition that stays on the
/// same `wayId` as its predecessor. Default 0.0 = no-op (all goldens stay
/// byte-identical). Exposed as a tuning hook only; do NOT raise it without
/// deliberately regenerating the golden corpus.
const double kSameWayStickinessLog = 0;

/// Same-ROAD continuation bonus (nats) added to a transition between two
/// DIFFERENT ways that carry the SAME `ref` (e.g. both "B 469") and are
/// genuinely routable to each other (routeDist != null). A trunk/Bundesstraße
/// is chopped into dozens of short same-ref ways, so crossing each seam costs a
/// small transition penalty; a parallel unref'd frontage road is ONE continuous
/// way and pays nothing, letting it out-continue the real road at a seam and be
/// painted alongside it (defect F, B469 near Stockstadt). This bonus offsets one
/// seam's typical cost so the chopped same-ref corridor behaves as one road —
/// the user's "a road is one road" continuity. Sized well under emission
/// differences (comparable to [kDirectionWeightLog]) so it can never snap onto a
/// genuinely different road: it only applies where the two ways are already
/// routable (node-connected), and a parallel opposing carriageway is node-
/// disjoint so `routeDist` is null and the bonus is never reached. Inert for
/// unref'd ways (ref == null) — the frontage road never matches any B469 ref.
const double kSameRefContinuationLog = 2;

/// Minimum peak excursion (meters) on a same-way run before an intra-way
/// direction reversal is allowed to SPLIT the run into two directional
/// intervals (#9 out-and-back). Guards against GPS jitter spuriously splitting
/// a monotonic run.
const double kReversalMinMeters = 10;

/// Maximum gap (meters) between two adjacent driven intervals that the
/// matcher-side auto-fill (#10) will bridge. Matches the short-connector /
/// `isFullyCovered` small-way floor used elsewhere in the matcher.
const double kMaxAutoFillGapMeters = 30;

/// Highway-safe endpoint-touch tolerance (meters) for the #10 DIFFERENT-wayId
/// degree-2 continuation fill. At highway speed (120 km/h, 1 Hz sampling ≈ 33 m
/// per fix) the last matched fix before a way boundary can sit well beyond the
/// 30 m [kMaxAutoFillGapMeters] cap, so the pure degree-2 continuation across a
/// shared node — where there is provably NO alternative route (a degree-2 node
/// has no branch) — must accept a larger endpoint shortfall. Passing A→B across
/// a degree-2 node necessarily traverses the shared node N regardless of the
/// metric gap, so raising the tolerance here is safe. Degree > 2 interchange
/// nodes stay conservative (never filled) — the car may have exited via a ramp.
const double kHighwayEndpointToleranceMeters = 60;

/// #10 through-intersection bridge (2026-07-27): hard upper bound on the total
/// on-road length a single gap bridge may paint. Genuine data/rendering gaps at
/// an intersection are short; a wrong-road detour would exceed this.
const double kMaxBridgeMeters = 200;

/// Max ratio of bridge on-road route length to the straight-line (great-circle)
/// distance between the two loose-end nodes. A true through-drive has
/// route ≈ straight-line; a wrong-parallel-road detour has route ≫ straight-line.
const double kBridgeMaxLengthRatio = 1.6;

/// GPS-corridor tolerance: every node on a proposed bridge path must lie within
/// this distance of SOME raw GPS fix, else the vehicle never went there and the
/// bridge is refused. This is the primary guard against inventing undriven road.
const double kBridgeCorridorMeters = 45;

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
  final exponent = -(perpDistMeters * perpDistMeters) / (2 * sigmaM * sigmaM);
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
