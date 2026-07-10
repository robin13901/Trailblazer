// Phase 5 (Plan 05-05): HmmMatcher — the orchestrator that turns
// (List<GpsFix>, List<WayCandidate>) into a MatchResult.
//
// Responsibilities:
//   1. Build a WaySegmentIndex from the supplied WayCandidate list.
//   2. Run ViterbiDecoder.decode to get per-fix List<MatchedStep?>.
//   3. Collapse consecutive MatchedSteps into DrivenWayIntervalDraft rows
//      via the interval-merging algorithm described in Plan 05-05.
//
// The matcher is STATELESS: two calls with identical inputs produce
// identical outputs. Safe to run on an isolate (Plan 05-06).
//
// No Drift, no Flutter, no isolate API in this file.

import 'dart:math' as math;

import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_probability.dart';
import 'package:auto_explore/features/matching/domain/match_result.dart';
import 'package:auto_explore/features/matching/domain/matched_step.dart';
import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/matching/domain/viterbi_decoder.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Orchestrator that maps a raw GPS trace + road-candidate list to a
/// [MatchResult] containing per-fix [MatchedStep]s and collapsed
/// [DrivenWayIntervalDraft]s.
///
/// Usage:
/// ```dart
/// final result = const HmmMatcher().match(fixes: fixes, ways: ways);
/// // result.intervals → ready for DrivenWayIntervalsDao.insertBatch
/// //                     after the coordinator (05-07) adds tripId.
/// ```
class HmmMatcher {
  const HmmMatcher({
    this.betaMeters = kTransitionBetaMeters,
    this.beamWidth = kBeamWidth,
  });

  /// Transition beta (meters); forwarded to [ViterbiDecoder].
  final double betaMeters;

  /// Top-K beam width; forwarded to [ViterbiDecoder].
  final int beamWidth;

  /// Match a GPS trace against a set of road candidates.
  ///
  /// Returns a [MatchResult] with:
  /// - [MatchResult.steps]: per-fix Viterbi decisions (null = dropped).
  /// - [MatchResult.intervals]: collapsed intervals ready for the DAO.
  ///
  /// Empty [fixes] → empty [MatchResult] with zero intervals.
  /// Empty [ways] → all fixes dropped (no candidates), empty intervals.
  ///
  /// [onProgress], when non-null, is forwarded to [ViterbiDecoder.decode] and
  /// invoked periodically with `(processed, total)` during the forward pass
  /// (`total == fixes.length`). It is a no-op when null and produces no
  /// behaviour change relative to the null case.
  MatchResult match({
    required List<GpsFix> fixes,
    required List<WayCandidate> ways,
    void Function(int processed, int total)? onProgress,
  }) {
    if (fixes.isEmpty) {
      return const MatchResult(
        steps: [],
        intervals: [],
        matchedFixCount: 0,
        droppedFixCount: 0,
      );
    }

    final index = WaySegmentIndex.buildFromWays(ways);
    final waysById = <int, WayCandidate>{
      for (final w in ways) w.wayId: w,
    };

    final decoder = ViterbiDecoder(
      betaMeters: betaMeters,
      beamWidth: beamWidth,
    );
    final steps = decoder.decode(fixes, index, onProgress: onProgress);

    final intervals = _collapseToIntervals(steps, waysById);

    final matched = steps.where((s) => s != null).length;
    final dropped = steps.length - matched;

    return MatchResult(
      steps: steps,
      intervals: intervals,
      matchedFixCount: matched,
      droppedFixCount: dropped,
    );
  }

  // ---------------------------------------------------------------------------
  // Interval merging
  // ---------------------------------------------------------------------------

  /// Collapse consecutive [MatchedStep]s into [DrivenWayIntervalDraft] rows.
  ///
  /// Merging rules (Plan 05-05 §must_haves):
  /// - Consecutive steps on the **same wayId** extend the current interval.
  /// - A **different wayId** flushes the current interval and starts a new one.
  /// - A **null step** (confidence gap, MMT-05) flushes the current interval.
  ///   The next non-null step starts a fresh interval, even on the same wayId.
  ///
  /// `startMeters` / `endMeters` are cumulative segment lengths from the
  /// way's first node to the projection point, computed via
  /// `segmentLengthMeters` (Plan 05-02). At flush time the raw first/last
  /// meter values may be in any order; `startMeters` is always the minimum,
  /// `endMeters` the maximum, and `direction` is derived from the sign:
  ///   - `rawEnd >= rawStart → 'forward'`
  ///   - `rawEnd < rawStart → 'backward'`
  ///
  /// Direction-flip intra-way: when a vehicle reverses on the same way, the
  /// sign of (currentMeters − previousMeters) flips. Per Plan 05-05
  /// §Deviations, this plan does NOT try to split intra-way reversal — that
  /// is a Phase 6 aggregation concern. The flush happens only on wayId change
  /// or null gap; the stored interval captures start=min, end=max, direction
  /// derived from the net delta (first vs last raw meter value).
  List<DrivenWayIntervalDraft> _collapseToIntervals(
    List<MatchedStep?> steps,
    Map<int, WayCandidate> waysById,
  ) {
    final out = <DrivenWayIntervalDraft>[];

    int? runWayId;
    double runRawStart = 0; // meters at the first step of the current run
    double runRawEnd = 0; // meters at the latest step of the current run
    // True when this run began by transitioning DIRECTLY from a different
    // matched way (not from a gap/null or the trip start). Half of the
    // pass-through test.
    var enteredFromOtherWay = false;

    // [exitedToOtherWay] completes the pass-through test: the run ends because
    // a DIFFERENT matched way immediately follows (not a gap/null or trip end).
    void flush({required bool exitedToOtherWay}) {
      if (runWayId == null) return;
      var start = math.min(runRawStart, runRawEnd);
      var end = math.max(runRawStart, runRawEnd);
      final direction = runRawEnd >= runRawStart ? 'forward' : 'backward';

      // Pass-through recall fix (2026-07-10): a way the vehicle demonstrably
      // ENTERED from another way and EXITED to another way was traversed
      // end-to-end — but a short junction connector often catches only 1-2
      // GPS fixes, so the raw [start..end] collapses to a near-zero-length
      // point and the coverage renderer drops it (→ visible gap at the
      // junction). When both the entry and exit are ways (a true pass-through),
      // extend the interval to the FULL way length so the connector renders.
      // Ways only touched at the trip start/end, or bounded by a confidence
      // gap, keep the conservative measured span (we can't prove traversal).
      if (enteredFromOtherWay && exitedToOtherWay) {
        final way = waysById[runWayId];
        if (way != null) {
          final len = _polylineLengthMeters(way.geometry);
          if (len > 0) {
            start = 0;
            end = len;
          }
        }
      }

      out.add(
        DrivenWayIntervalDraft(
          wayId: runWayId!,
          startMeters: start,
          endMeters: end,
          direction: direction,
        ),
      );
      runWayId = null;
    }

    for (final s in steps) {
      if (s == null) {
        // Confidence gap: flush the current run (NOT a pass-through — we don't
        // know the vehicle exited to another way) and wait for the next step.
        flush(exitedToOtherWay: false);
        continue;
      }

      final metersFromWayStart = _metersFromWayStart(s, waysById);

      if (runWayId == null) {
        // Start a new run after a gap/null or at trip start — NOT entered from
        // another matched way, so reset the pass-through entry flag.
        runWayId = s.wayId;
        runRawStart = metersFromWayStart;
        runRawEnd = metersFromWayStart;
        enteredFromOtherWay = false;
      } else if (s.wayId != runWayId) {
        // Different way: the previous run exited to another way → pass-through
        // eligible. Flush it, then the new run counts as entered-from-a-way.
        flush(exitedToOtherWay: true);
        runWayId = s.wayId;
        runRawStart = metersFromWayStart;
        runRawEnd = metersFromWayStart;
        enteredFromOtherWay = true;
        continue;
      } else {
        // Same way: extend the current run.
        runRawEnd = metersFromWayStart;
      }
    }
    // End of trace: the final run did NOT exit to another way.
    flush(exitedToOtherWay: false);
    return out;
  }

  // ---------------------------------------------------------------------------
  // Meter accumulation
  // ---------------------------------------------------------------------------

  /// Distance in meters from the way's first node to the projection point
  /// of `step` on its matched segment.
  ///
  /// Algorithm (Plan 05-05 §Context):
  ///   sum of segmentLengthMeters for segments 0 through segIdx-1
  ///   + step.projectionFraction * segmentLengthMeters at step.segIdx
  ///
  /// Returns 0.0 when the way geometry is missing or degenerate (< 2 points).
  double _metersFromWayStart(
    MatchedStep step,
    Map<int, WayCandidate> waysById,
  ) {
    final way = waysById[step.wayId];
    if (way == null || way.geometry.length < 2) return 0;

    final geom = way.geometry;
    var acc = 0.0;

    // Sum the lengths of all complete segments before the matched segment.
    for (var i = 0; i < step.segIdx && i + 1 < geom.length; i++) {
      acc += segmentLengthMeters(
        aLat: geom[i].latitude,
        aLon: geom[i].longitude,
        bLat: geom[i + 1].latitude,
        bLon: geom[i + 1].longitude,
      );
    }

    // Add the fractional portion within the current segment.
    if (step.segIdx + 1 < geom.length) {
      final segLen = segmentLengthMeters(
        aLat: geom[step.segIdx].latitude,
        aLon: geom[step.segIdx].longitude,
        bLat: geom[step.segIdx + 1].latitude,
        bLon: geom[step.segIdx + 1].longitude,
      );
      acc += step.projectionFraction * segLen;
    }

    return acc;
  }

  /// Total Haversine length of a way polyline, summed over its segments.
  /// Used by the pass-through recall fix to extend a traversed connector's
  /// interval to the full way length.
  double _polylineLengthMeters(List<LatLng> geometry) {
    var total = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      total += segmentLengthMeters(
        aLat: geometry[i].latitude,
        aLon: geometry[i].longitude,
        bLat: geometry[i + 1].latitude,
        bLon: geometry[i + 1].longitude,
      );
    }
    return total;
  }
}
