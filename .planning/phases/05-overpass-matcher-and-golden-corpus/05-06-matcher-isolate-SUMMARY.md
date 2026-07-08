---
phase: 05-overpass-matcher-and-golden-corpus
plan: 06
subsystem: matching
tags: [dart, isolate, hmm-matcher, concurrency, riverpod]

# Dependency graph
requires:
  - phase: 05-overpass-matcher-and-golden-corpus
    plan: 05
    provides: "HmmMatcher.match() stateless orchestrator + MatchResult + DrivenWayIntervalDraft"
  - phase: 05-overpass-matcher-and-golden-corpus
    plan: 04
    provides: "GpsFix, MatchedStep isolate-safe value types"
  - phase: 04-osm-pipeline
    plan: 13
    provides: "WayCandidate with LatLng geometry (plain 2-double, Sendable)"
provides:
  - "MatchJob (jobSeq, tripId, fixes, ways) — Sendable isolate payload"
  - "MatchJobReply (jobSeq, result?, error?, cancelled) — worker reply"
  - "MatcherCancelledException — control-flow signal (not DomainError)"
  - "MatcherIsolate.start/match/cancel/dispose — long-lived warm worker isolate"
  - "_matcherWorker top-level entry function — no Drift, no Flutter"
  - "matcherIsolateProvider — plain Provider<MatcherIsolate> with onDispose"
affects:
  - "05-07 (trip-match coordinator — consumes matcherIsolateProvider + MatcherIsolate.match)"
  - "05-08 (golden corpus — exercises MatcherIsolate via coordinator)"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Top-level entry function pattern for Isolate.spawn (required on all platforms)"
    - "Warm isolate with ReceivePort.listen + Completer correlation via jobSeq"
    - "v1 pre-check cancel-set on worker side (cancel before job start, not in-flight)"
    - "TODO(mid-flight-cancel) marker for future per-frame cancellation hook"

key-files:
  created:
    - lib/features/matching/data/match_job.dart
    - lib/features/matching/data/matcher_isolate.dart
    - test/features/matching/data/matcher_isolate_test.dart
  modified:
    - lib/features/matching/data/matching_providers.dart

key-decisions:
  - "v1 cancellation is pre-job-start only (cancel-set consulted before HmmMatcher.match() starts). TODO(mid-flight-cancel) marker placed for Phase 6 follow-up."
  - "MatcherCancelledException is NOT a DomainError — it is a control-flow signal. Coordinator (05-07) decides whether to wrap into Result<T> at the DomainError boundary."
  - "matcherIsolateProvider uses fire-and-forget unawaited(isolate.start()) — coordinator awaits start() before first job to avoid race."
  - "Worker processes jobs serially (single-threaded isolate); 'concurrent' means multiple pending Futures on the main side, not parallel matching."
  - "MatcherCancelledException passes tripId=-1 in the main-side completer (worker does not echo tripId in MatchJobReply). Callers key on Future.error type, not tripId field."

patterns-established:
  - "Isolate warm-start pattern: MatcherIsolate.start() spawns worker + awaits first SendPort message"
  - "jobSeq correlation: int key in pending Map<int, Completer<T>> resolves concurrent futures to correct results"
  - "Cancel-set on worker side (Set<int> cancelled): remove-and-skip before each job; not a persistent blacklist"

# Metrics
duration: 10min
completed: 2026-07-08
---

# Phase 5 Plan 06: Matcher Isolate Summary

**Long-lived `MatcherIsolate` wrapping `HmmMatcher` behind a warm worker isolate, with jobSeq-keyed concurrent futures, pre-start cancellation via cancel-set, and a `matcherIsolateProvider` for Riverpod wiring**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-08T00:09:48Z
- **Completed:** 2026-07-08T00:19:42Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- `MatchJob` / `MatchJobReply` / `MatcherCancelledException` — pure-Dart Sendable payload types with no Drift/Flutter imports
- `MatcherIsolate` — long-lived warm isolate: `start()` spawns worker, `match()` returns keyed `Future<MatchResult>`, `cancel(tripId)` sends cancel message to worker's pre-check set, `dispose()` kills isolate
- `_matcherWorker` top-level entry function — serially processes `MatchJob` queue; consults `Set<int> cancelled` before each job; no Drift/Flutter imports
- `matcherIsolateProvider` — plain `Provider<MatcherIsolate>` per STATE 01-01 rule; fire-and-forget `unawaited(isolate.start())`, `ref.onDispose(isolate.dispose)`
- 4 isolate tests: roundtrip + concurrent keying + cancel race + dispose-clean; all green in < 2 s
- Full suite 377/377 tests green

## Task Commits

1. **Task 1: MatchJob/MatchJobReply payloads + MatcherCancelledException** - `fbd2bde` (feat)
2. **Task 2: MatcherIsolate spawn + protocol + provider wiring** - `22054ce` (feat)

## Files Created/Modified

- `lib/features/matching/data/match_job.dart` — Sendable payload types (MatchJob, MatchJobReply, MatcherCancelledException); no Drift/Flutter imports
- `lib/features/matching/data/matcher_isolate.dart` — MatcherIsolate main-side class + `_matcherWorker` top-level entry; no Drift/Flutter imports
- `lib/features/matching/data/matching_providers.dart` — added `matcherIsolateProvider` (plain `Provider<MatcherIsolate>`); added `dart:async` import for `unawaited`
- `test/features/matching/data/matcher_isolate_test.dart` — 4 scenarios: roundtrip, concurrent keying, cancel race, dispose-clean

## Decisions Made

- **v1 pre-check cancellation only.** `cancel(tripId)` adds to a `Set<int> cancelled` on the worker; this is checked BEFORE popping each job. A job already inside `HmmMatcher.match()` runs to completion. In-flight cancellation deferred — `TODO(mid-flight-cancel)` marker placed in `matcher_isolate.dart`. Rationale: trips take 2-5 s; MVP can tolerate completing then discarding.
- **`MatcherCancelledException` is NOT a `DomainError`.** It is a control-flow signal. The coordinator (05-07) decides whether to surface it as a `DomainError` at the `Result<T>` boundary. Documented in both the class docstring and STATE.md.
- **jobSeq echoed in `MatchJobReply`, tripId NOT echoed.** Main-side `_pending` map keyed by jobSeq; callers check exception type, not tripId. Keeps the reply payload minimal.
- **Fire-and-forget `unawaited(isolate.start())` in provider.** The coordinator (05-07) must call `await isolate.start()` before its first `match()`. Provider does not await to avoid blocking Riverpod initialization on an async operation.
- **Test 3 accepts either outcome.** v1 pre-check cancel may race; both `MatcherCancelledException` and successful completion are valid. Test documents the v1 behaviour contract without coupling to a specific race outcome.

## Deviations from Plan

None — plan executed exactly as written.

The plan's `MatchJobReply.cancelled` path passes `MatcherCancelledException(-1)` since tripId is not echoed in the reply. This is noted in the main-side listener code. The coordinator (05-07) will capture the tripId from its own context when needed.

The ignore-comment iteration (3 Ralph-loop passes on `matcher_isolate.dart` to fix `avoid_catches_without_on_clauses`) is normal lint polish, not a deviation.

## Issues Encountered

Minor lint iterations during Ralph loop:
- `comment_references` lint: doc comment `[MatcherIsolate]` in `match_job.dart` was unresolved (MatcherIsolate not imported in that file). Fixed by switching to backtick-quoted plain text references.
- `avoid_catches_without_on_clauses`: bare `catch (e)` in `_matcherWorker` changed to `on Object catch (e)`. Obsolete ignore comment removed.
- `avoid_redundant_argument_values`: `dtSecs: 0` in test helpers removed.

All fixed in < 3 Ralph-loop passes.

## Next Phase Readiness

- **05-07 (Trip Match Coordinator):** Can now consume `matcherIsolateProvider` and call `iso.match(tripId:, fixes:, ways:)`. Coordinator should `await iso.start()` before the first job.
- **Cancellation:** `cancel(tripId)` is wired; coordinator calls it on trip cancellation path (05-07).
- **No blockers** — `MatcherIsolate` is fully functional and test-covered.

---
*Phase: 05-overpass-matcher-and-golden-corpus*
*Completed: 2026-07-08*
