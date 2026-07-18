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
    // The wayId of the run IMMEDIATELY BEFORE this one (the way we entered
    // from), when [enteredFromOtherWay]. Used by the topology check to tell a
    // genuine A→B→C pass-through from an A→B→A spur excursion.
    int? entryWayId;

    // [exitedToOtherWay] completes the pass-through test: the run ends because
    // a DIFFERENT matched way immediately follows (not a gap/null or trip end).
    // [exitWayId] is that following way (null on gap/trip-end).
    void flush({required bool exitedToOtherWay, int? exitWayId}) {
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
      //
      // Over-draw guard (2026-07-10, revised): the raw pass-through test marked
      // spurious ways as fully driven — an exit ramp or a side-street stub that
      // a couple of GPS fixes drifted onto near a junction, or a parallel road.
      // The renderer paints the WHOLE way geometry for any covered way, so the
      // entire ramp/stub lit up ("triangle at every exit", side-street snippet).
      // A short connector is extended ONLY when the topology confirms a real
      // pass-through: entered from one endpoint and exited at the OTHER endpoint
      // (a genuine A→B→C drive-through). A spur/ramp/parallel excursion enters
      // and leaves at the SAME endpoint (A→B→A) and is NOT extended → its tiny
      // measured span falls under the coverage floor and is dropped. Longer ways
      // never use the topology path; they extend only when the measured span
      // already covers a majority of the way (a real end-to-end drive).
      if (enteredFromOtherWay && exitedToOtherWay) {
        final way = waysById[runWayId];
        if (way != null) {
          final len = _polylineLengthMeters(way.geometry);
          if (len > 0) {
            final measuredSpan = end - start;
            final coversMajority =
                measuredSpan >= len * kMinTraversedFractionForExtend;
            final isConnector = len <= kMaxPassThroughConnectorMeters &&
                _isPassThroughConnector(
                  connector: way,
                  entryWay: waysById[entryWayId],
                  exitWay: waysById[exitWayId],
                );
            if (isConnector || coversMajority) {
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
        runRawStart = metersFromWayStart;
        runRawEnd = metersFromWayStart;
        enteredFromOtherWay = false;
        entryWayId = null;
      } else if (s.wayId != runWayId) {
        // Different way: the previous run exited to another way → pass-through
        // eligible. Capture the way we're leaving (the entry way of the NEW
        // run) before flushing, and tell flush which way we're exiting to.
        final leavingWayId = runWayId;
        flush(exitedToOtherWay: true, exitWayId: s.wayId);
        runWayId = s.wayId;
        runRawStart = metersFromWayStart;
        runRawEnd = metersFromWayStart;
        enteredFromOtherWay = true;
        entryWayId = leavingWayId;
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
}

/// Which endpoint of a short connector way an adjacent (entry/exit) way is
/// attached to, per [HmmMatcher._attachedEnd].
enum _ConnectorEnd { start, end, none }
