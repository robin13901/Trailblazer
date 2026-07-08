---
phase: 05-overpass-matcher-and-golden-corpus
plan: "04"
subsystem: matching
tags: [viterbi, hmm, dart, map-matching, log-space, beam-search, gps]

requires:
  - phase: 05-02
    provides: emissionLogProb, transitionLogProb, adaptiveRadiusMeters, kEmissionSigmaMeters, kTransitionBetaMeters, kBaseRadiusMeters, kMaxRadiusMeters
  - phase: 05-03
    provides: WaySegment, WaySegmentIndex (rbush R-Tree, queryTopK)
  - phase: 04-13
    provides: WayCandidate, OnewayDirection, kfzHighwayClasses
  - phase: haversine
    provides: haversineMeters (great-circle distance for transition denominator)

provides:
  - "GpsFix: immutable GPS observation value type (lat, lon, accuracyMeters, speedKmh, ts); decoupled from Drift TripPoint"
  - "MatchedStep: per-fix Viterbi output (wayId, segIdx, projectionFraction, perpDistMeters, emissionLogP, direction, highwayClass, oneway)"
  - "ViterbiDecoder.decode(List<GpsFix>, WaySegmentIndex) → List<MatchedStep?> (same length as input; null = unmatched)"
  - "Log-space forward pass + backpointer traceback with per-sub-track independence"
  - "Gap detection (Δt > 60 s), MMT-07 speed guard (-ln(1e6) on motorway/trunk at < 15 km/h), one-way constraint"
  - "22 scenario tests: 12 named scenarios + 10 constants"

affects:
  - 05-05 (HmmMatcher orchestrator — collapses MatchedStep to DrivenWayInterval)
  - 05-06 (matcher isolate — uses ViterbiDecoder and WaySegmentIndex)
  - 05-07 (coordinator — maps TripPoint → GpsFix at DB boundary)
  - 05-08 (golden corpus — validates decoder accuracy)

tech-stack:
  added: []
  patterns:
    - "Log-space Viterbi HMM: forward pass with top-K beam, backward traceback per sub-track"
    - "Adaptive emission sigma: max(kEmissionSigmaMeters, accuracyMeters/2)"
    - "Route distance approximation: great_circle × kRouteDetourFactor (1.4)"
    - "Direction via segIdx comparison then fraction (not fraction alone — resets 0→1 per segment)"
    - "Sub-track detection: gap-reset markers are all-null-backptr trellis steps"

key-files:
  created:
    - lib/features/matching/domain/gps_fix.dart
    - lib/features/matching/domain/matched_step.dart
    - lib/features/matching/domain/viterbi_decoder.dart
    - test/features/matching/domain/viterbi_decoder_test.dart
  modified: []

key-decisions:
  - "kBeamWidth=5 per MMT-04: top-5 candidates carried forward per fix"
  - "kGapThresholdSeconds=60: gap resets Viterbi state, starts a new sub-track"
  - "kRouteDetourFactor=1.4: standard Germany detour factor (research §2)"
  - "kMotorwayPenaltyLog=-ln(1e6): MMT-07 speed guard for motorway/trunk at < 15 km/h"
  - "kOnewayViolationLog=-ln(1e6): same magnitude as motorway penalty"
  - "Direction uses segIdx first, then projectionFraction within the same segment"
  - "Sub-track traceback is per-sub-track (not a single global traceback)"
  - "gapThresholdSeconds exposed as ViterbiDecoder constructor param for test override"

patterns-established:
  - "Viterbi trellis as List<List<_State>>: outer = steps, inner = beam candidates"
  - "Sub-track detection via all-null-backptr predicate on trellis cells"
  - "Chain reversal (backptr → lo, then reverse) for chronological direction resolution"
  - "Epsilon 0.001 on dfrac before applying oneway violation penalty (floating-point guard)"

duration: 13min
completed: 2026-07-08
---

# Phase 5 Plan 04: Viterbi HMM Decoder Summary

**Pure log-space Viterbi HMM map-matcher over WaySegmentIndex: top-5 beam, gap detection, MMT-07 motorway speed guard, one-way constraint, backpointer traceback with per-sub-track independence; 22 tests all green**

## Performance

- **Duration:** ~13 min
- **Started:** 2026-07-08T20:14:02Z
- **Completed:** 2026-07-08T20:27:16Z
- **Tasks:** 2
- **Files created:** 4

## Accomplishments

- `GpsFix` and `MatchedStep` immutable value types ship fully decoupled from Drift — the decoder has zero Flutter/Drift imports, enabling isolate deployment (Plan 05-06)
- `ViterbiDecoder.decode` returns `List<MatchedStep?>` of exactly the same length as the input GPS trace; `null` entries are unmatched drops (never force-snapped) per MMT-05
- All required algorithmic features ship: log-space forward pass, adaptive emission sigma, top-K beam (k=5), gap detection at 60 s threshold, MMT-07 motorway/trunk speed guard (−13.8 nats at < 15 km/h), one-way constraint with epsilon guard, and per-sub-track backpointer traceback with correct chronological direction labeling
- 22 tests pass: 12 named scenarios (empty trace, single fix with/without candidates, 5-fix forward trace, speed guard with/without penalty, gap detection, low-confidence drop, one-way violation, determinism, k=1 vs k=5 beam, result-length invariant) plus 10 constant assertions

## Task Commits

1. **Task 1: GpsFix + MatchedStep value types** — `c9f946f` (feat)
2. **Task 2: Viterbi HMM decoder + 22 scenario tests** — `b2588c8` (feat)

## Files Created

- `lib/features/matching/domain/gps_fix.dart` (45 lines) — Immutable GPS observation; decoupled from Drift TripPoint
- `lib/features/matching/domain/matched_step.dart` (71 lines) — Per-fix Viterbi output; consumed by HmmMatcher orchestrator (05-05)
- `lib/features/matching/domain/viterbi_decoder.dart` (408 lines) — Pure-Dart decoder; all constants at file top; no Flutter/Drift imports
- `test/features/matching/domain/viterbi_decoder_test.dart` (590 lines) — 22 scenario tests; all passing

## Decisions Made

1. **Direction uses `segIdx` first, then `projectionFraction`** — comparing fractions alone across segment boundaries gives wrong results because fraction resets 0→1 on each new segment. Using `segIdx` change as the primary signal, then fraction within the same segment, correctly identifies forward vs backward motion.

2. **`gapThresholdSeconds` exposed as constructor parameter** — per plan §Deviations guidance, the 60 s default is exposed as an override so tests can use smaller intervals without waiting real seconds. Default preserved.

3. **Sub-track traceback is per-sub-track, not global** — each `(lo, hi)` pair is traced back independently. This prevents a later sub-track's high `totalLogP` from clobbering earlier sub-track matches.

4. **Oneway epsilon guard = 0.001** — per plan §Deviations, `abs(dfrac) > 0.001` before enforcing the oneway violation penalty prevents floating-point noise from triggering the penalty on zero-motion steps on the same segment.

5. **`kBeamWidth=5` is the default `beamWidth` constructor param** — the constant and the param are linked by default value; tests with `beamWidth: 5` trigger `avoid_redundant_argument_values`, so k=5 tests use `const ViterbiDecoder()`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Direction labeling was wrong across segment boundaries**

- **Found during:** Task 2 — Test 4 failure (`'backward'` when `'forward'` expected on a 5-fix forward trace)
- **Issue:** `_directionFrom` compared `projectionFraction` only; when moving from segment 0 (fraction 0.8) to segment 1 (fraction 0.2), the delta is negative → 'backward' even though motion is forward along the way.
- **Fix:** Compare `segIdx` first (higher = forward, lower = backward), then `projectionFraction` within the same segment.
- **Files modified:** `lib/features/matching/domain/viterbi_decoder.dart`
- **Committed in:** b2588c8 (Task 2 commit, after fix during Ralph tight loop)

---

**Total deviations:** 1 auto-fixed (Rule 1 — bug)
**Impact on plan:** Required for correct direction labeling on all multi-segment traces. No scope creep.

## Issues Encountered

- `comment_references` lint fired on `[ViterbiDecoder]`, `[kEmissionSigmaMeters]`, `[wayId]`, and `[segIdx]` in doc comments — same pattern as STATE Plan 04-13. Fixed by wrapping affected names in backticks. Pattern is now established for all Phase 5 domain docs.
- `prefer_int_literals` and `prefer_const_declarations` lints required several iterations on the test file — GpsFix's `DateTime` field makes it non-const-constructible; `ViterbiDecoder(beamWidth: 5)` is redundant when default is 5.

## Next Phase Readiness

- `ViterbiDecoder.decode` is ready for consumption by the HmmMatcher orchestrator (Plan 05-05)
- `GpsFix` is the input type; Plan 05-07's coordinator will map `TripPoint → GpsFix` at the DB boundary
- `MatchedStep` is the output type; Plan 05-05 will collapse consecutive same-wayId steps into `DrivenWayInterval` rows
- No blockers. `flutter analyze` clean; all 362 project tests pass.

---
*Phase: 05-overpass-matcher-and-golden-corpus*
*Completed: 2026-07-08*
