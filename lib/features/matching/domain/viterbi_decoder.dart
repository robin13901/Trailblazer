// Phase 5 (Plan 05-04): Viterbi HMM decoder.
//
// Newson & Krumm (2009) HMM map-matching, tuned per this codebase:
//   * Emission sigma: adaptive — max(kEmissionSigmaMeters, hDop/2).
//   * Transition beta: kTransitionBetaMeters (1.0 m default).
//   * Route distance: bounded on-road shortest path over a NodeGraph (real
//     Newson-Krumm route distance, not a constant detour factor).
//   * Top-K beam: kBeamWidth (5 per MMT-04).
//   * Adaptive radius: adaptiveRadiusMeters(hDop) per fix (25..150 m).
//   * Gap detection: Δt > kGapThresholdSeconds resets the state.
//   * MMT-07 speed guard: motorway/trunk candidates penalized at
//     speed < kSpeedGuardKmh.
//   * One-way rule: same-wayId transitions must agree with oneway direction.
//
// Pure functional; no I/O; no state beyond the decode() call. Testable
// with `dart test`.

import 'dart:math' as math;

import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_probability.dart';
import 'package:auto_explore/features/matching/domain/matched_step.dart';
import 'package:auto_explore/features/matching/domain/node_graph.dart';
import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Top-K beam width per fix (MMT-04).
const int kBeamWidth = 5;

/// Gap threshold in seconds: Δt > this resets the Viterbi state (MMT-08).
const int kGapThresholdSeconds = 60;

/// Speed below which the MMT-07 motorway/trunk penalty applies (km/h).
const double kSpeedGuardKmh = 15;

/// Route-search cap floor (meters). The bounded route-distance search between
/// two consecutive fixes' candidates is capped at `max(this, gc × factor)`.
/// Consecutive fixes are ~1 s apart, so the true on-road move is short; this
/// floor keeps the search cheap while still finding a genuine detour.
const double kRouteSearchCapFloorMeters = 2000;

/// Route-search cap multiplier on the great-circle distance (see
/// [kRouteSearchCapFloorMeters]). A legal move rarely exceeds a few times the
/// straight-line distance; beyond this the pair is treated as unreachable
/// (Newson-Krumm "broken path").
const double kRouteSearchCapFactor = 8;

/// Log-probability threshold: a fix whose best candidate emission is below
/// this value is treated as unmatched (null output). Value = ln(0.001).
const double kLowConfidenceDropLog = -6.907755278982137; // ln(0.001)

/// Motorway/trunk emission penalty for MMT-07 (log-space).
/// Value = -ln(1e6) ≈ -13.816.
const double kMotorwayPenaltyLog = -13.815510557964274; // -ln(1e6)

/// One-way violation penalty (log-space). Same magnitude as motorway
/// penalty so a same-way transition against the allowed direction is
/// effectively never preferred when alternatives exist.
const double kOnewayViolationLog = -13.815510557964274;

/// Highway classes that trigger the MMT-07 speed guard.
const Set<String> kHighClassHighwaysForSpeedGuard = {
  'motorway',
  'motorway_link',
  'trunk',
  'trunk_link',
};

/// Progress-callback stride: emit `onProgress` every this-many fixes during
/// the forward pass (plus always on the final fix). Keeps isolate-boundary
/// traffic bounded on long traces without losing perceptible smoothness.
const int _kProgressStride = 128;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Pure Viterbi HMM decoder over a [WaySegmentIndex].
///
/// Each call to [decode] is stateless — no internal mutable state is retained
/// between calls. The decoder is safe to run on an isolate.
class ViterbiDecoder {
  const ViterbiDecoder({
    this.betaMeters = kTransitionBetaMeters,
    this.beamWidth = kBeamWidth,
    this.gapThresholdSeconds = kGapThresholdSeconds,
  });

  /// Transition beta (meters); see [kTransitionBetaMeters].
  final double betaMeters;

  /// Maximum number of candidates carried forward per fix.
  final int beamWidth;

  /// Gap-detection threshold in seconds; exposed for testing.
  final int gapThresholdSeconds;

  /// Decode a full GPS trace into a per-fix `List<MatchedStep?>`.
  ///
  /// Returns a list of the same length as [fixes]. Each entry is either:
  /// - A [MatchedStep] when the decoder found a high-confidence match, or
  /// - `null` when the fix falls below the low-confidence threshold
  ///   (MMT-05: unmatched fixes are dropped, never force-snapped).
  ///
  /// Internally:
  /// 1. Forward pass builds a trellis of per-fix [_State] lists.
  /// 2. Backward pass traces back per-sub-track and writes `MatchedStep`
  ///    values. Sub-tracks are separated by gap resets or empty steps.
  ///
  /// [onProgress], when non-null, is invoked periodically during the forward
  /// pass with `(processed, total)` where `total == fixes.length` and
  /// `processed` is the number of fixes processed so far (1-based). It is
  /// throttled — called every [_kProgressStride] fixes AND on the final fix —
  /// to avoid flooding the isolate boundary. When null it is a no-op and all
  /// existing behaviour/outputs are preserved exactly.
  List<MatchedStep?> decode(
    List<GpsFix> fixes,
    WaySegmentIndex index, {
    NodeGraph? nodeGraph,
    void Function(int processed, int total)? onProgress,
  }) {
    if (fixes.isEmpty) return const [];

    // ------------------------------------------------------------------
    // Forward pass
    // ------------------------------------------------------------------
    final trellis = <List<_State>>[];

    for (var step = 0; step < fixes.length; step++) {
      // Throttled progress: every _kProgressStride fixes AND on the final fix.
      // processed is 1-based (number of fixes seen so far). No-op when null.
      if (onProgress != null &&
          ((step + 1) % _kProgressStride == 0 || step == fixes.length - 1)) {
        onProgress(step + 1, fixes.length);
      }

      final fix = fixes[step];

      // Adaptive sigma: max(kEmissionSigmaMeters, accuracyMeters / 2).
      var sigma = kEmissionSigmaMeters;
      if (!fix.accuracyMeters.isNaN && fix.accuracyMeters > 0) {
        sigma = math.max(kEmissionSigmaMeters, fix.accuracyMeters / 2);
      }

      final radius = adaptiveRadiusMeters(fix.accuracyMeters);
      final candidates = index.queryTopK(
        lat: fix.lat,
        lon: fix.lon,
        radiusMeters: radius,
        k: beamWidth,
      );

      if (candidates.isEmpty) {
        trellis.add(const []);
        continue;
      }

      // Build state list for this step.
      final states = <_State>[];
      for (final seg in candidates) {
        final perp = perpDistanceToSegmentMeters(
          pLat: fix.lat,
          pLon: fix.lon,
          aLat: seg.aLat,
          aLon: seg.aLon,
          bLat: seg.bLat,
          bLon: seg.bLon,
        );
        final frac = projectionFractionOnSegment(
          pLat: fix.lat,
          pLon: fix.lon,
          aLat: seg.aLat,
          aLon: seg.aLon,
          bLat: seg.bLat,
          bLon: seg.bLon,
        );
        var emit = emissionLogProb(perpDistMeters: perp, sigmaM: sigma);

        // MMT-07 speed guard: penalize motorway/trunk when slow.
        if (fix.speedKmh < kSpeedGuardKmh &&
            kHighClassHighwaysForSpeedGuard.contains(seg.highwayClass)) {
          emit += kMotorwayPenaltyLog;
        }

        states.add(
          _State(
            segment: seg,
            projectionFraction: frac,
            perpDistMeters: perp,
            emissionLogP: emit,
            totalLogP: emit,
          ),
        );
      }

      // Low-confidence drop: if the best emission is below the threshold
      // (extremely far from any road), treat as unmatched.
      final bestEmit =
          states.fold<double>(double.negativeInfinity, (m, s) {
        return s.emissionLogP > m ? s.emissionLogP : m;
      });
      if (bestEmit < kLowConfidenceDropLog) {
        trellis.add(const []);
        continue;
      }

      // Check whether this step is a gap-reset or first step.
      final isGapReset = step > 0 &&
          _isGap(fixes[step - 1].ts, fix.ts, gapThresholdSeconds);
      final hasPrior = step > 0 && trellis[step - 1].isNotEmpty;

      if (!hasPrior || isGapReset) {
        // No predecessor: start fresh; totalLogP = emissionLogP only.
        // Leave backptr null to mark this as a sub-track start.
        trellis.add(states);
        continue;
      }

      // Transition step: for each candidate at this step, find the best
      // predecessor from the prior step.
      final prevFix = fixes[step - 1];
      final gc = haversineMeters(
        prevFix.lat,
        prevFix.lon,
        fix.lat,
        fix.lon,
      );
      // Route-search cap: a legal move between two consecutive fixes is short.
      final routeCap = math.max(
        kRouteSearchCapFloorMeters,
        gc * kRouteSearchCapFactor,
      );

      final prior = trellis[step - 1];
      for (final s in states) {
        var bestTotal = double.negativeInfinity;
        int? bestIdx;
        for (var pIdx = 0; pIdx < prior.length; pIdx++) {
          final pState = prior[pIdx];

          // REAL route distance: the bounded on-road shortest path between the
          // predecessor's projection point and this candidate's projection
          // point (Newson-Krumm). This is the discrimination the old
          // `gc * 1.4` constant lacked — an impossible jump onto a side road at
          // a junction now costs a large |route − gc|, so the through-road is
          // preferred and the triangle/fan/zigzag artifacts do not form.
          final routeDist = nodeGraph == null
              ? gc // no graph (unit tests) → neutral: route == gc, zero penalty
              : nodeGraph.routeDistanceMeters(
                  fromWayId: pState.segment.wayId,
                  fromSegIdx: pState.segment.segIdx,
                  fromFraction: pState.projectionFraction,
                  fromANode: pState.segment.aNodeId,
                  fromBNode: pState.segment.bNodeId,
                  toWayId: s.segment.wayId,
                  toSegIdx: s.segment.segIdx,
                  toFraction: s.projectionFraction,
                  toANode: s.segment.aNodeId,
                  toBNode: s.segment.bNodeId,
                  maxMeters: routeCap,
                );

          // Breakage (Newson-Krumm broken path): no bounded on-road route
          // between the two candidates → this transition is impossible. Skip
          // the predecessor entirely so it can never be chosen; if EVERY
          // predecessor is unreachable, bestIdx stays null and the traceback
          // treats this candidate as a sub-track start (a fresh run), exactly
          // like a gap reset.
          if (routeDist == null) continue;

          var trans = transitionLogProb(
            routeDistMeters: routeDist,
            greatCircleMeters: gc,
            betaMeters: betaMeters,
          );

          // One-way rule: penalize same-wayId transitions that violate
          // the stored direction. Use an epsilon (0.001) to avoid
          // floating-point noise triggering the penalty.
          if (pState.segment.wayId == s.segment.wayId) {
            final dfrac =
                s.projectionFraction - pState.projectionFraction;
            final oneway = s.segment.oneway;
            if (oneway == OnewayDirection.forward && dfrac < -0.001) {
              trans += kOnewayViolationLog;
            } else if (oneway == OnewayDirection.backward &&
                dfrac > 0.001) {
              trans += kOnewayViolationLog;
            }
          }

          final total = pState.totalLogP + trans + s.emissionLogP;
          if (total > bestTotal) {
            bestTotal = total;
            bestIdx = pIdx;
          }
        }
        if (bestIdx == null) {
          // No reachable predecessor for this candidate (every prior was a
          // broken path). Treat it as a fresh sub-track start: seed totalLogP
          // with the emission only and leave backptr null — identical to the
          // gap-reset / first-step semantics the traceback keys on. Without
          // this reset the state would keep totalLogP = -inf and, if it became
          // the step's sole survivor, poison the whole downstream chain.
          s
            ..totalLogP = s.emissionLogP
            ..backptr = null;
        } else {
          s
            ..totalLogP = bestTotal
            ..backptr = bestIdx;
        }
      }
      trellis.add(states);
    }

    // ------------------------------------------------------------------
    // Backward traceback
    // ------------------------------------------------------------------
    return _traceback(trellis, fixes.length);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  bool _isGap(DateTime prev, DateTime cur, int thresholdSeconds) {
    final dt = cur.difference(prev).inSeconds;
    return dt.abs() > thresholdSeconds;
  }

  List<MatchedStep?> _traceback(
    List<List<_State>> trellis,
    int length,
  ) {
    final result = List<MatchedStep?>.filled(length, null);

    // Identify sub-track boundaries.
    // A sub-track is a maximal contiguous run [lo..hi] of non-empty trellis
    // steps where the FIRST step of each sub-track has null backptrs (gap-
    // reset or first step), and subsequent steps have non-null backptrs.
    //
    // We detect a new sub-track start when:
    //   (a) trellis[step] is the first non-empty step found, OR
    //   (b) every state in trellis[step] has backptr == null (gap-reset
    //       marker), even though trellis[step] is non-empty and the
    //       previous non-empty step exists.
    final subTracks = <(int, int)>[];
    int? curLo;

    for (var step = 0; step < length; step++) {
      if (trellis[step].isEmpty) {
        if (curLo != null) {
          subTracks.add((curLo, step - 1));
          curLo = null;
        }
        continue;
      }
      if (curLo == null) {
        curLo = step;
        continue;
      }
      // Check gap-reset: all states at this step have null backptr.
      final allNull = trellis[step].every((s) => s.backptr == null);
      if (allNull) {
        subTracks.add((curLo, step - 1));
        curLo = step;
      }
    }
    if (curLo != null) subTracks.add((curLo, length - 1));

    // Walk each sub-track independently.
    for (final (lo, hi) in subTracks) {
      // A single sub-track can still contain INTERNAL broken-path resets: a
      // step whose WINNING chain state has backptr == null because no
      // predecessor was routable within the search cap, even though sibling
      // states at that step kept valid backptrs (so the `allNull` sub-track
      // splitter above did NOT fire). Chasing one chain from `hi` and stopping
      // at the first such reset would silently drop every step before it — the
      // trip-11 half-match bug (2026-07-22): a 97 km trace decoded as one
      // sub-track lost its entire first half when the winning chain reset
      // mid-trip. Fix: after a chain terminates at a reset step B, re-run
      // best-terminal + chase over the remaining prefix [lo..B-1], repeating
      // until the whole sub-track is covered. Each contiguous chain is written
      // independently; every matched step is emitted.
      var segHi = hi;
      while (segHi >= lo) {
        // Best terminal state within [lo..segHi] at segHi.
        var bestIdx = 0;
        for (var i = 1; i < trellis[segHi].length; i++) {
          if (trellis[segHi][i].totalLogP > trellis[segHi][bestIdx].totalLogP) {
            bestIdx = i;
          }
        }

        // Chase back-pointers from segHi toward lo, stopping at a reset (null
        // backptr). `breakStep` is where the chain reset (a fresh sub-track
        // start); the next iteration continues from just before it.
        final chain = <(int, int)>[];
        var curIdx = bestIdx;
        var s = segHi;
        var breakStep = lo;
        while (s >= lo) {
          chain.add((s, curIdx));
          final bp = trellis[s][curIdx].backptr;
          if (bp == null) {
            breakStep = s;
            break;
          }
          curIdx = bp;
          s--;
        }

        _writeChain(chain, trellis, result);

        // Continue with the prefix strictly before the reset step. When the
        // chain reached `lo` without a reset, breakStep == lo and we stop.
        segHi = breakStep - 1;
      }
    }

    return result;
  }

  /// Write a back-chased [chain] of `(step, stateIdx)` cells into [result] in
  /// chronological order (so [_directionFrom] can look back at already-written
  /// prior steps on the same way).
  void _writeChain(
    List<(int, int)> chain,
    List<List<_State>> trellis,
    List<MatchedStep?> result,
  ) {
    for (var k = chain.length - 1; k >= 0; k--) {
      final (step, stateIdx) = chain[k];
      final state = trellis[step][stateIdx];
      // Snap the fix onto its matched segment: lerp between the segment's two
      // nodes by the projection fraction. Cheap linear lat/lon interpolation
      // over one short segment matches the equirectangular approximation used
      // throughout segment_geometry.dart. Feeds the road-snapped coverage
      // line (2026-07-14 rework).
      final f = state.projectionFraction;
      result[step] = MatchedStep(
        wayId: state.segment.wayId,
        segIdx: state.segment.segIdx,
        projectionFraction: state.projectionFraction,
        perpDistMeters: state.perpDistMeters,
        emissionLogP: state.emissionLogP,
        direction: _directionFrom(state, step, result),
        highwayClass: state.segment.highwayClass,
        oneway: state.segment.oneway,
        snappedLat:
            state.segment.aLat + (state.segment.bLat - state.segment.aLat) * f,
        snappedLon:
            state.segment.aLon + (state.segment.bLon - state.segment.aLon) * f,
      );
    }
  }

  /// Determine the direction of travel for [state] at [step].
  ///
  /// Looks back in [result] for the nearest prior [MatchedStep] on the
  /// same `wayId`. Returns `'forward'` when no same-way prior exists, or
  /// when the vehicle is moving toward higher segment indices (or the same
  /// segment with increasing fraction); `'backward'` otherwise.
  ///
  /// Uses `segIdx` before `projectionFraction` because the fraction resets
  /// 0→1 on each segment, so comparing fractions alone across segment
  /// boundaries gives incorrect results.
  String _directionFrom(
    _State state,
    int step,
    List<MatchedStep?> result,
  ) {
    // Search backward for the nearest prior step on the same wayId.
    for (var i = step - 1; i >= 0; i--) {
      final prior = result[i];
      if (prior == null) continue;
      if (prior.wayId == state.segment.wayId) {
        // Higher segIdx = forward progress along the way.
        if (state.segment.segIdx > prior.segIdx) return 'forward';
        if (state.segment.segIdx < prior.segIdx) return 'backward';
        // Same segment: compare projection fraction.
        final dfrac = state.projectionFraction - prior.projectionFraction;
        if (dfrac < 0) return 'backward';
        return 'forward';
      }
      // Different way: stop looking (don't infer direction from a
      // different road's position).
      break;
    }
    return 'forward';
  }
}

// ---------------------------------------------------------------------------
// Private trellis state carrier
// ---------------------------------------------------------------------------

/// Internal Viterbi trellis cell.
class _State {
  _State({
    required this.segment,
    required this.projectionFraction,
    required this.perpDistMeters,
    required this.emissionLogP,
    required this.totalLogP,
  });

  /// The way segment this cell corresponds to.
  final WaySegment segment;

  /// Projection fraction onto the segment (0..1).
  final double projectionFraction;

  /// Exact perpendicular distance to the segment (meters).
  final double perpDistMeters;

  /// Emission log-probability (without predecessor contribution).
  final double emissionLogP;

  /// Best total log-probability from the start of the sub-track to this cell.
  double totalLogP;

  /// Index into the previous step's [_State] list. `null` when there is
  /// no predecessor (first step of a sub-track or gap-reset).
  int? backptr;
}
