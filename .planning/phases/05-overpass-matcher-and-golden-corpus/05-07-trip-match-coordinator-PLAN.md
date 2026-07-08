---
id: 05-07
phase: 05-overpass-matcher-and-golden-corpus
plan: 07
type: execute
wave: 5
depends_on: [05-01, 05-05, 05-06]
files_modified:
  - lib/features/matching/data/trip_match_coordinator.dart
  - lib/features/matching/data/matching_providers.dart
  - lib/features/trips/data/trips_dao.dart
  - lib/features/trips/data/trips_repository.dart
  - lib/app.dart
  - lib/features/matching/data/trip_road_fetch_coordinator.dart
  - test/features/matching/data/trip_match_coordinator_test.dart
autonomous: true
requirements: [MMT-01, MMT-03, MMT-05, MMT-06, MMT-08, MMT-10]

must_haves:
  truths:
    - "`TripMatchCoordinator.onTripReadyForMatching(tripId)` (invoked on `pending` transition from 04-15's coordinator) fetches ways via `WayCandidateSource`, loads `trip_points` from `TripsDao`, converts them to `List<GpsFix>`, submits a `MatchJob` to `MatcherIsolate`, and on success writes the returned `DrivenWayIntervalDraft` list to `DrivenWayIntervalsDao` before transitioning the trip to `TripStatus.matched`."
    - "State machine: pending → (matching in flight) → matched (Phase 5). No new intermediate state introduced. `pending → matched` is the Phase 5 boundary; `matched → confirmed` is Phase 6."
    - "On `TripMatchCoordinator.cancel(tripId)` — invoked when the user deletes an in-flight trip — the coordinator (1) calls `matcherIsolate.cancel(tripId)`, (2) deletes any DrivenWayIntervals already written via `DrivenWayIntervalsDao.deleteByTrip`, (3) allows the trip deletion to proceed via CASCADE on `trip_points`."
    - "On isolate error or empty result, the trip stays in `pending` (retryable on next resume); the coordinator logs but does not throw."
    - "`app.dart`'s `AppLifecycleState.resumed` hook now (a) drains 04-15's fetch queue AND (b) invokes `TripMatchCoordinator.processPending()` to pick up any `pending` trips that arrived without a matching completion + (c) invokes the 30-day retention sweep from 05-01."
    - "`TripsDao.listPendingTrips()` returns all trips with `status == pending`, ordered by `endedAt ASC` for FIFO fairness."
    - "GpsFix.speedKmh: use `trip_points.speedKmh` when non-null, else 0. accuracyMeters: use `trip_points.accuracyMeters` when non-null, else NaN (decoder handles NaN → default sigma)."
  artifacts:
    - path: "lib/features/matching/data/trip_match_coordinator.dart"
      provides: "TripMatchCoordinator (onTripReadyForMatching, cancel, processPending); wires WayCandidateSource + MatcherIsolate + DAOs + retention sweep."
      min_lines: 180
    - path: "test/features/matching/data/trip_match_coordinator_test.dart"
      provides: "≥ 6 tests: happy-path pending→matched, cancel-during-match, empty-way-fetch, no-fixes-in-trip, processPending-multi-trip, retention-sweep-on-resume."
      min_lines: 200
  key_links:
    - from: "lib/features/matching/data/trip_match_coordinator.dart"
      to: "lib/features/matching/data/matcher_isolate.dart"
      via: "matcherIsolate.match({tripId, fixes, ways}) → MatchResult"
      pattern: "matcherIsolate\\.match|MatcherIsolate"
    - from: "lib/features/matching/data/trip_match_coordinator.dart"
      to: "lib/core/db/daos/driven_way_intervals_dao.dart"
      via: "DrivenWayIntervalsDao.insertBatch(companions with tripId attached)"
      pattern: "insertBatch|drivenWayIntervalsDao"
    - from: "lib/app.dart"
      to: "lib/features/matching/data/trip_match_coordinator.dart"
      via: "AppLifecycleState.resumed → coordinator.processPending() + tripsRepository.sweepRawGpsRetention()"
      pattern: "processPending|sweepRawGpsRetention"
    - from: "lib/features/matching/data/trip_match_coordinator.dart"
      to: "lib/features/trips/data/trips_repository.dart"
      via: "transitionToMatched(tripId) after successful insertBatch"
      pattern: "transitionToMatched"
---

## Goal

Wire everything together. When a trip lands in `TripStatus.pending` (either from 04-15's online path or its drain path), invoke the matcher: fetch ways, load fixes, submit to the isolate, write intervals, transition to `matched`. Add the app-resume hook for pickup + retention sweep.

Resolves research §11 open questions:
- **#4 State-machine call:** Phase 5 goes `pending → matched` after successful match. Phase 6 will handle `matched → confirmed`. No new state needed. `TripStatus.matched` already exists in the enum (`lib/features/trips/domain/trip_status.dart:19`).
- **#3 Retention sweep:** invoked on resume via `TripsRepository.sweepRawGpsRetention` from 05-01. No WorkManager.

## Context

- **05-01** ships the DAO + retention sweep repository method.
- **05-05** ships the pure matcher and `DrivenWayIntervalDraft`.
- **05-06** ships `MatcherIsolate` and `matcherIsolateProvider`.
- **04-15** already invokes `TripRoadFetchCoordinator.onTripStopped` from `TrackingService`. When that coordinator transitions a trip to `pending`, that's the Phase-5 entry point.
- Two triggering paths for the match coordinator:
  1. **Online path (04-15 online):** `TripRoadFetchCoordinator.onTripStopped` → transitions to `pending` after successful fetch → then the Phase 5 coordinator picks up the trip. Coupling can be:
     - a) 04-15 explicitly calls a Phase 5 hook after `transitionToPending`, OR
     - b) Phase 5 polls via `processPending()` at every relevant lifecycle event.
     **Recommended (b):** loose coupling. The match coordinator does not need a callback from 04-15. Instead, `TrackingService` (or the 04-15 coordinator, since it's the state-transition owner) invokes `TripMatchCoordinator.onTripReadyForMatching(tripId)` immediately after `transitionToPending`, AND `processPending()` fires on resume as a safety net.
- **04-15 hook edit:** In `lib/features/matching/data/trip_road_fetch_coordinator.dart`, after each `_repository.transitionToPending(...)` call (there are 2 — one in `onTripStopped`'s online success path, one in `drainQueue`'s success branch), also invoke `matchCoordinator.onTripReadyForMatching(tripId)`. Inject `TripMatchCoordinator` via constructor + provider. This creates a plan-cross-dependency; add `05-06` and `05-01` to the providers module list.
- **Repository additions:** `TripsRepository.transitionToMatched(int tripId) → Result<void>` and a `TripsDao.transitionToMatched(int tripId)` sibling to the existing `transitionToPending`.
- **TripPoint → GpsFix conversion:** `TripPoint(lat, lon, ts, speedKmh?, accuracyMeters?)` → `GpsFix(lat, lon, ts, speedKmh: speedKmh ?? 0, accuracyMeters: accuracyMeters ?? double.nan)`.
- **Bbox lookup for ways:** use the trip's stored `bboxMinLat/bboxMinLon/bboxMaxLat/bboxMaxLon` from `trips_table.dart` (populated by `closeTrip`). Do NOT recompute from `trip_points` — the trip row already has it.
- **Empty-fixes protection:** if `trip_points.count == 0` for the trip, skip matching, log a warning, transition to `matched` anyway (an empty trip is degenerate but should not clog `pending`).
- **Empty-ways protection:** if `WayCandidateSource.fetchWaysInBbox` returns `[]`, skip matching, log, transition to `matched` with zero intervals. (Cache miss on offline; nothing to match against.)
- **Provider ordering:** `matcherIsolateProvider` (05-06) is already registered; add `tripMatchCoordinatorProvider` alongside `tripRoadFetchCoordinatorProvider`.

## Tasks

<task type="auto">
  <name>Task 1: TripsDao.transitionToMatched + listPendingTrips + repository wrapper</name>
  <files>
    lib/features/trips/data/trips_dao.dart
    lib/features/trips/data/trips_repository.dart
  </files>
  <intent>Two DAO methods + Result-wrapped repository entries.</intent>
  <action>
    **`trips_dao.dart` — add after existing `transitionToPending`:**
    ```dart
    /// Flip [tripId] to [TripStatus.matched] once the matcher has written
    /// its intervals. Idempotent.
    Future<void> transitionToMatched(int tripId) =>
        (update(trips)..where((t) => t.id.equals(tripId))).write(
          const TripsCompanion(status: Value(TripStatus.matched)),
        );

    /// All trips with `status == TripStatus.pending`, ordered by `endedAt`
    /// ascending (oldest ready-to-match trip first). Used by the Phase 5
    /// match coordinator on app resume.
    Future<List<Trip>> listPendingTrips() =>
        (select(trips)
              ..where((t) => t.status.equalsValue(TripStatus.pending))
              ..orderBy([(t) => OrderingTerm.asc(t.endedAt)]))
            .get();

    /// All trip_points for [tripId], ordered by `seq`. Returned as plain
    /// Drift rows; conversion to GpsFix happens on the caller side.
    Future<List<TripPoint>> listPointsForTrip(int tripId) =>
        (select(tripPoints)
              ..where((p) => p.tripId.equals(tripId))
              ..orderBy([(p) => OrderingTerm.asc(p.seq)]))
            .get();
    ```

    **`trips_repository.dart` — add Result wrappers:**
    ```dart
    Future<Result<void>> transitionToMatched(int tripId) async {
      try {
        await _dao.transitionToMatched(tripId);
        return const Ok(null);
        // ignore: avoid_catches_without_on_clauses
      } catch (e, st) {
        return Err(DomainError.wrap(e, st));
      }
    }
    ```
    (No repository wrapper needed for `listPendingTrips` / `listPointsForTrip` — the coordinator reads directly from DAO; those are internal-flow reads, not domain-boundary writes. Matches the pattern in existing repository where reads bypass Result.)
  </action>
  <verify>
    ```bash
    flutter analyze
    ```
    Analyze clean.
  </verify>
  <done>Two new DAO methods + one repository method compile clean.</done>
</task>

<task type="auto">
  <name>Task 2: TripMatchCoordinator + provider wiring + 04-15 hook edit</name>
  <files>
    lib/features/matching/data/trip_match_coordinator.dart
    lib/features/matching/data/matching_providers.dart
    lib/features/matching/data/trip_road_fetch_coordinator.dart
    test/features/matching/data/trip_match_coordinator_test.dart
  </files>
  <intent>The Phase 5 orchestrator — DAO reads, isolate submit, DAO writes, state transitions.</intent>
  <action>
    **`lib/features/matching/data/trip_match_coordinator.dart`:**
    ```dart
    // Phase 5 (Plan 05-07): TripMatchCoordinator — orchestrates the
    // pending-trip → matched-trip pipeline. Fetches ways via
    // WayCandidateSource, submits to MatcherIsolate, writes intervals via
    // DrivenWayIntervalsDao, transitions state via TripsRepository.

    import 'package:auto_explore/core/db/app_database.dart';
    import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
    import 'package:auto_explore/features/matching/data/match_job.dart';
    import 'package:auto_explore/features/matching/data/matcher_isolate.dart';
    import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
    import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
    import 'package:auto_explore/features/matching/domain/gps_fix.dart';
    import 'package:auto_explore/features/matching/domain/match_result.dart';
    import 'package:auto_explore/features/trips/data/trips_dao.dart';
    import 'package:auto_explore/features/trips/data/trips_repository.dart';
    import 'package:drift/drift.dart' show Value;
    import 'package:logging/logging.dart';

    class TripMatchCoordinator {
      TripMatchCoordinator({
        required WayCandidateSource source,
        required MatcherIsolate matcherIsolate,
        required TripsDao tripsDao,
        required TripsRepository tripsRepository,
        required DrivenWayIntervalsDao intervalsDao,
      })  : _source = source,
            _isolate = matcherIsolate,
            _tripsDao = tripsDao,
            _tripsRepository = tripsRepository,
            _intervalsDao = intervalsDao;

      final WayCandidateSource _source;
      final MatcherIsolate _isolate;
      final TripsDao _tripsDao;
      final TripsRepository _tripsRepository;
      final DrivenWayIntervalsDao _intervalsDao;
      final _log = Logger('trip_match_coordinator');

      /// Invoked by 04-15's TripRoadFetchCoordinator immediately after a trip
      /// transitions from `pendingRoadData` to `pending`.
      Future<void> onTripReadyForMatching(int tripId) async {
        _log.info('trip $tripId ready for matching');
        await _isolate.start(); // idempotent

        final tripRow = await (_tripsDao.select(_tripsDao.trips)
              ..where((t) => t.id.equals(tripId)))
            .getSingleOrNull();
        if (tripRow == null) {
          _log.warning('trip $tripId not found — skipping match');
          return;
        }
        if (tripRow.bboxMinLat == null ||
            tripRow.bboxMinLon == null ||
            tripRow.bboxMaxLat == null ||
            tripRow.bboxMaxLon == null) {
          _log.info('trip $tripId has null bbox — marking matched with 0 intervals');
          await _tripsRepository.transitionToMatched(tripId);
          return;
        }

        final ways = await _source.fetchWaysInBbox(
          minLat: tripRow.bboxMinLat!,
          minLon: tripRow.bboxMinLon!,
          maxLat: tripRow.bboxMaxLat!,
          maxLon: tripRow.bboxMaxLon!,
          throwOnError: false,
        );
        if (ways.isEmpty) {
          _log.warning('trip $tripId has no ways in bbox — marking matched with 0 intervals');
          await _tripsRepository.transitionToMatched(tripId);
          return;
        }

        final points = await _tripsDao.listPointsForTrip(tripId);
        if (points.isEmpty) {
          _log.warning('trip $tripId has no points — marking matched');
          await _tripsRepository.transitionToMatched(tripId);
          return;
        }
        final fixes = points
            .map((p) => GpsFix(
                  lat: p.lat,
                  lon: p.lon,
                  accuracyMeters: p.accuracyMeters ?? double.nan,
                  speedKmh: p.speedKmh ?? 0.0,
                  ts: p.ts,
                ))
            .toList(growable: false);

        try {
          final result = await _isolate.match(
            tripId: tripId,
            fixes: fixes,
            ways: ways,
          );
          await _writeIntervals(tripId, result.intervals);
          await _tripsRepository.transitionToMatched(tripId);
          _log.info(
            'trip $tripId matched: ${result.intervals.length} intervals, '
            '${result.matchedFixCount} matched fixes, '
            '${result.droppedFixCount} dropped',
          );
        } on MatcherCancelledException {
          _log.info('trip $tripId matching cancelled');
        } on Object catch (e, st) {
          _log.warning('trip $tripId matching failed: $e', e, st);
          // Leave trip in `pending` — resume hook will retry.
        }
      }

      Future<void> _writeIntervals(
        int tripId,
        List<DrivenWayIntervalDraft> drafts,
      ) async {
        if (drafts.isEmpty) return;
        final companions = drafts
            .map((d) => DrivenWayIntervalsCompanion.insert(
                  wayId: d.wayId,
                  tripId: Value(tripId),
                  startMeters: d.startMeters,
                  endMeters: d.endMeters,
                  direction: Value(d.direction),
                ))
            .toList(growable: false);
        await _intervalsDao.insertBatch(companions);
      }

      /// Invoked when the user deletes an in-flight trip. Cancels the isolate
      /// job (best-effort) and deletes any intervals already written. The
      /// trip row itself is deleted by the caller (CASCADE on trip_points).
      Future<void> cancel(int tripId) async {
        _log.info('cancel matching for trip $tripId');
        _isolate.cancel(tripId);
        await _intervalsDao.deleteByTrip(tripId);
      }

      /// Called on app resume to pick up any trips that arrived at `pending`
      /// while the isolate wasn't running (e.g. app killed mid-match).
      Future<void> processPending() async {
        final pending = await _tripsDao.listPendingTrips();
        _log.fine('processPending: ${pending.length} trips');
        for (final trip in pending) {
          await onTripReadyForMatching(trip.id);
        }
      }
    }
    ```

    **`matching_providers.dart` addition (after `matcherIsolateProvider`):**
    ```dart
    /// Phase 5 (Plan 05-07): coordinator wiring pending trips into the
    /// matcher isolate and DAO writes.
    final tripMatchCoordinatorProvider = Provider<TripMatchCoordinator>((ref) {
      return TripMatchCoordinator(
        source: ref.watch(wayCandidateSourceProvider),
        matcherIsolate: ref.watch(matcherIsolateProvider),
        tripsDao: ref.watch(appDatabaseProvider).tripsDao,  // add tripsDao getter if absent
        tripsRepository: ref.watch(tripsRepositoryProvider),
        intervalsDao: ref.watch(appDatabaseProvider).drivenWayIntervalsDao,
      );
    });
    ```
    Imports: `TripMatchCoordinator`, `TripsDao`.
    Note: `appDatabaseProvider` currently exposes `.overpassWayCacheDao`, `.pendingRoadFetchesDao`. Add a `.tripsDao` getter to `AppDatabase` if not already present — it should be, since Drift auto-generates a getter for each `daos:` entry. `TripsDao` is currently NOT in the `daos:` list (it's a hand-rolled DatabaseAccessor in `lib/features/trips/data/`). Either (a) add `TripsDao` to the daos list, or (b) construct it inline: `TripsDao(ref.watch(appDatabaseProvider))`. **Recommendation (b):** construct inline in the provider — matches the existing `TripsRepository` provider pattern, which does the same.

    **`trip_road_fetch_coordinator.dart` edits:** Inject `TripMatchCoordinator? matchCoordinator` as an optional constructor param (nullable to avoid breaking existing tests). After BOTH calls to `_repository.transitionToPending(tripId)`, invoke `unawaited(matchCoordinator?.onTripReadyForMatching(tripId))`. Do NOT await — the fetch coordinator's SLA is "return quickly"; matching happens in the background.

    **Provider wiring for the 04-15 coordinator:** update `tripRoadFetchCoordinatorProvider` in `matching_providers.dart` to pass `matchCoordinator: ref.watch(tripMatchCoordinatorProvider)`.

    **Tests (`test/features/matching/data/trip_match_coordinator_test.dart`)** — ≥ 6 scenarios:
    1. `onTripReadyForMatching happy path: trip with bbox + points + ways → intervals written, trip → matched`. Use `FixtureWayCandidateSource`, in-memory DB, real `MatcherIsolate`.
    2. `onTripReadyForMatching with empty ways → trip → matched, 0 intervals written`.
    3. `onTripReadyForMatching with empty trip_points → trip → matched, 0 intervals written`.
    4. `onTripReadyForMatching with null bbox → trip → matched, 0 intervals written`.
    5. `cancel deletes any intervals already written`. Seed 2 intervals for tripId=1; call cancel(1); assert both gone.
    6. `processPending processes all pending trips in FIFO order`. Seed 3 pending trips; assert all 3 transition to matched after processPending().
  </action>
  <verify>
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    flutter analyze
    flutter test test/features/matching/data/trip_match_coordinator_test.dart
    flutter test test/features/matching/data/trip_road_fetch_coordinator_test.dart  # regression check on 04-15
    ```
    Analyze clean; all new tests green; 04-15 tests still green.
  </verify>
  <done>Coordinator round-trips pending → matched successfully; cancel path deletes intervals; processPending picks up FIFO.</done>
</task>

<task type="auto">
  <name>Task 3: Wire processPending + retention sweep into app.dart resume hook</name>
  <files>
    lib/app.dart
  </files>
  <intent>Extend the existing `didChangeAppLifecycleState.resumed` block from 04-15.</intent>
  <action>
    Current `app.dart` resume block:
    ```dart
    void didChangeAppLifecycleState(AppLifecycleState state) {
      super.didChangeAppLifecycleState(state);
      if (state == AppLifecycleState.resumed) {
        unawaited(ref.read(tripRoadFetchCoordinatorProvider).drainQueue());
      }
    }
    ```

    Extend to invoke, in order:
    1. `unawaited(ref.read(tripRoadFetchCoordinatorProvider).drainQueue())` — existing (04-15).
    2. `unawaited(ref.read(tripMatchCoordinatorProvider).processPending())` — Phase 5 pickup.
    3. `unawaited(ref.read(tripsRepositoryProvider).sweepRawGpsRetention())` — 30-day sweep (MMT-10).

    Add `import` for `tripsRepositoryProvider` if not already present.

    All three are `unawaited` — they run in parallel; each logs its own errors. Ordering does not matter semantically (a drain-in-progress trip will land in `pending` and be picked up by the next `processPending` call on the next resume).

    **No test change required** — `app.dart` is the composition root; the coordinators are unit-tested independently. Grep-verify the three lines are present:
    ```bash
    grep -c "drainQueue\|processPending\|sweepRawGpsRetention" lib/app.dart
    ```
    Should return 3 (one match per line).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test  # full suite — smoke check
    ```
    Analyze clean; full test suite green.
  </verify>
  <done>All three resume-hook methods invoked from AppLifecycleState.resumed; grep -c returns 3.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- All ~6 new tests + existing 04-15 tests green.
- `app.dart` resume block invokes all three periodic methods.
- Grep-verify: `grep -rn tripMatchCoordinatorProvider lib/` shows at least the provider def and `app.dart` reference.
- No new schema version — build_runner regenerates `.g.dart` only.

## Ralph Loop

- Tight loop: `flutter analyze`.
- Behavior-sensitive (touches DB, isolate, and app lifecycle): `flutter test` after each task.

## Deviations

- If `TripsDao` cannot expose `.trips` and `.select()` from outside the class (Drift generates protected accessors in some cases), replace the inline `select(trips)..where(...)` with a new `TripsDao.getTripById(int)` helper and call that.
- If the resume hook's three `unawaited` calls trigger CI test flakiness (some ProviderContainers time out), guard the block behind `if (!kDebugMode || _resumeHookEnabled)` and expose a test seam.

## Commit Strategy

- Task 1 commit: `feat(05-07): TripsDao transitionToMatched + listPendingTrips + listPointsForTrip`
- Task 2 commit: `feat(05-07): TripMatchCoordinator + isolate wiring + 04-15 hook edit`
- Task 3 commit: `feat(05-07): app.dart resume — processPending + retention sweep`
