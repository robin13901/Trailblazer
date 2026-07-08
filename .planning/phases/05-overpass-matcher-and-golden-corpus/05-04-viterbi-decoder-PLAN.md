---
id: 05-04
phase: 05-overpass-matcher-and-golden-corpus
plan: 04
type: execute
wave: 2
depends_on: [05-02, 05-03]
files_modified:
  - lib/features/matching/domain/gps_fix.dart
  - lib/features/matching/domain/viterbi_decoder.dart
  - lib/features/matching/domain/matched_step.dart
  - test/features/matching/domain/viterbi_decoder_test.dart
autonomous: true
requirements: [MMT-02, MMT-04, MMT-05, MMT-07]

must_haves:
  truths:
    - "`ViterbiDecoder.decode(List<GpsFix>, WaySegmentIndex)` returns a `List<MatchedStep?>` of the same length as the input, one entry per GPS fix; unmatched fixes yield `null` (never force-snapped) per MMT-05."
    - "Decoder works entirely in log-space; no `double.negativeInfinity` produced without a corresponding `null` output at that step (prevents `NaN` propagation)."
    - "Autobahn smear guard: when a fix's `speedKmh < 15` AND a candidate's `highwayClass` is one of {motorway, motorway_link, trunk, trunk_link}, that candidate's emission log-prob is penalized by `-log(1e6)` — the fix will only match to it if no other candidate exists (MMT-07)."
    - "Gap detection: when consecutive fixes have `Δt > 60 s`, the Viterbi state resets and a new sub-track begins; intervals before and after are independently valid."
    - "One-way respect: transitions between candidates on the same wayId are only scored if the projection-fraction delta agrees with the way's `oneway` direction (forward: fraction must be non-decreasing; backward: non-increasing; no: either)."
    - "Backpointer traceback works: given a 4-fix synthetic trace with a known correct sequence, `decode` returns the exact expected `(wayId, segIdx)` sequence."
    - "Lookahead ≥ 5: the beam width parameter is exposed as `kBeamWidth = 5` (top-5 candidates carried forward per fix per MMT-04); tests assert that dropping to `k=1` breaks a scenario that `k=5` solves."
  artifacts:
    - path: "lib/features/matching/domain/gps_fix.dart"
      provides: "GpsFix immutable value type (lat, lon, accuracyMeters, speedKmh, ts). Kept out of hmm_probability.dart for import discipline."
      min_lines: 40
    - path: "lib/features/matching/domain/matched_step.dart"
      provides: "MatchedStep (wayId, segIdx, projectionFraction, perpDistM, emissionLogP, direction, highwayClass)."
      min_lines: 40
    - path: "lib/features/matching/domain/viterbi_decoder.dart"
      provides: "Pure Viterbi HMM decoder over a WaySegmentIndex; adaptive radius, top-K beam, log-space, backpointer traceback, gap-detection, MMT-07 speed guard, one-way transition rule."
      min_lines: 220
    - path: "test/features/matching/domain/viterbi_decoder_test.dart"
      provides: "≥ 10 scenario tests: happy-path, gap, autobahn smear, one-way violation, single-fix trace, empty trace, k=1 vs k=5 correctness delta."
      min_lines: 200
  key_links:
    - from: "lib/features/matching/domain/viterbi_decoder.dart"
      to: "lib/features/matching/domain/hmm_probability.dart"
      via: "emissionLogProb + transitionLogProb + adaptiveRadiusMeters"
      pattern: "emissionLogProb|transitionLogProb|adaptiveRadiusMeters"
    - from: "lib/features/matching/domain/viterbi_decoder.dart"
      to: "lib/features/matching/domain/way_segment_index.dart"
      via: "queryTopK per fix"
      pattern: "queryTopK"
    - from: "lib/features/matching/domain/viterbi_decoder.dart"
      to: "lib/features/matching/domain/segment_geometry.dart"
      via: "perpDistanceToSegmentMeters + projectionFractionOnSegment"
      pattern: "perpDistanceToSegment|projectionFractionOnSegment"
    - from: "lib/features/trips/domain/haversine.dart"
      to: "lib/features/matching/domain/viterbi_decoder.dart"
      via: "great-circle distance between successive fixes for the transition denominator; route distance approximated as gc * 1.4"
      pattern: "haversineMeters"
---

## Goal

Ship the pure-Dart Viterbi HMM decoder — the algorithmic heart of the matcher. Given a list of `GpsFix` and a `WaySegmentIndex`, produce a `List<MatchedStep?>` (same length as input; nulls where confidence is too low). No I/O, no isolate, no Drift — testable with `dart test`.

This is the highest-complexity plan in Phase 5. Do not batch other work into it.

Resolves research §11 open questions:
- **#1 β = 1.0 default:** exposed as constructor param defaulting to `kTransitionBetaMeters` from 05-02.
- **#8 Gap detection:** yes — `Δt > 60 s` resets Viterbi state (constant `kGapThresholdSeconds`).
- **#6 direction:** decoder emits `'forward'` / `'backward'` only; `'both'` is a Phase 6 concern.

## Context

- Research §2 is the authoritative algorithm reference — read it before starting.
- Wave-1 outputs are the inputs: `emissionLogProb`, `transitionLogProb`, `adaptiveRadiusMeters`, `WaySegmentIndex`, `perpDistanceToSegmentMeters`, `projectionFractionOnSegment`.
- Great-circle distance for the transition denominator: reuse `lib/features/trips/domain/haversine.dart` (`haversineMeters`).
- **Route distance approximation:** without a routing engine, `route_dist ≈ great_circle × 1.4` per research §2 (standard Germany detour factor). This is MEDIUM-confidence — the golden corpus (05-08) will validate. Expose as `kRouteDetourFactor = 1.4` constant.
- **`GpsFix`** is a new domain type — deliberately NOT `TripPoint` (which is a Drift row type). The coordinator (05-07) maps `TripPoint` → `GpsFix` at the DB boundary. Keeps the decoder free of Drift dependencies.
- **`MatchedStep`** is the per-fix output — one row for each Viterbi decision. The matcher orchestrator (05-05) will collapse consecutive same-way MatchedSteps into `DrivenWayInterval` rows for the DAO.
- **MMT-07 speed guard:** when `fix.speedKmh < 15` AND the candidate segment's `highwayClass` is in `kHighClassHighwaysForSpeedGuard = {'motorway', 'motorway_link', 'trunk', 'trunk_link'}`, penalize emission by `-log(1e6) ≈ -13.8`. Do NOT hard-exclude — the penalty is large enough that any non-motorway candidate wins if it exists, but if there's genuinely nothing else, the motorway match wins over `null`.
- **One-way rule:** for a transition from `(waySegA)` to `(waySegB)` where `waySegA.wayId == waySegB.wayId`, check the sign of `(fractionB - fractionA)`:
  - `oneway == forward` → require `fractionB >= fractionA`; violation → `-log(1e6)`.
  - `oneway == backward` → require `fractionB <= fractionA`; violation → `-log(1e6)`.
  - `oneway == no` → no constraint.
  Cross-way transitions (different wayId) are unconstrained by direction here — spatially discontinuous jumps are already penalized by the transition-distance term.
- **Gap detection:** if `fixes[i].ts.difference(fixes[i-1].ts) > Duration(seconds: kGapThresholdSeconds)`, reset the Viterbi state at fix `i` (no predecessor considered — start a new sub-track). The pre-gap traceback finalizes on `i-1`; the post-gap track starts fresh.
- **Low-confidence drop:** at each fix, if the max emission log-prob among the top-K candidates is below `-log(0.001)` more than the running best, drop the fix (`null` output). This mirrors research §2's threshold.
- Constants live at the top of `viterbi_decoder.dart`. All are `const` — no magic numbers scattered in the body.

## Tasks

<task type="auto">
  <name>Task 1: GpsFix + MatchedStep value types</name>
  <files>
    lib/features/matching/domain/gps_fix.dart
    lib/features/matching/domain/matched_step.dart
  </files>
  <intent>Immutable value types that flow through the decoder; kept tiny so 05-05/05-06/05-07 don't need to re-derive them.</intent>
  <action>
    **`lib/features/matching/domain/gps_fix.dart`:**
    ```dart
    // Phase 5 (Plan 05-04): GpsFix — one GPS observation as consumed by the
    // Viterbi decoder. Deliberately decoupled from the Drift `TripPoint`
    // row so the matcher can be tested / isolate-shipped without dragging
    // Drift into pure-Dart code.

    import 'package:meta/meta.dart';

    @immutable
    class GpsFix {
      const GpsFix({
        required this.lat,
        required this.lon,
        required this.accuracyMeters,
        required this.speedKmh,
        required this.ts,
      });

      final double lat;
      final double lon;

      /// Horizontal accuracy in meters (HDOP-derived, from
      /// flutter_background_geolocation). Values <= 0 or NaN are treated as
      /// "unknown" downstream and default the emission sigma to
      /// `kEmissionSigmaMeters`.
      final double accuracyMeters;

      /// Speed in km/h; may be 0 for stationary fixes.
      final double speedKmh;

      final DateTime ts;

      @override
      String toString() =>
          'GpsFix($lat,$lon acc=${accuracyMeters}m spd=${speedKmh}km/h @$ts)';
    }
    ```

    **`lib/features/matching/domain/matched_step.dart`:**
    ```dart
    // Phase 5 (Plan 05-04): MatchedStep — one Viterbi decision per GPS fix.
    // Collapsed into DrivenWayInterval rows by the HmmMatcher orchestrator
    // (Plan 05-05).

    import 'package:auto_explore/features/matching/domain/way_candidate.dart';
    import 'package:meta/meta.dart';

    @immutable
    class MatchedStep {
      const MatchedStep({
        required this.wayId,
        required this.segIdx,
        required this.projectionFraction,
        required this.perpDistMeters,
        required this.emissionLogP,
        required this.direction,
        required this.highwayClass,
        required this.oneway,
      });

      final int wayId;
      final int segIdx;

      /// Fraction along the segment (0..1) where the GPS fix projects.
      final double projectionFraction;

      final double perpDistMeters;
      final double emissionLogP;

      /// 'forward' | 'backward'. Determined by the sign of the fraction delta
      /// against the prior step on the same wayId; forward on first step.
      final String direction;

      final String highwayClass;
      final OnewayDirection oneway;

      @override
      String toString() =>
          'MatchedStep(way=$wayId, seg=$segIdx, frac=${projectionFraction.toStringAsFixed(3)}, '
          'perp=${perpDistMeters.toStringAsFixed(1)}m, dir=$direction)';
    }
    ```

    No tests for these — pure data classes; equality isn't needed (structural comparison in tests is via field access on a specific known step).
  </action>
  <verify>
    ```bash
    flutter analyze
    ```
    Analyze clean.
  </verify>
  <done>Two value types compile clean; no Flutter or Drift imports.</done>
</task>

<task type="auto">
  <name>Task 2: ViterbiDecoder (log-space, top-K beam, backpointer traceback, gap detection, MMT-07 guard, one-way rule)</name>
  <files>
    lib/features/matching/domain/viterbi_decoder.dart
    test/features/matching/domain/viterbi_decoder_test.dart
  </files>
  <intent>The algorithmic core. ~220 lines. Testable end-to-end without I/O.</intent>
  <action>
    **`lib/features/matching/domain/viterbi_decoder.dart`:**

    Structure:
    ```dart
    // Phase 5 (Plan 05-04): Viterbi HMM decoder.
    //
    // Newson & Krumm (2009) HMM map-matching, tuned per this codebase:
    //   * Emission sigma: adaptive — max(kEmissionSigmaMeters, hDop/2).
    //   * Transition beta: kTransitionBetaMeters (1.0 m default).
    //   * Route distance ≈ great_circle * kRouteDetourFactor (1.4).
    //   * Top-K beam: kBeamWidth (5 per MMT-04).
    //   * Adaptive radius: adaptiveRadiusMeters(hDop) per fix (25..150 m).
    //   * Gap detection: Δt > kGapThresholdSeconds resets the state.
    //   * MMT-07 speed guard: motorway/trunk candidates penalized at
    //     speed < kSpeedGuardKmh.
    //   * One-way rule: same-wayId transitions must agree with oneway.
    //
    // Pure functional; no I/O; no state beyond the decode() call. Testable
    // with `dart test`.

    import 'dart:math' as math;
    import 'package:auto_explore/features/matching/domain/gps_fix.dart';
    import 'package:auto_explore/features/matching/domain/hmm_probability.dart';
    import 'package:auto_explore/features/matching/domain/matched_step.dart';
    import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
    import 'package:auto_explore/features/matching/domain/way_candidate.dart';
    import 'package:auto_explore/features/matching/domain/way_segment.dart';
    import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
    import 'package:auto_explore/features/trips/domain/haversine.dart';

    const int kBeamWidth = 5;
    const int kGapThresholdSeconds = 60;
    const double kSpeedGuardKmh = 15.0;
    const double kRouteDetourFactor = 1.4;
    const double kLowConfidenceDropLog = -6.907; // ln(0.001)
    const double kMotorwayPenaltyLog = -13.816;  // ln(1e-6)
    const double kOnewayViolationLog = -13.816;

    const Set<String> kHighClassHighwaysForSpeedGuard = {
      'motorway',
      'motorway_link',
      'trunk',
      'trunk_link',
    };

    class ViterbiDecoder {
      const ViterbiDecoder({
        this.betaMeters = kTransitionBetaMeters,
        this.beamWidth = kBeamWidth,
      });

      final double betaMeters;
      final int beamWidth;

      /// Decode a full GPS trace into a per-fix List<MatchedStep?>. `null`
      /// entries indicate low-confidence drops (MMT-05).
      List<MatchedStep?> decode(List<GpsFix> fixes, WaySegmentIndex index) {
        if (fixes.isEmpty) return const [];
        // ... trellis[step] = list of _State (candidate + logProb + backptr)
        // ... run forward pass
        // ... run backward traceback
        // ... emit List<MatchedStep?> matching input length
      }
    }

    // Private state carrier for the trellis.
    class _State {
      _State({
        required this.segment,
        required this.projectionFraction,
        required this.perpDistMeters,
        required this.emissionLogP,
        required this.totalLogP,
        required this.backptr,
      });
      final WaySegment segment;
      final double projectionFraction;
      final double perpDistMeters;
      final double emissionLogP;
      double totalLogP;
      int? backptr; // index into trellis[step - 1]
    }
    ```

    **Forward pass algorithm (pseudocode inside `decode`):**
    ```
    trellis = List<List<_State>>()
    for step, fix in enumerate(fixes):
      sigma = max(kEmissionSigmaMeters, fix.accuracyMeters / 2)
      if sigma.isNaN or sigma <= 0: sigma = kEmissionSigmaMeters
      radius = adaptiveRadiusMeters(fix.accuracyMeters)
      candidates = index.queryTopK(lat=fix.lat, lon=fix.lon, radiusMeters=radius, k=beamWidth)

      states = []
      for seg in candidates:
        perp = perpDistanceToSegmentMeters(fix, seg endpoints)
        frac = projectionFractionOnSegment(fix, seg endpoints)
        emit = emissionLogProb(perp, sigma)
        if fix.speedKmh < kSpeedGuardKmh and seg.highwayClass in kHighClassHighwaysForSpeedGuard:
          emit += kMotorwayPenaltyLog
        states.add(_State(seg, frac, perp, emit, totalLogP=emit, backptr=null))

      if states is empty:
        # No candidate in radius; drop this fix.
        trellis.add([]); continue

      # Low-confidence drop: if best emission < max_ever_seen - 6.9, drop.
      # (Compares within-step; also compares to prior best if any state exists.)
      bestEmit = max(s.emissionLogP for s in states)
      if bestEmit < kLowConfidenceDropLog:  # emission itself absurdly low
        trellis.add([]); continue

      if step == 0 or _priorStepIsGap(fixes, step) or trellis[step-1] is empty:
        # No predecessors — start fresh; totalLogP = emit only.
        trellis.add(states); continue

      # Transition step: for each state s in states, find best predecessor p.
      gc = haversineMeters(fixes[step-1], fixes[step])
      routeDist = gc * kRouteDetourFactor
      for s in states:
        bestP = -infinity
        bestIdx = null
        for pIdx, pState in enumerate(trellis[step-1]):
          trans = transitionLogProb(routeDist, gc, betaMeters)
          # One-way rule (same wayId transitions):
          if pState.segment.wayId == s.segment.wayId:
            dfrac = s.projectionFraction - pState.projectionFraction
            if pState.segment.oneway == forward and dfrac < 0: trans += kOnewayViolationLog
            if pState.segment.oneway == backward and dfrac > 0: trans += kOnewayViolationLog
          total = pState.totalLogP + trans + s.emissionLogP
          if total > bestP: bestP = total; bestIdx = pIdx
        s.totalLogP = bestP
        s.backptr = bestIdx
      trellis.add(states)
    ```

    **Backward traceback — per-sub-track walk:**

    Sub-tracks are contiguous non-empty runs of `trellis` separated by (a) empty
    steps (low-confidence drops / no candidates in radius) or (b) gap-reset
    boundaries where the state's `backptr` is `null` even though the prior
    step is non-empty. Each sub-track's Viterbi state array is independent —
    walk each one separately, tail-first, and write MatchedSteps into `result`.

    ```
    result = List<MatchedStep?>.filled(fixes.length, null)

    # 1. Identify sub-track boundaries.
    # A sub-track is a maximal contiguous run [lo..hi] where:
    #   * trellis[i] is non-empty for every i in [lo..hi], AND
    #   * for i in [lo+1..hi], at least one state in trellis[i] has a
    #     non-null backptr (i.e. a real transition, not a gap-reset start).
    # Equivalently: start a new sub-track at any step where either trellis[step]
    # is the first non-empty step, or every state in trellis[step] has backptr
    # == null (this is the gap-reset marker).

    subTracks = []               # List of (lo, hi) inclusive pairs
    curLo = null
    for step in range(len(fixes)):
      if trellis[step] is empty:
        if curLo is not null: subTracks.append((curLo, step-1)); curLo = null
        continue
      if curLo is null:
        curLo = step
        continue
      # Check gap-reset: if every state at this step has backptr == null,
      # this step starts a new sub-track.
      if all(state.backptr is null for state in trellis[step]):
        subTracks.append((curLo, step-1))
        curLo = step
    if curLo is not null: subTracks.append((curLo, len(fixes)-1))

    # 2. Walk each sub-track independently.
    for (lo, hi) in subTracks:
      bestIdx = argmax(range(len(trellis[hi])), key=lambda i: trellis[hi][i].totalLogP)
      cur = bestIdx
      s = hi
      priorStep = null   # for _directionFrom on next iteration
      # Local pass writes in reverse; direction resolved in a second forward
      # pass over the sub-track since 'forward'/'backward' depends on the
      # PRIOR step (chronologically earlier) on the same wayId.
      chain = []         # (step, stateIdx) pairs, tail-first
      while s >= lo and cur is not null:
        chain.append((s, cur))
        cur = trellis[s][cur].backptr
        s -= 1
      # Reverse the chain to walk chronologically for direction resolution.
      chain.reverse()
      priorStep = null
      for (step, stateIdx) in chain:
        state = trellis[step][stateIdx]
        direction = _directionFrom(state, priorStep)
        result[step] = MatchedStep(
          wayId=state.segment.wayId,
          segIdx=state.segment.segIdx,
          projectionFraction=state.projectionFraction,
          perpDistMeters=state.perpDistMeters,
          emissionLogP=state.emissionLogP,
          direction=direction,
          highwayClass=state.segment.highwayClass,
          oneway=state.segment.oneway,
        )
        priorStep = state
    ```

    Rationale: (a) per-sub-track traceback keeps earlier sub-tracks'
    matches from being clobbered when the tail of a later sub-track has a
    higher total-logP; (b) walking chronologically after backptr-chase
    lets `_directionFrom` see the actual prior step on the same wayId (not
    the forward-pass `_State`); (c) any step whose backptr chain doesn't
    reach `lo` (defensive — should not happen if sub-track detection is
    correct) leaves `result[step]` as null, which is the correct
    low-confidence output.

    **`_directionFrom(state, priorSameWayFraction)`:**
    - `null` prior → default 'forward'.
    - Same wayId prior with `state.fraction > prior.fraction` → 'forward'.
    - Same wayId prior with `state.fraction < prior.fraction` → 'backward'.
    - Different wayId prior → default 'forward'.

    **Tests (`test/features/matching/domain/viterbi_decoder_test.dart`)** — ≥ 10 scenarios:
    Build synthetic ways + fixes inline (no fixtures needed) — see e.g. `List<WayCandidate>` with two east-west ways.

    1. `empty trace → empty result`.
    2. `single-fix trace with 1 candidate in radius → 1 MatchedStep`.
    3. `single-fix trace with 0 candidates → [null]`.
    4. `straight 5-fix trace along one way → 5 MatchedSteps on the same wayId, all forward`.
    5. `MMT-07 speed guard: 5 fixes on a service road parallel to a motorway, all at speed 5 km/h → all fixes match to the service road, NOT the motorway`.
    6. `MMT-07 without guard control: same 5 fixes but at speed 60 km/h → decoder is free to pick either; test asserts speeds > 15 km/h don't apply the penalty (assert emission log-P is not shifted by ≈ -13.8)`.
    7. `Gap detection: 10 fixes with a 90-second gap in the middle → decoder produces two separate sub-tracks; the fix immediately after the gap has null backptr`.
    8. `Low-confidence drop: 5 fixes, all 500 m from any way in the index → all 5 outputs null`.
    9. `One-way violation: 3 fixes going backwards along a oneway=forward way → second and third fixes still match forward on the way (violation penalty forces different candidate or leaves it as-is; assert the decoder does not silently return forward direction for a backward-motion trace when a backward-oneway alternative way exists)`.
    10. `Deterministic output: two runs of decode on the same input produce identical MatchedStep lists (test structural equality via toString comparison)`.
    11. `Beam width matters: build a scenario with 6 candidates where the correct answer is candidate #6 by emission but candidate #5 becomes right after transition. Assert kBeamWidth=5 solves it and kBeamWidth=1 fails`. (This validates MMT-04's top-5 requirement.)
    12. `Result length equals input length`.

    Use small hand-built way lists (2-4 ways of 3-5 nodes each). This makes tests fast and debuggable.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/domain/viterbi_decoder_test.dart
    ```
    Analyze clean; all 12 scenario tests green.
  </verify>
  <done>Decoder produces correct per-fix output on all 12 scenarios; MMT-04 (top-5), MMT-05 (drop, not force-snap), and MMT-07 (speed guard + lookahead) demonstrably work.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- All 12 decoder tests green.
- `viterbi_decoder.dart` imports NO Flutter, NO Drift, NO isolate. Verify with grep.
- Constants (`kBeamWidth = 5`, `kGapThresholdSeconds = 60`, `kSpeedGuardKmh = 15.0`, `kRouteDetourFactor = 1.4`) are at file top and referenced (not hard-coded) throughout.

## Ralph Loop

- Tight loop: `flutter analyze`.
- Behavior-sensitive (highest of any plan in Phase 5): `flutter test test/features/matching/domain/viterbi_decoder_test.dart` on every change.
- If a test regresses, do NOT tune the algorithm to make it pass — first re-read research §2 to confirm the algorithm is still Newson-Krumm. Test scenarios encode the requirements; algorithm changes to fit tests are usually the wrong move.

## Deviations

- If the one-way transition rule proves too aggressive (e.g. causes valid same-way transitions to be penalized due to floating-point noise on `projectionFraction`), soften the check with an epsilon: `abs(dfrac) > 0.001` before enforcing.
- If the gap threshold of 60 s fires spuriously in tests (e.g. because synthetic ts spacing is off), expose it as a constructor param and let the test set a lower value. The 60 s default remains.
- If backpointer traceback becomes complex due to the gap-reset logic, factor `_tracebackFromStep(int startStep)` into a private helper and iterate over sub-tracks explicitly.

## Commit Strategy

- Task 1 commit: `feat(05-04): GpsFix + MatchedStep value types`
- Task 2 commit: `feat(05-04): Viterbi HMM decoder (log-space, top-K, gap+speed+oneway guards)`
