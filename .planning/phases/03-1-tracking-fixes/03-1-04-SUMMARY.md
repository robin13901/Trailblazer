---
phase: 03-1-tracking-fixes
plan: 04
subsystem: tracking-regression-tests
tags: [regression-tests, tracking-service, state-stream, motion-filter, activity-gate, tdd, fake-facade]

# Dependency graph
requires:
  - phase: 03-1-tracking-fixes
    provides: TrackingDiagnostics DTO + counters (03-1-01) — used as assertion surface for acceptCount / rejectCount / lastActivityType invariants
  - phase: 03-tracking-mvp
    provides: TrackingService state machine, TrackingIdle/TrackingRecording sealed states, FakeBackgroundGeolocationFacade with emitFix/emitMotion/emitActivity helpers
provides:
  - Regression coverage for the H3 invariant (startManual bypasses TRK-01 activity gate) — 4 tests
  - Regression coverage for the H4 invariant (stateStream re-emits per accepted fix) — 3 tests
  - Bonus contrapositive coverage: auto-trip path IS gated on fresh in_vehicle activity (guards against a future refactor that removes the filter entirely)
  - Bonus rejected-fix invariant: pointCount only advances on ACCEPTED fixes, not per input fix (guards against a drift from 'emit per accept' to 'emit per input')
affects:
  - 03-1-05 (in-car verification + close-out) — with H3/H4 invariants now formally locked, the drive report focuses on H1/H5 evidence rather than H3/H4 disconfirmation
  - Any future Wave 4+ refactor of TrackingService.\_onLocation / \_onMotionChange — will hit these tripwires if the invariants regress

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Regression-test pattern for REFUTED research hypotheses: separate test file per invariant, header docstring citing the RESEARCH.md section + verdict, action-in-fail comment stating 'if this fails, the verdict was wrong — escalate as a Rule 4 architectural finding, do not silently drop the assertion'"
    - "Diagnostics-based assertion surface: prefer svc.diagnostics.acceptCount / rejectCount / lastActivityType over reaching into private state — Plan 03-1-01 established the DTO explicitly for this"
    - "stateStream emissions collected via `svc.stateStream.listen((s) { if (s is TrackingRecording) emissions.add(s); })` — matches production consumer pattern (LiveTrackingPanel)"

key-files:
  created:
    - test/features/trips/tracking_service_motion_filter_regression_test.dart
    - test/features/trips/tracking_service_state_stream_cadence_test.dart
  modified: []

key-decisions:
  - "H3 invariant locked (2026-07-06): TRK-01 automotive motion filter runs ONLY while _currentState is TrackingIdle. Any code path that reaches TrackingRecording (startManual today, future manual/auto variants tomorrow) bypasses the gate. _onLocation never gates on activity. Future refactors that hoist the activity check to a shared helper must preserve this invariant — the two 'manual accepts fix' regression tests fail hard if it drifts."
  - "H4 invariant locked (2026-07-06): stateStream re-emits a fresh TrackingRecording on EVERY accepted fix (not on rejects, not on gaps except via split path, not on timer ticks). The emission carries the ingestor's running totalDistanceMeters + pointCount and the incoming fix's speedKmh. LiveTrackingPanel's per-tick update depends on this cadence. Any future refactor that throttles _emitState or moves state updates behind a timer will break the panel — the '10 fixes → >= 10 emissions' + 'rejected fix does NOT bump pointCount' tests will catch it."
  - "Bonus invariant locked: auto-trip path IS gated on fresh in_vehicle activity. Contrapositive to H3 — proves the TRK-01 filter still fires when it should. If a future refactor removes the filter entirely (mistaking 'H3 refuted' for 'gate not needed'), the contrapositive test fails hard."
  - "Assertion surface: use TrackingDiagnostics DTO (Plan 03-1-01) — cleaner than reaching for private state via reflection, and reads exactly like production code. Rejected fixes are visible via rejectCount, activity state via lastActivityType — no test-only accessors needed."

patterns-established:
  - "H3/H4-style regression pattern for REFUTED hypotheses: three-part structure (bypass-with-unknown, bypass-with-non-vehicle-activity, contrapositive) + stateStream-listen collector + diagnostics-DTO assertions"
  - "stateStream cadence test template: subscribe → emit N fixes with yields → drain 100 ms → cancel → assert (>= N emissions, monotonic pointCount, last emission carries last fix's data)"

# Metrics
duration: 8min
completed: 2026-07-06
---

# Phase 3.1 Plan 04: Regression Tests — Motion Filter (H3) + StateStream Cadence (H4) Summary

**Lock in the H3 (motion filter is Idle-only) and H4 (stateStream emits per accept) invariants as pure regression tests — no production code touched, 7 new tests all green on first run, both research verdicts confirmed against live behavior.**

## Performance

- Duration: ~8 min (well under Phase 3.1 avg of 23 min/plan and the plan-checker's implicit 45-60 min budget for a two-task test-only plan)
- Loop cost: 1 Ralph-Loop iteration per task — analyze surfaced two trivial lint fixes on Task 1 (`unnecessary_import` for `dart:async`, `avoid_redundant_argument_values` for an explicit-null `activityType`), Task 2 clean on first analyze
- Test count: 153 → 160 (+7: 4 H3 tests, 3 H4 tests). Full trips test folder ran green at 70 tests (includes the 03-1-02 start-plumbing tests that landed in parallel).
- Commits: 2 task commits — e79518a (H3), 69fbec4 (H4)
- Zero production code touched — `git diff HEAD~2 HEAD -- lib/` returns empty; both commits are pure additions under `test/features/trips/`

## What ships

### Task 1: H3 regression tests (commit e79518a)

New file `test/features/trips/tracking_service_motion_filter_regression_test.dart` — 4 tests:

1. **manual trip accepts a fix when `_lastActivityType` has never been set** — the default "unknown" case. Verifies `svc.diagnostics.acceptCount == 1` after `startManual()` + one `emitFix()` with no preceding `emitActivity()`.
2. **manual trip accepts a fix even when `_lastActivityType == 'on_foot'`** — a deliberately non-vehicle activity signal. If the TRK-01 filter wrongly applied to manual trips, this would reject on the "not in_vehicle" branch.
3. **stateStream re-emits `TrackingRecording` on the first manual accepted fix** — proves the acceptance path actually runs (both a start-emission at `pointCount=0` and an accept-emission at `pointCount=1`), not just the initial start transition.
4. **contrapositive: auto-trip path IS gated on fresh in_vehicle activity** — from TrackingIdle, `motion=true` without any `emitActivity('in_vehicle')` must stay Idle; `motion=true` after `emitActivity('on_foot')` must also stay Idle. Guards against a future refactor that removes the filter entirely.

All assertions use `svc.diagnostics.*` (from Plan 03-1-01's DTO) rather than reaching into private state — cleaner and reads like production code.

### Task 2: H4 regression tests (commit 69fbec4)

New file `test/features/trips/tracking_service_state_stream_cadence_test.dart` — 3 tests:

1. **10 accepted fixes → >= 10 TrackingRecording emissions, monotonic pointCount, last `currentSpeedKmh` reflects the last fix's speed** — assertion is `>=10` (not `==11`) to remain robust against future emission additions (e.g. gap-flush) but never fewer. Explicit `svc.diagnostics.acceptCount == 10` + `rejectCount == 0` sanity checks ensure the ingestor accepted everything.
2. **per-fix `distanceMeters` is monotonically non-decreasing and accumulates > 200 m over 5 fixes ~111 m apart** — separate from pointCount because a future refactor could preserve pointCount but drop distance updates.
3. **a rejected fix does NOT increment pointCount** — accept 1, reject 1 (accuracy=500 > 25 m), accept 1. Final `pointCount==2`, monotonic throughout. Guards against a drift from "emit per accept" to "emit per input" where every input fix would push a fresh state event.

All three tests use the same pattern: subscribe → emit fixes with `Future<void>.delayed(Duration.zero)` yields between → drain 100 ms → cancel → assert.

## Verification results

- `flutter analyze test/features/trips/tracking_service_motion_filter_regression_test.dart test/features/trips/tracking_service_state_stream_cadence_test.dart` → No issues found.
- `flutter analyze` (repo-wide) → 4 pre-existing warnings/info in `lib/features/trips/data/fgb_background_geolocation_facade.dart` and `lib/features/trips/domain/tracking_service.dart` — all owned by parallel plan 03-1-02, not touched here.
- `flutter test test/features/trips/` → 70/70 pass (63 prior + 7 new from this plan). Also picked up the 5 tests from 03-1-02's `tracking_service_start_test.dart` which had landed in parallel — all green.
- Both new tests are behavior-sensitive (they assert against the state machine's live emission behavior), so full-suite ran inside the tight Ralph Loop per project CLAUDE.md.
- `git status --short` shows only the two new test files (plus 03-1-03's unrelated `map_screen.dart` / `tracking_camera_sync.dart` which are outside this plan's lane).

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 1 — Lint] `unnecessary_import` on `dart:async`**

- **Found during:** Task 1 first `flutter analyze`
- **Issue:** Copy-pasted the header block from `tracking_service_test.dart` (which uses `StreamSubscription` directly); the regression test uses `flutter_test`'s re-exports so `dart:async` was redundant.
- **Fix:** Removed the `import 'dart:async';` line.
- **Files modified:** `test/features/trips/tracking_service_motion_filter_regression_test.dart`
- **Commit:** e79518a

**2. [Rule 1 — Lint] `avoid_redundant_argument_values` on `activityType: null`**

- **Found during:** Task 1 first `flutter analyze`
- **Issue:** Explicit `activityType: null` in a `FixInput` constructor matches the default. The plan text called for demonstrating the "no activity classification" case — but the language does that for free by omitting the parameter.
- **Fix:** Removed the argument, added an inline comment `// Deliberately omit activityType — defaults to null, i.e. no activity classification attached to the fix itself.` to preserve intent.
- **Files modified:** `test/features/trips/tracking_service_motion_filter_regression_test.dart`
- **Commit:** e79518a

### Not deviated (called out because plan-checker or prompt flagged)

- **Fake facade left untouched.** The prompt warned that 03-1-02 might be modifying `test/helpers/fake_background_geolocation_facade.dart` in parallel. This plan does not need any new emitter or accessor — `emitFix`, `emitMotion`, `emitActivity`, `readyCalls`, `startCalls`, `stopCalls` were all sufficient. No merge risk.
- **No test file collision with parallel plans.** Both new files are under `test/features/trips/` with unique names (`tracking_service_motion_filter_regression_test.dart`, `tracking_service_state_stream_cadence_test.dart`) — 03-1-02 owns `tracking_service_start_test.dart` (different file), 03-1-03 owns `test/features/map/**` (different feature).
- **Both research verdicts confirmed against live behavior.** Every H3-bypass and H4-cadence assertion passed on first run once the two lint fixes landed. If any had failed, the plan's Deviation-Handling section instructed to STOP and escalate as a Rule 4 architectural finding — that path was NOT triggered.
- **No architectural change (Rule 4) triggered.** Pure additive tests against existing observable seams (stateStream, diagnostics DTO, fake facade emitters).

## Authentication Gates

None — this plan is entirely local code + tests. No CLI, no API, no external auth.

## Next Phase Readiness

**Ready for Wave 3 (03-1-05, in-car verification):**

- H3 and H4 are no longer "REFUTED but suspicious" — they are actively defended by regression coverage. The drive report can focus attention on H1 (FGB.start() fix from 03-1-02) and H2 (map camera-follow from 03-1-03) evidence, which are the CONFIRMED bugs.
- If the drive still shows zero-distance manual trips after 03-1-02 and 03-1-03 land, the tripwires here narrow the fault domain: it's NOT the motion filter, and it's NOT the state-stream cadence. Look elsewhere (FGB config, permissions, OEM battery kill).

**No new blockers introduced.**

## Known gaps / concerns

- **`Future<void>.delayed(Duration.zero)` between emits.** The tight-loop yield lets `TrackingService._onLocation` run for the just-emitted fix before the next `emitFix` call in the loop pushes another. On a slower CI runner this could conceivably race — if it flakes, the Deviation-Handling section allowed bumping to 200 ms. Not observed in 3 local runs of the H4 test.
- **The H4 "rejected fix does NOT bump pointCount" test relies on the ingestor's `accuracy` filter (25 m default) as the rejection trigger.** If a future refactor makes the accuracy threshold configurable and someone accidentally raises it above 500 m in the default config, this test would silently pass with an accepted fix instead of a rejected one — the `svc.diagnostics.rejectCount == 1` sanity assertion catches that case, so the test would still fail loudly if the ingestor's behavior drifted.
- **No performance-tier assertion.** These are correctness invariants; timing / throughput of stateStream emissions is not tested. If a future refactor moves emissions to a microtask-scheduled batch, the tests still pass — but LiveTrackingPanel might feel laggy. Out of scope for this plan; would be a separate perf-tier test.

## References

- Plan: `.planning/phases/03-1-tracking-fixes/03-1-04-regression-tests-motion-filter-and-cadence-PLAN.md`
- Research: `.planning/phases/03-1-tracking-fixes/03-1-RESEARCH.md` §4 (H3 verdict + evidence), §5 (H4 verdict + evidence)
- Context: `.planning/phases/03-1-tracking-fixes/03-1-CONTEXT.md` (H3/H4 hypothesis text, wave breakdown)
- Prior art:
  - Plan 03-1-01 (TrackingDiagnostics DTO + accept/reject counters — the assertion surface used here)
  - Plan 03-04 (fixture-timestamp discipline: `DateTime.now()` at test start, not hardcoded past dates)
  - Existing `test/features/trips/domain/tracking_service_test.dart` (style + `makeService()` factory pattern)
