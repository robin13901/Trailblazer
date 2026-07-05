---
phase: 03-tracking-mvp
plan: 04
subsystem: tracking
tags: [tracking-service, riverpod, notifier, background-geolocation, dwell-timer, automotive-filter, trip-recording, tdd]

# Dependency graph
requires:
  - phase: 03-tracking-mvp
    plan: 01
    provides: TripsRepository + TripPointsCompanion + appDatabaseProvider + tripsRepositoryProvider
  - phase: 03-tracking-mvp
    plan: 02
    provides: TripFixIngestor + TripFixBatcher + TripPointsSink + TrackingState + TripPoint DTO
  - phase: 03-tracking-mvp
    plan: 03
    provides: BackgroundGeolocationFacade interface + FgbBackgroundGeolocationFacade + backgroundGeolocationFacadeProvider
provides:
  - TripsRepositoryPointsSink adapter (Drift ↔ domain seam)
  - TrackingService — orchestrator with manual/auto lifecycle + TRK-01 automotive filter + dwell/resume timers
  - TripFixIngestor public totalDistanceMeters + pointCount getters (additive)
  - FakeBackgroundGeolocationFacade enhanced with emitFix/emitMotion/emitActivity + state tracking
  - TrackingNotifier<TrackingState> Riverpod adapter (trackingStateProvider)
  - trackingServiceProvider + tripsRepositoryPointsSinkProvider
  - main.dart: ProviderContainer + UncontrolledProviderScope + facade.ready() at boot
affects:
  - 03-06 (FAB morph reads trackingStateProvider, calls startManual/stopActive)
  - 03-07 (phase verification: all tracking lifecycle e2e)
  - All future plans needing TrackingService or TrackingNotifier

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TripsRepositoryPointsSink implements TripPointsSink: hides Drift-generated TripPoint row via import hide; folds Result.Err into Logger.warning (never rethrows)"
    - "TrackingService: constructor-injected facade + repository + sink + ingestorFactory; no Flutter/Riverpod imports; injectable timers for test speed"
    - "TRK-01 automotive filter: single-line predicate on cached _lastActivityType + activityFreshness check at instant motion=true arrives — no state machine, no fusion"
    - "ProviderContainer + UncontrolledProviderScope pattern in main() for eager initialization (facade.ready() before first frame)"
    - "TrackingNotifier.build() uses stateStream.listen + ref.onDispose; fire-and-forget init() — hydration via stream"

key-files:
  created:
    - lib/features/trips/data/trips_repository_points_sink.dart
    - lib/features/trips/domain/tracking_service.dart
    - lib/features/trips/data/tracking_service_providers.dart
    - lib/features/trips/presentation/providers/tracking_state_provider.dart
    - test/features/trips/data/trips_repository_points_sink_test.dart
    - test/features/trips/domain/tracking_service_test.dart
    - test/features/trips/presentation/tracking_notifier_test.dart
  modified:
    - lib/features/trips/domain/trip_fix_ingestor.dart (added totalDistanceMeters + pointCount getters)
    - test/helpers/fake_background_geolocation_facade.dart (enhanced with emitFix/emitMotion/emitActivity, state tracking)
    - lib/main.dart (ProviderContainer + UncontrolledProviderScope, facade.ready() at boot)

key-decisions:
  - "TripPoint ambiguous_import resolved via hide: app_database.dart exports Drift-generated TripPoint row; domain TripPoint DTO is a separate class. Fix: import app_database with hide TripPoint in adapter and test files"
  - "TripFixIngestor.totalDistanceMeters + pointCount added as public read-only getters — additive to Plan 03-02 file, enabling live stats in TrackingService without duplicating state"
  - "FakeBackgroundGeolocationFacade enhanced additively — preserved all existing call-count fields, added moving/readyCalled getters and emitFix/emitMotion/emitActivity helpers"
  - "main.dart switched from ProviderScope to ProviderContainer + UncontrolledProviderScope to call facade.ready() before runApp; only 5 net lines changed"
  - "Test fixture timestamps anchored to DateTime.now() at test start (not a fixed past DateTime) because trip startedAt is also now(), and keeper threshold computes duration as lastFixTs - startedAt"
  - "trackingServiceProvider does not duplicate backgroundGeolocationFacadeProvider — imports from 03-05's background_geolocation_facade_provider.dart"

patterns-established:
  - "Drift/domain TripPoint clash: always use hide TripPoint on app_database.dart imports in files that also import domain trip_point.dart"
  - "Injectable timer durations in service constructors: autoStopDwell/resumeWindow/activityFreshness allow real-time tests without fake_async"
  - "TrackingService stream handler pattern: all async work is unawaited with try/catch; errors logged and swallowed per STATE.md 01-04"

# Metrics
duration: 27min
completed: 2026-07-05
---

# Phase 3 Plan 04: Tracking Service + Notifier Summary

**`TrackingService` orchestrator with TRK-01 automotive filter, manual/auto lifecycle, dwell/resume timers, `TripsRepositoryPointsSink` Drift adapter, and `TrackingNotifier` Riverpod provider — all tested with 17 new tests (10 service + 4 notifier + 3 adapter)**

## Performance

- **Duration:** 27 min
- **Started:** 2026-07-05T11:33:56Z
- **Completed:** 2026-07-05T12:01:04Z
- **Tasks:** 3
- **Files modified:** 10

## Accomplishments

- `TripsRepositoryPointsSink` bridges domain `TripPointsSink` contract to Drift `TripPointsCompanion`, folds `Result.Err` into a logged warning (never rethrows)
- `TrackingService` orchestrates the complete trip lifecycle: manual start/stop (TRK-02/TRK-03), TRK-01 automotive filter with freshness guard, 2-min dwell auto-stop (TRK-04), 15-min resume window with 500 m radius check, SplitRequired handling, cold-start hydration
- `TrackingNotifier` thin Riverpod adapter watches `stateStream` and forwards to Riverpod state; `trackingStateProvider` is the single Riverpod entry point for Wave 3 (Plan 03-06)
- `main.dart` migrated to `ProviderContainer + UncontrolledProviderScope`; `facade.ready()` called once at boot before first frame
- 17 new tests (3 adapter + 10 service + 4 notifier), 130 total passing

## Task Commits

Each task was committed atomically:

1. **Task 1: TripsRepositoryPointsSink adapter** - `8c9d07b` (feat)
2. **Task 2: TrackingService + FakeBackgroundGeolocationFacade** - `24ca4ce` (feat)
3. **Task 3: TrackingNotifier + providers + main.dart wiring** - `00d5f0b` (feat)

**Plan metadata:** `(pending)` (docs: complete plan)

## Files Created/Modified

- `lib/features/trips/data/trips_repository_points_sink.dart` — adapter (TripPoint → TripPointsCompanion, logs Err)
- `lib/features/trips/domain/tracking_service.dart` — orchestrator (lifecycle + automotive filter + timers)
- `lib/features/trips/data/tracking_service_providers.dart` — tripsRepositoryPointsSinkProvider + trackingServiceProvider
- `lib/features/trips/presentation/providers/tracking_state_provider.dart` — TrackingNotifier + trackingStateProvider
- `lib/main.dart` — ProviderContainer + ready() at boot
- `lib/features/trips/domain/trip_fix_ingestor.dart` — added totalDistanceMeters + pointCount getters
- `test/helpers/fake_background_geolocation_facade.dart` — enhanced with emitFix/emitMotion/emitActivity
- `test/features/trips/data/trips_repository_points_sink_test.dart` — 3 adapter tests
- `test/features/trips/domain/tracking_service_test.dart` — 10 service tests
- `test/features/trips/presentation/tracking_notifier_test.dart` — 4 notifier tests

## Decisions Made

1. **TripPoint ambiguous_import** — The Drift code-generated `app_database.g.dart` re-exports a `TripPoint` row class (from `trip_points_table.dart`). The domain layer also defines `TripPoint`. In files that import both, the analyzer emits `ambiguous_import`. Fixed by adding `hide TripPoint` to the `app_database.dart` import wherever the domain DTO is needed.

2. **TripFixIngestor getters added additively** — `totalDistanceMeters` and `pointCount` were added as public read-only getters to `trip_fix_ingestor.dart` rather than duplicating state in `TrackingService`. This is an additive change to the Plan 03-02 file; the ingestor's internal fields (`_totalDistanceMeters`, `_pointCount`) are unchanged.

3. **Test fixture timestamps = DateTime.now()** — The trip's `startedAt` in `startManual()` is `DateTime.now()`. The ingestor's `finalize(startedAt:)` computes duration as `lastAcceptedFix.ts - startedAt`. Using a fixed past `_base` datetime caused negative duration → keeper threshold failed. Switching to `DateTime.now()` at test start aligns trip timestamps with service timestamps.

4. **ProviderContainer + UncontrolledProviderScope** — Switched from `ProviderScope(child:)` to allow `facade.ready()` to be called eagerly before `runApp`. Net diff: +5 lines to `main.dart`.

5. **trackingServiceProvider imports from 03-05** — `backgroundGeolocationFacadeProvider` was already created in `lib/features/trips/data/background_geolocation_facade_provider.dart` by Plan 03-05 (which ran in parallel). `tracking_service_providers.dart` imports from there rather than duplicating the provider.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] TripPoint ambiguous_import in adapter and test files**

- **Found during:** Task 1 (flutter analyze)
- **Issue:** `app_database.dart` re-exports a Drift-generated `TripPoint` row class. Domain `trip_point.dart` also defines `TripPoint`. Any file importing both produces `ambiguous_import` errors.
- **Fix:** Added `hide TripPoint` to `app_database.dart` import in `trips_repository_points_sink.dart` and its test file.
- **Files modified:** `lib/features/trips/data/trips_repository_points_sink.dart`, test file
- **Verification:** `flutter analyze` clean; 3 adapter tests pass
- **Committed in:** `8c9d07b` (Task 1 commit)

**2. [Rule 2 - Missing Critical] TripFixIngestor public stat getters**

- **Found during:** Task 2 (TrackingService live-stats update in `_onLocation`)
- **Issue:** `TrackingService` needed `totalDistanceMeters` and `pointCount` from the ingestor to emit updated `TrackingRecording` state after each fix. These were private fields.
- **Fix:** Added `double get totalDistanceMeters => _totalDistanceMeters` and `int get pointCount => _pointCount` to `TripFixIngestor`.
- **Files modified:** `lib/features/trips/domain/trip_fix_ingestor.dart`
- **Verification:** `flutter analyze` clean; all ingestor tests still pass
- **Committed in:** `24ca4ce` (Task 2 commit)

**3. [Rule 1 - Bug] Test fixture timestamps anchored to DateTime.now()**

- **Found during:** Task 2 test run (manual round-trip and auto-stop tests failed)
- **Issue:** Fixtures used `_base = DateTime.utc(2026, 7, 5, 9)` (fixed past time) but `startManual()` uses `DateTime.now()` (~2.5 h later). `finalize(startedAt: now)` computed negative duration → `durationSeconds = 0` → keeper threshold failed → trip deleted instead of kept.
- **Fix:** Changed all fixture timestamp builders to accept `DateTime from` and generate timestamps relative to `DateTime.now()` at test start.
- **Files modified:** `test/features/trips/domain/tracking_service_test.dart`
- **Verification:** All 10 service tests pass
- **Committed in:** `24ca4ce` (Task 2 commit)

**4. [Rule 3 - Blocking] backgroundGeolocationFacadeProvider already exists from 03-05**

- **Found during:** Task 3 (checking files before creating tracking_service_providers.dart)
- **Issue:** Plan 03-04 planned to create `backgroundGeolocationFacadeProvider` in `tracking_service_providers.dart`, but Plan 03-05 (parallel wave) had already created it in `background_geolocation_facade_provider.dart`.
- **Fix:** `tracking_service_providers.dart` imports from 03-05's file rather than duplicating the provider.
- **Files modified:** `lib/features/trips/data/tracking_service_providers.dart`
- **Verification:** `flutter analyze` clean; no duplicate provider
- **Committed in:** `00d5f0b` (Task 3 commit)

---

**Total deviations:** 4 auto-fixed (2 bugs, 1 missing critical, 1 blocking)
**Impact on plan:** All fixes resolved correctly. No scope changes; all plan deliverables shipped.

## Issues Encountered

None beyond the deviations documented above.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `trackingStateProvider` is ready for Plan 03-06 (FAB morph + live-tracking panel)
- `TrackingNotifier.startManual()` / `stopActive()` are the two public API points Plan 03-06 wires to the FAB
- `main.dart` already calls `facade.ready()` — no further boot wiring needed
- All 130 tests green; `flutter analyze` clean

---
*Phase: 03-tracking-mvp*
*Completed: 2026-07-05*
