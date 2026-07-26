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
import 'package:auto_explore/features/matching/domain/node_graph.dart';
import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/matching/domain/viterbi_decoder.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Maximum full length (m) of a way eligible for the topology-based
/// pass-through extension. A genuine junction connector — the short link the
/// vehicle drives straight through between two roads — is typically only a
/// handful of meters and legitimately catches just 1-2 GPS fixes, so its
/// measured span collapses to ~0. Short ways at or below this length are
/// extended to full length ONLY when the topology check confirms a real
/// pass-through (entered one end, exited the other — see
/// `_isPassThroughConnector`).
///
/// Ways LONGER than this never use the topology path; they extend only when
/// the measured span already proves traversal ([kMinTraversedFractionForExtend]).
/// 30 m matches the `isFullyCovered` small-way branch in
/// `coverage_threshold.dart`.
const double kMaxPassThroughConnectorMeters = 30;

/// For pass-through ways LONGER than [kMaxPassThroughConnectorMeters], the
/// measured span must cover at least this fraction of the full way length
/// before we extend to full length. A brief GPS excursion onto a neighbouring
/// parallel road covers only a small fraction, so it fails this gate and keeps
/// its conservative measured span (which the coverage short-way floor then
/// discards). A real end-to-end drive covers most of the way and passes.
const double kMinTraversedFractionForExtend = 0.5;

/// How close (m) an adjacent way's nearest vertex must be to a connector's
/// endpoint node to count as "attached" there. OSM junction nodes are shared
/// exactly between ways, but GPS-cache geometry and densification can nudge
/// coordinates slightly; 12 m tolerates that without merging distinct nodes of
/// a short connector (whose two ends are >= its full length apart).
const double kConnectorEndpointToleranceMeters = 12;

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

    // Routing graph over the same candidate ways, keyed by OSM node id (or a
    // coordinate-hash surrogate). Gives the decoder a REAL bounded on-road
    // route distance between consecutive candidates, replacing the old
    // constant detour factor — this is what stops junction mis-snaps.
    final nodeGraph = NodeGraph.fromWays(ways);

    final decoder = ViterbiDecoder(
      betaMeters: betaMeters,
      beamWidth: beamWidth,
    );
    final steps = decoder.decode(
      fixes,
      index,
      nodeGraph: nodeGraph,
      onProgress: onProgress,
    );

    final intervals = _collapseToIntervals(steps, waysById);
    // #10 matcher-side auto-fill: bridge small NULL/confidence gaps between
    // adjacent intervals on the same way, and close collinear continuations
    // across a degree-2 shared node between two ways. Conservative — see
    // `_fillSmallGaps`. The manual tap-to-fill (DB/UI) half of #10 is separate.
    final filled = _fillSmallGaps(intervals, waysById, nodeGraph);

    final matched = steps.where((s) => s != null).length;
    final dropped = steps.length - matched;

    return MatchResult(
      steps: steps,
      intervals: filled,
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
    // A same-wayId run tracks four raw meter marks so an out-and-back excursion
    // (#9) is captured faithfully: [runRawMin..runRawMax] is the true peak
    // span, while runRawFirst/runRawLast give the net direction. All four are
    // seeded to the run's first `meters` at BOTH start sites.
    double runRawFirst = 0; // meters at the first step of the current run
    double runRawLast = 0; // meters at the latest step of the current run
    double runRawMin = 0; // smallest meters seen this run (peak excursion lo)
    double runRawMax = 0; // largest meters seen this run (peak excursion hi)
    // Established travel direction along the way for this run: +1 = toward
    // higher meters, -1 = toward lower, null = not yet determined. Drives the
    // #9 out-and-back reversal split.
    double? runDirSign;
    // True when this run began by transitioning DIRECTLY from a different
    // matched way (not from a gap/null or the trip start). Half of the
    // pass-through test.
    var enteredFromOtherWay = false;
    // The wayId of the run IMMEDIATELY BEFORE this one (the way we entered
    // from), when [enteredFromOtherWay]. Used by the topology check to tell a
    // genuine A→B→C pass-through from an A→B→A spur excursion.
    int? entryWayId;

    // [exitedToOtherWay] completes the pass-through test: the run ends because
    // a DIFFERENT matched way immediately follows (not a gap/null or trip end).
    // [exitWayId] is that following way (null on gap/trip-end).
    void flush({required bool exitedToOtherWay, int? exitWayId}) {
      if (runWayId == null) return;
      // #9: the interval spans the full peak excursion (min..max), and the net
      // direction is the sign of last-vs-first (the direction the run ended up
      // heading). For a monotonic run min==first and max==last, so this is
      // identical to the pre-change min/max behaviour — existing golden and
      // intra-way tests are unaffected. For an out-and-back that was NOT split
      // (excursion below kReversalMinMeters), the span still reflects the true
      // peak rather than the collapsed endpoints.
      var start = runRawMin;
      var end = runRawMax;
      final direction = runRawLast >= runRawFirst ? 'forward' : 'backward';

      // Pass-through recall fix (2026-07-10): a way the vehicle demonstrably
      // ENTERED from another way and EXITED to another way was traversed
      // end-to-end — but a short junction connector often catches only 1-2
      // GPS fixes, so the raw [start..end] collapses to a near-zero-length
      // point and the coverage renderer drops it (→ visible gap at the
      // junction). When both the entry and exit are ways (a true pass-through),
      // extend the interval to the FULL way length so the connector renders.
      // Ways only touched at the trip start/end, or bounded by a confidence
      // gap, keep the conservative measured span (we can't prove traversal).
      //
      // Full-length extension (2026-07-18, tightened): extend a partially-
      // measured run to the FULL way length ONLY when the route genuinely
      // traversed the way END-TO-END — it entered from another matched way
      // attached to ONE endpoint node and exited to another matched way
      // attached to the OTHER endpoint node (exact OSM node-id topology via
      // `_isPassThroughConnector`, now applied to ways of ANY length, not just
      // short connectors). This is the gap-closer for junction connectors and
      // for a road split into consecutive OSM way-segments each driven fully.
      //
      // The prior rule extended on `coversMajority` ALONE (measured span ≥ 50%
      // of the way) with no topology check for longer ways. That over-drew a
      // road the vehicle merely ran PARALLEL to or CLIPPED near a junction: a
      // parallel excursion snaps a majority-spanning run onto the neighbour and
      // got auto-completed to 100% (the real "Dientzenhoferstraße" over-draw,
      // painted 256/256 m with its midpoint 49 m off the actual GPS trace).
      // Requiring end-to-end topology refuses that: a parallel/clip enters and
      // exits at the SAME end (or tees mid-way, attaching to neither endpoint),
      // so the topology check fails and only the conservatively-measured span
      // is kept — the coverage floor then drops a tiny clip entirely.
      //
      // `coversMajority` is retained as CORROBORATION for longer ways: a
      // genuine end-to-end drive already spans most of the way, so a topology
      // "pass-through" whose measured span is implausibly tiny (a mid-length
      // way matched to 1-2 fixes) is not blindly completed. Short connectors
      // legitimately catch only 1-2 fixes, so they extend on topology alone.
      if (enteredFromOtherWay && exitedToOtherWay) {
        final way = waysById[runWayId];
        if (way != null) {
          final len = _polylineLengthMeters(way.geometry);
          if (len > 0) {
            final measuredSpan = end - start;
            final coversMajority =
                measuredSpan >= len * kMinTraversedFractionForExtend;
            final isShortConnector = len <= kMaxPassThroughConnectorMeters;
            final passesThroughEndToEnd = _isPassThroughConnector(
              connector: way,
              entryWay: waysById[entryWayId],
              exitWay: waysById[exitWayId],
            );
            if (passesThroughEndToEnd && (isShortConnector || coversMajority)) {
              start = 0;
              end = len;
            }
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
        runRawFirst = metersFromWayStart;
        runRawLast = metersFromWayStart;
        runRawMin = metersFromWayStart;
        runRawMax = metersFromWayStart;
        runDirSign = null;
        enteredFromOtherWay = false;
        entryWayId = null;
      } else if (s.wayId != runWayId) {
        // Different way: the previous run exited to another way → pass-through
        // eligible. Capture the way we're leaving (the entry way of the NEW
        // run) before flushing, and tell flush which way we're exiting to.
        final leavingWayId = runWayId;
        flush(exitedToOtherWay: true, exitWayId: s.wayId);
        runWayId = s.wayId;
        runRawFirst = metersFromWayStart;
        runRawLast = metersFromWayStart;
        runRawMin = metersFromWayStart;
        runRawMax = metersFromWayStart;
        runDirSign = null;
        enteredFromOtherWay = true;
        entryWayId = leavingWayId;
        continue;
      } else {
        // Same way: extend the current run.
        // #9 OUT-AND-BACK: detect a genuine reversal on the same way. When the
        // vehicle was heading one way (runDirSign established) and the new step
        // moves the OPPOSITE way, and the run has already covered a real
        // excursion (peak span >= kReversalMinMeters), flush the current
        // directional interval and start a FRESH same-wayId run seeded here.
        // The result is [entry..peak] in one direction + [peak..exit] in the
        // other, together covering the full driven span — instead of a single
        // interval whose collapsed min/max hides the turn-around direction.
        // Guarded by kReversalMinMeters so GPS jitter does not split a run.
        final delta = metersFromWayStart - runRawLast;
        final newSign = delta == 0 ? 0.0 : delta.sign;
        if (runDirSign != null &&
            newSign != 0 &&
            newSign != runDirSign &&
            (runRawMax - runRawMin) >= kReversalMinMeters) {
          // Flush the completed directional leg. This is NOT a way change, so
          // it is not a pass-through (we did not exit to another way).
          flush(exitedToOtherWay: false);
          // Fresh same-wayId run seeded at the current position. The next
          // step's delta will establish the new (reversed) direction.
          runWayId = s.wayId;
          runRawFirst = metersFromWayStart;
          runRawLast = metersFromWayStart;
          runRawMin = metersFromWayStart;
          runRawMax = metersFromWayStart;
          runDirSign = null;
          enteredFromOtherWay = false;
          entryWayId = null;
        } else {
          if (newSign != 0) runDirSign = newSign;
          runRawLast = metersFromWayStart;
          if (metersFromWayStart < runRawMin) runRawMin = metersFromWayStart;
          if (metersFromWayStart > runRawMax) runRawMax = metersFromWayStart;
        }
      }
    }
    // End of trace: the final run did NOT exit to another way.
    flush(exitedToOtherWay: false);
    return out;
  }

  /// Topology test distinguishing a genuine junction connector (drove A→B→C,
  /// must render to close the gap) from a spurious spur/ramp/parallel
  /// excursion (drove A→B→A near a junction, must NOT render).
  ///
  /// A genuine pass-through enters [connector] from [entryWay] at one endpoint
  /// node and exits to [exitWay] at the OTHER endpoint node — the connector
  /// bridges the two roads, so the vehicle necessarily traversed its full
  /// length. A spur/ramp dangles off a single junction node: the entry and
  /// exit roads both attach to the SAME endpoint of [connector] (frequently
  /// entryWay == exitWay, an A→B→A return), so the vehicle only dipped onto the
  /// near end and turned around — the far end was never reached.
  ///
  /// **Exact when OSM node ids are present (2026-07-18):** two ways share a
  /// junction iff they list the same node id, so "attaches to endpoint X" is a
  /// set-membership test on the connector's first/last node id — no distance
  /// tolerance, no nearest-endpoint disambiguation, and immune to the residual
  /// over-draw that plagued the old fuzzy 12 m test on short connectors. When
  /// node ids are absent (hand-authored fixtures — `nodeIds` empty), it falls
  /// back to the nearest-endpoint coordinate test.
  ///
  /// Returns true (extend to full) only when [entryWay] attaches to one
  /// endpoint and [exitWay] to the OTHER. Returns false — the conservative
  /// default — when entry and exit are the same way (A→B→A), when either is
  /// unattached, or when both attach to the same endpoint.
  bool _isPassThroughConnector({
    required WayCandidate connector,
    required WayCandidate? entryWay,
    required WayCandidate? exitWay,
  }) {
    final geom = connector.geometry;
    if (geom.length < 2) return false;
    if (entryWay == null || exitWay == null) return false;
    // A→B→A: the same road on both sides is a spur/return, never a genuine
    // pass-through — the vehicle left road A onto B and came straight back.
    if (entryWay.wayId == exitWay.wayId) return false;

    // Exact path: connector endpoints are its first/last node ids; a neighbour
    // attaches to an end iff it lists that node id.
    final ids = connector.nodeIds;
    if (ids.length == geom.length && ids.length >= 2) {
      final startId = ids.first;
      final endId = ids.last;
      final entryEnd = _attachedEndById(entryWay, startId, endId);
      final exitEnd = _attachedEndById(exitWay, startId, endId);
      if (entryEnd == _ConnectorEnd.none || exitEnd == _ConnectorEnd.none) {
        return false;
      }
      return entryEnd != exitEnd;
    }

    // Fallback (no node ids): nearest-endpoint coordinate test.
    final startNode = geom.first;
    final endNode = geom.last;
    final entryEnd = _attachedEnd(entryWay, startNode, endNode);
    final exitEnd = _attachedEnd(exitWay, startNode, endNode);
    if (entryEnd == _ConnectorEnd.none || exitEnd == _ConnectorEnd.none) {
      return false;
    }
    return entryEnd != exitEnd;
  }

  /// Exact endpoint attachment by OSM node id: returns which connector endpoint
  /// ([startId] / [endId]) the [way] shares a node with, or
  /// [_ConnectorEnd.none] when it shares neither. When a way somehow lists
  /// both, the start wins (deterministic; a real connector's two ends are
  /// distinct nodes so this is a degenerate self-loop case).
  _ConnectorEnd _attachedEndById(WayCandidate way, int startId, int endId) {
    var touchesStart = false;
    var touchesEnd = false;
    for (final id in way.nodeIds) {
      if (id == startId) touchesStart = true;
      if (id == endId) touchesEnd = true;
    }
    if (touchesStart) return _ConnectorEnd.start;
    if (touchesEnd) return _ConnectorEnd.end;
    return _ConnectorEnd.none;
  }

  /// Which endpoint of a connector [way] attaches to — whichever of
  /// [startNode] / [endNode] its nearest vertex is closer to — or
  /// [_ConnectorEnd.none] when even that nearest vertex is beyond
  /// [kConnectorEndpointToleranceMeters] (the way does not touch the connector
  /// at all). Coordinate fallback used only when node ids are unavailable.
  _ConnectorEnd _attachedEnd(WayCandidate way, LatLng startNode, LatLng endNode) {
    var dStart = double.infinity;
    var dEnd = double.infinity;
    for (final v in way.geometry) {
      final ds = segmentLengthMeters(
        aLat: v.latitude,
        aLon: v.longitude,
        bLat: startNode.latitude,
        bLon: startNode.longitude,
      );
      if (ds < dStart) dStart = ds;
      final de = segmentLengthMeters(
        aLat: v.latitude,
        aLon: v.longitude,
        bLat: endNode.latitude,
        bLon: endNode.longitude,
      );
      if (de < dEnd) dEnd = de;
    }
    if (math.min(dStart, dEnd) > kConnectorEndpointToleranceMeters) {
      return _ConnectorEnd.none;
    }
    return dStart <= dEnd ? _ConnectorEnd.start : _ConnectorEnd.end;
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

  // ---------------------------------------------------------------------------
  // #10 Matcher-side gap auto-fill (2026-07-25)
  // ---------------------------------------------------------------------------

  /// Bridge small gaps left by a NULL/confidence drop between adjacent driven
  /// intervals. Two shapes are handled, both conservatively:
  ///
  /// * **Same wayId, same direction:** a confidence gap flushed the run and it
  ///   restarted on the same way. If the metric gap `cur.start - prev.end` is
  ///   positive AND no branch node (degree > 2) lies strictly inside that meter
  ///   interval along the way, merge into `[prev.start .. cur.end]`. There is
  ///   NO upper size cap (#10 highway fix, 2026-07-26): one OSM way is a single
  ///   continuous road, so absent a branch node the whole span was driven.
  /// * **Different wayId, same direction, collinear continuation:** the two
  ///   ways meet at a single degree-2 node shared by exactly those two ways
  ///   (no branch), and each interval already reaches the endpoint touching
  ///   that node (within [kHighwayEndpointToleranceMeters]). Extend `prev` to
  ///   its endpoint and `cur` to its start so the junction renders continuously.
  ///
  /// Everything else — direction mismatch, missing/ambiguous topology, a branch
  /// node, or a gap over the threshold — is left untouched (mirrors
  /// `_isPassThroughConnector`'s conservative philosophy). The manual
  /// tap-to-fill half of #10 (DB/UI) is out of scope here.
  List<DrivenWayIntervalDraft> _fillSmallGaps(
    List<DrivenWayIntervalDraft> intervals,
    Map<int, WayCandidate> waysById,
    NodeGraph nodeGraph,
  ) {
    if (intervals.length < 2) return intervals;
    final result = <DrivenWayIntervalDraft>[];
    for (final cur in intervals) {
      if (result.isEmpty) {
        result.add(cur);
        continue;
      }
      final prev = result.last;
      final repl = _tryFill(prev, cur, waysById, nodeGraph);
      if (repl != null) {
        result
          ..removeLast()
          ..addAll(repl);
      } else {
        result.add(cur);
      }
    }
    return result;
  }

  /// Attempt to bridge the gap between adjacent intervals [prev] and [cur].
  /// Returns the replacement for the pair (`[merged]` for a same-way merge, or
  /// `[extendedPrev, extendedCur]` for a different-way collinear extension), or
  /// `null` when no fill applies.
  List<DrivenWayIntervalDraft>? _tryFill(
    DrivenWayIntervalDraft prev,
    DrivenWayIntervalDraft cur,
    Map<int, WayCandidate> waysById,
    NodeGraph nodeGraph,
  ) {
    // Must share travel direction — never bridge a reversal (#9 split).
    if (prev.direction != cur.direction) return null;

    if (prev.wayId == cur.wayId) {
      final way = waysById[prev.wayId];
      if (way == null || way.geometry.length < 2) return null;
      final gap = cur.startMeters - prev.endMeters;
      // #10 highway gap (2026-07-26): the upper cap was removed. A single OSM
      // way is ONE continuous road; if prev and cur are the same wayId, same
      // direction, and NO branch node (degree > 2) lies strictly between them,
      // the vehicle provably drove the whole span — a way cannot be exited
      // mid-segment. At highway speed a dropped fix leaves a 60-90 m same-way
      // hole that the old 30 m cap refused to close; the branch-node guard
      // below makes closing gaps of ANY size safe (an interchange through-node
      // is degree > 2 and blocks the merge). Keep gap > 0 (adjacent/overlapping
      // intervals are handled by the caller's union).
      if (gap <= 0) return null;
      // Refuse to bridge across a branch (degree > 2) inside the gap.
      if (_branchNodeStrictlyBetween(
        way,
        prev.endMeters,
        cur.startMeters,
        nodeGraph,
      )) {
        return null;
      }
      return [
        DrivenWayIntervalDraft(
          wayId: prev.wayId,
          startMeters: prev.startMeters,
          endMeters: cur.endMeters,
          direction: prev.direction,
        ),
      ];
    }

    // Different wayId: collinear continuation across a single shared node.
    final pWay = waysById[prev.wayId];
    final cWay = waysById[cur.wayId];
    if (pWay == null || cWay == null) return null;
    if (pWay.geometry.length < 2 || cWay.geometry.length < 2) return null;

    final lenP = _polylineLengthMeters(pWay.geometry);
    final lenC = _polylineLengthMeters(cWay.geometry);
    if (lenP <= 0 || lenC <= 0) return null;
    // #10 highway continuation (2026-07-26): decoupled from kMaxAutoFillGapMeters.
    // A degree-2 node has NO alternative route, so passing A→B necessarily
    // traverses the shared node N regardless of the metric shortfall — at
    // highway speed the last matched fix before the boundary can sit >30 m
    // short. Use the highway-safe endpoint tolerance; the degree-2 / {A,B}
    // topology check below still gates the fill (degree > 2 interchanges never
    // continue).
    const tol = kHighwayEndpointToleranceMeters;

    // Which endpoint node(s) does each interval already touch (within tol)?
    // Each entry pairs the OSM node id with a flag: true = END node, false =
    // START node — so the extension knows which meter bound to open up.
    final pEnds = <(int nodeId, bool isEnd)>[
      if (prev.startMeters <= tol) (_nodeIdAt(pWay, 0), false),
      if (lenP - prev.endMeters <= tol) (_nodeIdAt(pWay, pWay.geometry.length - 1), true),
    ];
    final cEnds = <(int nodeId, bool isEnd)>[
      if (cur.startMeters <= tol) (_nodeIdAt(cWay, 0), false),
      if (lenC - cur.endMeters <= tol) (_nodeIdAt(cWay, cWay.geometry.length - 1), true),
    ];

    for (final (pNode, pIsEnd) in pEnds) {
      for (final (cNode, cIsEnd) in cEnds) {
        if (pNode != cNode) continue;
        // Degree-2, shared by EXACTLY these two ways = pure continuation.
        if (nodeGraph.nodeDegree(pNode) != 2) continue;
        final ways = nodeGraph.waysAtNode(pNode);
        if (ways.length != 2 ||
            !ways.contains(prev.wayId) ||
            !ways.contains(cur.wayId)) {
          continue;
        }
        // Extend prev up to its touched endpoint, cur out from its.
        final extPrev = DrivenWayIntervalDraft(
          wayId: prev.wayId,
          startMeters: pIsEnd ? prev.startMeters : 0,
          endMeters: pIsEnd ? lenP : prev.endMeters,
          direction: prev.direction,
        );
        final extCur = DrivenWayIntervalDraft(
          wayId: cur.wayId,
          startMeters: cIsEnd ? cur.startMeters : 0,
          endMeters: cIsEnd ? lenC : cur.endMeters,
          direction: cur.direction,
        );
        return [extPrev, extCur];
      }
    }
    return null;
  }

  /// True when a branch node — one where more than two distinct ways meet —
  /// lies STRICTLY between [loMeters] and [hiMeters] along [way]. Used to
  /// refuse a same-way gap merge that would paint across an intersection the
  /// vehicle might have turned off at.
  bool _branchNodeStrictlyBetween(
    WayCandidate way,
    double loMeters,
    double hiMeters,
    NodeGraph nodeGraph,
  ) {
    final geom = way.geometry;
    var cum = 0.0;
    for (var i = 0; i < geom.length; i++) {
      if (i > 0) {
        cum += segmentLengthMeters(
          aLat: geom[i - 1].latitude,
          aLon: geom[i - 1].longitude,
          bLat: geom[i].latitude,
          bLon: geom[i].longitude,
        );
      }
      if (cum > loMeters && cum < hiMeters) {
        if (nodeGraph.nodeDegree(_nodeIdAt(way, i)) > 2) return true;
      }
    }
    return false;
  }

  /// OSM node id of [way]'s vertex [i] — the real id when [WayCandidate.nodeIds]
  /// is present, else the deterministic coordinate-hash surrogate the rest of
  /// the matcher (and [NodeGraph]) uses for hand-authored fixtures.
  int _nodeIdAt(WayCandidate way, int i) {
    final ids = way.nodeIds;
    if (ids.length == way.geometry.length) return ids[i];
    final v = way.geometry[i];
    return WaySegment.nodeKeyFor(v.latitude, v.longitude);
  }
}

/// Which endpoint of a short connector way an adjacent (entry/exit) way is
/// attached to, per [HmmMatcher._attachedEnd].
enum _ConnectorEnd { start, end, none }
