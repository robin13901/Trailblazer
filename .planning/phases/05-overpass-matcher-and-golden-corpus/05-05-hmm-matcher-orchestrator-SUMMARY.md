---
id: 05-05
phase: 05-overpass-matcher-and-golden-corpus
plan: 05
subsystem: matching-engine
tags: [dart, hmm, map-matching, interval-merging, viterbi, domain, pure-dart]
requires: [05-01, 05-02, 05-03, 05-04]
provides:
  - HmmMatcher.match(fixes, ways) → MatchResult
  - DrivenWayIntervalDraft (tripless DAO companion)
  - MatchResult (steps + intervals + counts)
affects: [05-06, 05-07]
tech-stack:
  added: []
  patterns:
    - "Stateless orchestrator: build index → decode → collapse intervals"
    - "min/max swap for start/end meters; direction from net delta"
    - "Cumulative segmentLengthMeters + fraction for meter accumulation"
key-files:
  created:
    - lib/features/matching/domain/driven_way_interval_draft.dart
    - lib/features/matching/domain/match_result.dart
    - lib/features/matching/domain/hmm_matcher.dart
    - test/features/matching/domain/hmm_matcher_test.dart
  modified: []
decisions:
  - "Direction-flip intra-way is NOT split — single interval with net-delta direction (Plan 05-05 §Deviations). Phase 6 aggregation concern."
  - "runRawStart = meters at first step; runRawEnd = meters at last step. start/end stored as min/max. Direction = sign(rawEnd - rawStart)."
  - "prefer_const_declarations lint: _mPerDegLon in test file uses // ignore comment because float multiplication is not const."
metrics:
  duration: ~15 min
  completed: 2026-07-08
---

# Phase 5 Plan 05: HmmMatcher Orchestrator Summary

**One-liner:** Stateless `HmmMatcher.match(fixes, ways)` orchestrator: builds WaySegmentIndex, runs ViterbiDecoder, collapses MatchedSteps into DrivenWayIntervalDraft rows via cumulative-meter accumulation and direction-from-net-delta interval merging.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | DrivenWayIntervalDraft + MatchResult value types | c4c1a3e | driven_way_interval_draft.dart, match_result.dart |
| 2 | HmmMatcher orchestrator + interval merging + tests | f82745a | hmm_matcher.dart, hmm_matcher_test.dart |

## What Was Built

### Task 1: Value Types

**`DrivenWayIntervalDraft`** — Drift-free tripless companion of the `driven_way_intervals` DAO row:
- `wayId: int` — OSM way id
- `startMeters: double` — distance from way's first node to start of interval (always ≤ endMeters)
- `endMeters: double` — distance to end of interval
- `direction: String` — `'forward'` or `'backward'`
- No Drift import; isolate-safe for Plan 05-06

**`MatchResult`** — Full output of one `HmmMatcher.match` call:
- `steps: List<MatchedStep?>` — per-fix Viterbi decisions (null = dropped)
- `intervals: List<DrivenWayIntervalDraft>` — collapsed intervals for DAO
- `matchedFixCount / droppedFixCount: int` — for logging
- `isEmpty: bool` getter

### Task 2: HmmMatcher Orchestrator

**`HmmMatcher`** — Stateless glue layer:
1. Builds `WaySegmentIndex.buildFromWays(ways)` from the candidate list
2. Creates `ViterbiDecoder(betaMeters, beamWidth)` and calls `decode(fixes, index)`
3. Calls `_collapseToIntervals(steps, waysById)` to produce `DrivenWayIntervalDraft` rows

**Interval merging algorithm (`_collapseToIntervals`):**
- Iterates `List<MatchedStep?>` linearly, maintaining `runWayId`, `runRawStart`, `runRawEnd`
- **Same wayId**: extend run by updating `runRawEnd`
- **Different wayId**: flush current interval, start new run
- **null step**: flush current interval (confidence gap)
- At flush: `startMeters = min(rawStart, rawEnd)`, `endMeters = max(rawStart, rawEnd)`, `direction = rawEnd >= rawStart ? 'forward' : 'backward'`

**Meter accumulation (`_metersFromWayStart`):**
```
acc = sum(segmentLengthMeters for segments 0..segIdx-1)
    + step.projectionFraction * segmentLengthMeters(segment at segIdx)
```
Returns 0 when way geometry is missing or has < 2 points.

**Test coverage (10 scenarios):**
1. Empty fixes → empty MatchResult (0/0/0)
2. Empty ways → all null steps, no intervals
3. Single fix → 1 interval, start==end, direction=forward
4. Forward 5-fix trace → 1 interval, start < end, direction=forward
5. Reversed 5-fix trace → 1 interval, start < end, direction=backward
6. 5+5 fix trace (way A then way B) → 2 intervals, one per way
7. Confidence gap (fix 500 m off road) → ≥ 2 intervals after gap
8. Direction flip mid-way → no crash; start ≤ end; valid direction
9. Determinism: identical inputs → identical toString outputs
10. matchedFixCount + droppedFixCount == fixes.length (3 cases)

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| Intra-way direction flip NOT split | Plan 05-05 §Deviations: single interval with net-delta direction; Phase 6 aggregation splits if needed |
| `runRawStart` = first fix, `runRawEnd` = last fix | Net delta determines direction; not position-by-position |
| `prefer_int_literals` for all `0.0` / `25.0` constants | Very good analysis rule; Dart coerces int literals in double contexts |
| `_mPerDegLon` uses `// ignore: prefer_const_declarations` in test | Float multiplication is not const; the variable IS effectively constant |

## Deviations from Plan

None — plan executed exactly as written.

The direction-flip test (#8) was noted in plan §Deviations as potentially ambiguous. The behavior that landed: a single interval spanning the full traversed range with direction derived from the net first-to-last delta. Test encodes this behavior as the invariant (no crash, start ≤ end, direction is forward or backward).

## Success Criteria Verification

- [x] `flutter analyze` clean (lib/ + test/ — 0 issues)
- [x] All Wave-2 tests (05-04 + 05-05) green: 94/94 in `test/features/matching/domain/`
- [x] `hmm_matcher.dart` has no Drift, Flutter, or isolate import (grep-verified)
- [x] `DrivenWayIntervalDraft` has no `import 'package:drift'` (grep-verified)
- [x] `HmmMatcher.match` returns `(steps: List<MatchedStep?>, intervals: List<DrivenWayIntervalDraft>)`
- [x] Interval merging: same-way-same-direction collapses; null/wayId-change starts new
- [x] `start_meters`/`end_meters` computed via cumulative `segmentLengthMeters`

## Next Phase Readiness

Plan 05-06 (matcher isolate) can consume `HmmMatcher` directly — it has no Drift/Flutter imports and is `const`-constructible. The isolate entry point will call `HmmMatcher().match(fixes, ways)` and send back the `MatchResult` via `SendPort`.

Plan 05-07 (coordinator) will:
1. Map `TripPoint` rows → `List<GpsFix>`
2. Call `WayCandidateSource.fetchWaysInBbox` to get `List<WayCandidate>`
3. Call `HmmMatcher().match` (directly or via isolate)
4. Attach `tripId` to each `DrivenWayIntervalDraft`
5. Call `DrivenWayIntervalsDao.insertBatch`
