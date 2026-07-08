---
id: 05-07
phase: 05-overpass-matcher-and-golden-corpus
plan: 07
subsystem: matching-pipeline
tags: [trip-match-coordinator, matcher-isolate, driven-way-intervals, retention-sweep, app-lifecycle]
completed: 2026-07-08
duration: ~35min

dependency-graph:
  requires: [05-01, 05-05, 05-06, 04-15, 04-14, 03-01]
  provides:
    - TripMatchCoordinator (onTripReadyForMatching, cancel, processPending)
    - TripsDao.transitionToMatched / listPendingTrips / listPointsForTrip
    - TripsRepository.transitionToMatched
    - tripMatchCoordinatorProvider (Riverpod plain Provider)
    - app.dart resume hook: drainQueue + processPending + sweepRawGpsRetention
  affects: [06-trip-review-and-coverage-layer]

tech-stack:
  added: []
  patterns:
    - fire-and-forget unawaited coordinator calls from TripRoadFetchCoordinator
    - fake MatcherIsolate subclass for synchronous test control
    - DrivenWayIntervalsCompanion.insert with Value(tripId) attachment

key-files:
  created:
    - lib/features/matching/data/trip_match_coordinator.dart
    - test/features/matching/data/trip_match_coordinator_test.dart
  modified:
    - lib/features/trips/data/trips_dao.dart
    - lib/features/trips/data/trips_repository.dart
    - lib/features/matching/data/matching_providers.dart
    - lib/features/matching/data/trip_road_fetch_coordinator.dart
    - lib/app.dart
    - test/features/trips/presentation/tracking_notifier_test.dart

decisions:
  - "TripMatchCoordinator injected into TripRoadFetchCoordinator via optional constructor param (nullable for back-compat with 141 pre-Phase-5 tests)"
  - "match coordinator fires unawaited after both online path and drainQueue success path in 04-15 coordinator"
  - "empty ways / null bbox / no points all take the fast-path to matched (degenerate trip is not a blocker)"
  - "MatcherCancelledException leaves trip in pending (retryable on next resume); other errors also leave in pending"
  - "tracking_notifier_test expected status updated pending → matched: Phase 5 empty-ways path transitions immediately"
  - "DrivenWayIntervalsDao.insertBatch called with tripId=Value(tripId) attached by coordinator before DB write"
  - "processPending FIFO order via TripsDao.listPendingTrips ordered by endedAt ASC"

metrics:
  tasks: 3/3
  tests-added: 6
  tests-total: 383
  deviations: 1
---

# Phase 5 Plan 07: Trip Match Coordinator Summary

**One-liner:** End-to-end trip pipeline wired — TripMatchCoordinator fetches ways, submits to MatcherIsolate, inserts DrivenWayIntervals, transitions to matched; app resume hook drives all three periodic methods.

## What Was Built

### Task 1: TripsDao + TripsRepository additions
Added three new DAO methods and one repository wrapper to support the Phase 5 match flow:
- `TripsDao.transitionToMatched(int tripId)` — flip trip status to `matched`, idempotent
- `TripsDao.listPendingTrips()` — all `pending` trips ordered by `endedAt ASC` (FIFO)
- `TripsDao.listPointsForTrip(int tripId)` — all `trip_points` ordered by `seq ASC`
- `TripsRepository.transitionToMatched(int tripId)` — `Result<void>` wrapper per domain contract

### Task 2: TripMatchCoordinator + provider wiring + 04-15 hook edit
**`TripMatchCoordinator`** orchestrates the complete pending → matched pipeline:
1. `await isolate.start()` (idempotent warm-up)
2. Load trip row for stored bbox — null bbox → `matched` with 0 intervals
3. `source.fetchWaysInBbox(throwOnError: false)` — empty result → `matched` with 0 intervals
4. `dao.listPointsForTrip` → convert TripPoint → GpsFix (accuracyMeters: null → NaN, speedKmh: null → 0)
5. Empty points → `matched` with 0 intervals
6. `isolate.match(tripId, fixes, ways)` → on success: `_writeIntervals` + `transitionToMatched`
7. `MatcherCancelledException` → leave in `pending` (retryable); other errors → leave in `pending`

`cancel(tripId)` calls `isolate.cancel(tripId)` then `intervalsDao.deleteByTrip(tripId)`.

`processPending()` calls `listPendingTrips()` and serially processes each trip (FIFO).

**`matching_providers.dart`** extended:
- `tripMatchCoordinatorProvider` added (plain `Provider<TripMatchCoordinator>`)
- `tripRoadFetchCoordinatorProvider` updated to pass `matchCoordinator: ref.watch(tripMatchCoordinatorProvider)`

**`trip_road_fetch_coordinator.dart`** extended:
- Optional `TripMatchCoordinator? matchCoordinator` constructor param
- `unawaited(_matchCoordinator?.onTripReadyForMatching(tripId))` called after BOTH `transitionToPending` sites (empty-bbox path + online success path in `onTripStopped`, and drain success path in `drainQueue`)

**6 tests:** happy-path (intervals written + matched), empty-ways, no-points, null-bbox, cancel (intervals deleted), processPending (3 trips all matched FIFO).

### Task 3: app.dart resume hook
Extended `didChangeAppLifecycleState.resumed` to invoke all three periodic methods:
```dart
unawaited(ref.read(tripRoadFetchCoordinatorProvider).drainQueue());
unawaited(ref.read(tripMatchCoordinatorProvider).processPending());
unawaited(ref.read(tripsRepositoryProvider).sweepRawGpsRetention());
```
All three are fire-and-forget; each logs its own errors. Ordering is semantically independent.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] tracking_notifier_test expected status updated**

- **Found during:** Task 3 full test suite run
- **Issue:** `tracking_notifier_test.dart` expected trip status `pending` after `stopActive()`; with Phase 5 coordinator wired, the empty-ways path (`_NoopWayCandidateSource`) now immediately transitions the trip to `matched`
- **Fix:** Updated test assertion and description: `pending` → `matched`; added comment explaining Phase 5 empty-ways path behavior
- **Files modified:** `test/features/trips/presentation/tracking_notifier_test.dart`
- **Commit:** `0a9d0f6`

## State Machine Clarification

Phase 5 final state machine: `recording → pendingRoadData → pending → matched`

- `recording → pendingRoadData`: TripRoadFetchCoordinator.onTripStopped entry point
- `pendingRoadData → pending`: fetch coordinator after successful Overpass cache-fill
- `pending → matched`: TripMatchCoordinator after successful HMM match + interval insert
- `matched → confirmed`: Phase 6 territory (user review)

## Next Phase Readiness

Phase 6 (trip review + coverage layer) can safely read:
- `driven_way_intervals` rows keyed by `tripId` + `wayId`
- `trips.status == matched` as the trigger for "ready to show in review UI"
- `TripMatchCoordinator.cancel(tripId)` as the cleanup path for user-deleted trips

No new schema version needed — Phase 5 operates entirely on the v3 schema.
