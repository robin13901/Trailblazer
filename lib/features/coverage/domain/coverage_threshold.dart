// Trailblazer Phase 7, Plan 07-01:
// Pure-Dart coverage threshold and fraction functions (COV-02, COV-03).
// Isolate-safe — no dart:io, no Riverpod, no generated code.
// Consumed by the Phase-7 coverage overlay pipeline (07-03/07-04).

import 'dart:math' as math;

import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';

// ---------------------------------------------------------------------------
// Named constants — tunable against the golden corpus in 07-04
// ---------------------------------------------------------------------------

/// GPS start/end buffer applied to both ends of a way when testing for
/// full coverage (COV-02). A 15 m GPS drift window at each node means a
/// driven pass that clips the last 14 m of a dead end still counts as full.
const double kCoverageBufferMeters = 15;

/// Absolute minimum driven length before a way shows any partial coverage
/// (COV-03 / REN-03 floor). A stray 30 m GPS clip on a 1 km autobahn (3 %)
/// must not light up orange. Tune against golden corpus.
const double kPartialFloorMeters = 50;

/// Fractional minimum driven length before a way shows partial coverage,
/// expressed as a fraction of way length (COV-03 / REN-03 floor). The actual
/// floor is max([kPartialFloorMeters], [kPartialFloorFraction] × wayLength).
const double kPartialFloorFraction = 0.05;

// ---------------------------------------------------------------------------
// COV-02: Fully-explored threshold
// ---------------------------------------------------------------------------

/// Returns true when [unionLengthM] meets the fully-explored threshold for
/// a way of [wayLengthM] metres.
///
/// For ways longer than 30 m: threshold = wayLength − 2 × [kCoverageBufferMeters]
/// (15 m GPS drift window at each end).
///
/// For very short ways (≤ 30 m): threshold = 80 % of way length, since a
/// 15 m buffer on each end of a 20 m residential stub would require negative
/// driven length.
bool isFullyCovered(double unionLengthM, double wayLengthM) {
  if (wayLengthM <= 30.0) {
    return unionLengthM >= wayLengthM * 0.8;
  }
  return unionLengthM >=
      (wayLengthM - kCoverageBufferMeters - kCoverageBufferMeters);
}

// ---------------------------------------------------------------------------
// COV-03: Partial-coverage fraction + floor
// ---------------------------------------------------------------------------

/// Classifies coverage for a single way given its driven union length and
/// total length, both in metres.
///
/// Returns a [CoverageDatum] with:
/// - [CoverageDatum.fraction] clamped to [0.0, 1.0].
/// - [CoverageDatum.isFull] derived from [isFullyCovered].
///
/// **Minimum partial floor (REN-03):** a way shows partial ONLY when
/// `unionLengthM >= max(kPartialFloorMeters, wayLengthM × kPartialFloorFraction)`.
/// Below the floor, returns [CoverageDatum.undriven()] — treated identically
/// to undriven by the render layer. Tune against the golden corpus.
///
/// Guards against [wayLengthM] ≤ 0 by returning [CoverageDatum.undriven()].
CoverageDatum classifyCoverage(double unionLengthM, double wayLengthM) {
  if (wayLengthM <= 0) return const CoverageDatum.undriven();

  final floor = math.max(kPartialFloorMeters, wayLengthM * kPartialFloorFraction);
  if (unionLengthM < floor) return const CoverageDatum.undriven();

  final fraction = (unionLengthM / wayLengthM).clamp(0.0, 1.0);
  final isFull = isFullyCovered(unionLengthM, wayLengthM);
  return CoverageDatum(fraction: fraction, isFull: isFull);
}
