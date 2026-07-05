---
id: 03-04
phase: 03-tracking-mvp
plan: 04
type: execute
wave: 2
depends_on: [03-01, 03-02, 03-03]
files_modified:
  - lib/features/trips/data/trips_repository_points_sink.dart
  - lib/features/trips/domain/tracking_service.dart
  - lib/features/trips/presentation/providers/tracking_state_provider.dart
  - lib/features/trips/data/tracking_service_providers.dart
  - lib/main.dart
  - test/features/trips/data/trips_repository_points_sink_test.dart
  - test/features/trips/domain/tracking_service_test.dart
  - test/features/trips/presentation/tracking_notifier_test.dart
  - test/helpers/fake_background_geolocation_facade.dart
autonomous: true
requirements_addressed: [TRK-01, TRK-02, TRK-03, TRK-04, TRK-05, TRK-08]

must_haves:
  truths:
    - "Manual start: tapping FAB → `TrackingNotifier.startManual()` opens a Trips row (status=recording, manuallyStarted=true), calls `facade.changePace(moving: true)`, and transitions state to TrackingRecording"
    - "Manual stop: `stopActive()` calls `facade.changePace(moving: false)`, flushes the batcher, closes the trip via repository (or deletes it if `!passesKeeperThreshold`), transitions to TrackingIdle"
    - "Auto-start: `facade.onMotionChange(isMoving: true)` while state is Idle opens an auto trip (manuallyStarted=false) — but only if the most recent activity classification is `in_vehicle` AND that classification arrived within the freshness window (default 10 s). This is the TRK-01 automotive filter, NOT a state machine on top of FGB."
    - "Stale activity race: if the cached activity is null/unknown OR older than the freshness window (default 10 s), a motion=true event is discarded — the next motion tick (FGB re-emits within seconds) is expected to retry once the fresh activity classification lands"
    - "Auto-stop dwell: when the latest activity is non-automotive for > 2 min AND the resume window (15 min + 500 m of stop point) has elapsed with no in_vehicle event, the notifier closes the trip with `autoStopped=true`"
    - "Resume window: an `in_vehicle` motion event within 15 min AND within 500 m of the stop point extends the same trip (endedAt still null, no new row)"
    - "Cold-start hydration: on `build()`, if `repository.activeTrip()` returns a row, state is TrackingRecording seeded from that row's stats"
    - "Every fix from `facade.onLocation` is fed to `TripFixIngestor.ingest()`; `FixAccepted` → batcher; `SplitRequired` → close current trip + open new one seeded with the recovered fix"
    - "Both `main.dart` and Riverpod overrides in tests can inject a `BackgroundGeolocationFacade` — production wire uses `FgbBackgroundGeolocationFacade`"
    - "TripsRepositoryPointsSink adapter satisfies the 03-02 TripPointsSink contract by wrapping TripsRepository.appendPoints — it converts domain TripPoint → Drift TripPointsCompanion and unwraps Result<void> (logging on Err, never rethrowing)"
  artifacts:
    - path: "lib/features/trips/data/trips_repository_points_sink.dart"
      provides: "Adapter that lets TripsRepository (Plan 03-01) satisfy Plan 03-02's TripPointsSink contract"
      contains: "class TripsRepositoryPointsSink"
    - path: "lib/features/trips/domain/tracking_service.dart"
      provides: "The orchestrator that owns facade subscriptions, ingestor, batcher, and dwell timers — imperative, not a widget"
      contains: "class TrackingService"
    - path: "lib/features/trips/presentation/providers/tracking_state_provider.dart"
      provides: "Notifier<TrackingState> — thin Riverpod adapter over TrackingService"
      contains: "class TrackingNotifier"
    - path: "lib/features/trips/data/tracking_service_providers.dart"
      provides: "backgroundGeolocationFacadeProvider (FGB-backed) + trackingServiceProvider + tripsRepositoryPointsSinkProvider"
      contains: "backgroundGeolocationFacadeProvider"
    - path: "test/helpers/fake_background_geolocation_facade.dart"
      provides: "Reusable in-memory facade fake for all trip-notifier / tracking-service tests"
      contains: "class FakeBackgroundGeolocationFacade"
  key_links:
    - from: "lib/features/trips/data/trips_repository_points_sink.dart"
      to: "TripsRepository.appendPoints"
      via: "adapter converts List<TripPoint> → List<TripPointsCompanion>, calls repo, folds Result<void> Err into a logger warning"
      pattern: "TripsRepositoryPointsSink"
    - from: "lib/features/trips/domain/tracking_service.dart"
      to: "TripFixIngestor + TripFixBatcher + TripsRepositoryPointsSink + BackgroundGeolocationFacade"
      via: "constructor injection of all four"
      pattern: "TrackingService\\("
    - from: "lib/main.dart"
      to: "backgroundGeolocationFacadeProvider"
      via: "ProviderScope override or a one-shot `ref.read(facade).ready()` after runApp"
      pattern: "backgroundGeolocation"
    - from: "lib/features/trips/presentation/providers/tracking_state_provider.dart"
      to: "TrackingService"
      via: "notifier watches service.stateStream and forwards to Riverpod state"
      pattern: "ref.watch\\(trackingServiceProvider\\)"
---

<objective>
Wire the pure-Dart pieces (ingestor + batcher + repository + facade) into a single `TrackingService` orchestrator, expose it via a Riverpod `TrackingNotifier<TrackingState>`, and hydrate on cold-start. This plan is the phase's integration crossroads — the ~120 min plan per RESEARCH.md.

Purpose: TRK-01 (auto-detect background trip), TRK-02 (manual trip via FAB), TRK-03 (manual trip only ends on Stop — no auto-end for manual trips), TRK-04 (auto-trip 2-min non-automotive dwell), TRK-05 (metadata persisted), TRK-08 (state machine + 20-fix batching).

Output: TripsRepositoryPointsSink adapter + TrackingService + TrackingNotifier + providers + main.dart wiring + 3 test files + shared fake facade helper. UI still shows the P2 static FAB — Plan 03-06 wires the FAB to the notifier.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/03-tracking-mvp/03-CONTEXT.md
@.planning/phases/03-tracking-mvp/03-RESEARCH.md

# Wave 1 outputs this plan builds on
@.planning/phases/03-tracking-mvp/03-01-SUMMARY.md
@.planning/phases/03-tracking-mvp/03-02-SUMMARY.md
@.planning/phases/03-tracking-mvp/03-03-SUMMARY.md

# Phase 1 patterns
@lib/core/errors/domain_error.dart
@lib/core/errors/result.dart
@lib/main.dart

# Package name is `auto_explore`.
</context>

<tasks>

<task type="auto">
  <name>Task 1: TripsRepositoryPointsSink adapter (Drift ↔ domain seam)</name>
  <files>
    - lib/features/trips/data/trips_repository_points_sink.dart
    - test/features/trips/data/trips_repository_points_sink_test.dart
  </files>
  <action>
    Plan 03-02 defines `TripPointsSink` with `Future<void> appendPoints(int tripId, List<TripPoint> points)` in `lib/features/trips/domain/trip_fix_batcher.dart` (domain layer, no Drift imports). Plan 03-01 defines `TripsRepository.appendPoints(...)` returning `Future<Result<void>>` and consuming `List<TripPointsCompanion>` (Drift-generated). These signatures deliberately don't match — the domain layer must not know about Drift.

    This task creates the adapter that bridges them, living in the data layer alongside the repository.

    1. `lib/features/trips/data/trips_repository_points_sink.dart`:
       ```dart
       import 'package:auto_explore/core/errors/result.dart';
       import 'package:auto_explore/features/trips/data/trips_repository.dart';
       import 'package:auto_explore/features/trips/domain/trip_fix_batcher.dart'
           show TripPointsSink;
       import 'package:auto_explore/features/trips/domain/trip_point.dart';
       import 'package:drift/drift.dart' show Value;
       import 'package:logging/logging.dart';
       // Import the generated companion type from wherever 03-01 exposes it:
       import 'package:auto_explore/core/db/app_database.dart'; // TripPointsCompanion

       /// Adapts [TripsRepository] to the domain-layer [TripPointsSink] contract
       /// from Plan 03-02. Converts [TripPoint] → [TripPointsCompanion] and folds
       /// [Result.Err] into a logged warning so the batcher's `Future<void>`
       /// contract holds (never rethrow — a dropped batch must not kill the trip).
       class TripsRepositoryPointsSink implements TripPointsSink {
         TripsRepositoryPointsSink(this._repo, {Logger? logger})
             : _log = logger ?? Logger('tracking.points_sink');
         final TripsRepository _repo;
         final Logger _log;

         @override
         Future<void> appendPoints(int tripId, List<TripPoint> points) async {
           if (points.isEmpty) return;
           final companions = points.map(_toCompanion).toList(growable: false);
           final result = await _repo.appendPoints(tripId, companions);
           result.when(
             ok: (_) {},
             err: (e) => _log.warning(
               'appendPoints failed for tripId=$tripId '
               '(${points.length} points dropped): ${e.message}',
             ),
           );
         }

         TripPointsCompanion _toCompanion(TripPoint p) => TripPointsCompanion(
               tripId: Value(p.tripId),
               seq: Value(p.seq),
               ts: Value(p.ts),
               lat: Value(p.lat),
               lon: Value(p.lon),
               speedKmh: Value(p.speedKmh),
               accuracyMeters: Value(p.accuracyMeters),
               altitudeMeters: Value(p.altitudeMeters),
               motionType: Value(p.motionType),
             );
       }
       ```
       Verify the exact field names / nullability against Plan 03-01's `TripPointsCompanion` — 03-01's schema is authoritative. If a column is non-nullable but the DTO is nullable, fall back to a sensible default (`0` for numbers, `''` never — prefer NULLABLE columns in the schema).

    2. `test/features/trips/data/trips_repository_points_sink_test.dart`:
       - Boot an in-memory `AppDatabase` + real `TripsRepository` (per Plan 03-01's test pattern).
       - Cases:
         - `appendPoints(tripId, [])` → repository is not called (empty short-circuit)
         - `appendPoints(tripId, [3 TripPoints])` → 3 rows land in `trip_points` with matching seq/lat/lon
         - Repository returns `Err` (inject via a `TripsRepository` stub or an unopened DB handle) → adapter completes normally (does NOT rethrow), warning logged (assert via a `Logger.root.onRecord` listener capturing SEVERE/WARNING records)

    Anti-patterns to avoid:
    - Do NOT surface `Result<void>` from the sink — the batcher expects `Future<void>`. Errors are logged, never rethrown, per STATE.md 01-04 (swallow-and-log at boundaries).
    - Do NOT edit `lib/features/trips/data/trips_repository.dart` — its signature stays `Future<Result<void>>` as Plan 03-01 shipped it. The adapter is the seam.
    - Do NOT use `withOpacity` (no color code here, but STATE.md rule applies universally).
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/trips/data/trips_repository_points_sink_test.dart` all green
  </verify>
  <done>
    Adapter bridges Plan 03-01's `Result<void>`-returning repo to Plan 03-02's `Future<void>` sink contract. Ready for injection into `TrackingService`.
  </done>
</task>

<task type="auto">
  <name>Task 2: TrackingService — imperative orchestrator (no Riverpod)</name>
  <files>
    - lib/features/trips/domain/tracking_service.dart
    - test/helpers/fake_background_geolocation_facade.dart
    - test/features/trips/domain/tracking_service_test.dart
  </files>
  <action>
    1. `lib/features/trips/domain/tracking_service.dart` — plain Dart class, no Flutter/Riverpod imports. Owns:
       - The `BackgroundGeolocationFacade` (injected)
       - The `TripsRepository` (injected) — for open/close/hydrate; `TripsRepositoryPointsSink` is injected separately for the batcher
       - The active `TripFixIngestor` and `TripFixBatcher` (created per-trip, disposed on stop) — batcher is wired to the injected `TripPointsSink`
       - Stream subscriptions to `facade.onLocation`, `facade.onMotionChange`, `facade.onActivityChange`
       - Dwell timer (auto-stop) and resume-window timer
       - A `Stream<TrackingState>` output the notifier consumes

       API:
       ```dart
       class TrackingService {
         TrackingService({
           required BackgroundGeolocationFacade facade,
           required TripsRepository repository,
           required TripPointsSink pointsSink,
           TripFixIngestor Function() ingestorFactory = _defaultIngestor,
           Duration autoStopDwell = const Duration(minutes: 2),
           Duration resumeWindow = const Duration(minutes: 15),
           double resumeRadiusMeters = 500,
           Duration activityFreshness = const Duration(seconds: 10),
         });

         Stream<TrackingState> get stateStream; // seeded with TrackingIdle
         TrackingState get currentState;

         /// Called once at app boot after facade.ready(). Wires event listeners
         /// and hydrates state from the repository if a trip is in flight.
         Future<void> init();

         Future<void> startManual();
         Future<void> stopActive();
         Future<void> dispose();
       }
       ```

    2. Behaviour rules (implement in the service, verify in Task 3 tests):

       **onLocation event handling:**
       - Convert `FixInput` → `IngestorOutcome` via ingestor.
       - `FixAccepted` → build a domain `TripPoint(tripId: _currentTripId, seq: ++_seq, ts: fix.ts, lat, lon, speedKmh, accuracyMeters, altitudeMeters, motionType)` and pass to `batcher.add(...)`. Then update `_currentState` (`TrackingRecording` with fresh distance, pointCount, currentSpeedKmh) and emit to the stream.
         - **Note:** the batcher's sink is the injected `TripsRepositoryPointsSink` from Task 1 — the service never touches `TripPointsCompanion` directly.
       - `FixRejected` → no state change (log at fine level via `Logger('tracking')`).
       - `GapObserved` → flush batcher (natural checkpoint per RESEARCH.md); no state change.
       - `SplitRequired` → **close the current trip (auto), open a new one, seed it with the recovered fix.** Concretely:
         1. `batcher.flush()` (before repo close so points land in DB before we mark the trip done)
         2. `finalize` current ingestor → `TripSummaryDraft`
         3. If passesKeeper → `repository.closeTrip(_currentTripId, summary with autoStopped=true)`; else `repository.deleteTrip(_currentTripId)`.
         4. Open new trip row (`repository.openTrip(...)`) with `manuallyStarted=false`.
         5. Reset ingestor, feed the recovered fix as its first input.

       **onMotionChange event handling — TRK-01 automotive filter (NOT a state machine):**
       - If `mc.isMoving == true` AND state is TrackingIdle:
         - **Automotive filter (single-line check, enforcing TRK-01 "automotive"):**
           ```dart
           final lastActivity = _lastActivityType; // cached from onActivityChange
           final lastActivityAt = _lastActivityAt; // DateTime? of cache write
           final activityFresh = lastActivityAt != null &&
               DateTime.now().difference(lastActivityAt) <= activityFreshness;
           if (lastActivity != 'in_vehicle' || !activityFresh) {
             // Non-automotive OR stale activity → discard this motion event.
             // FGB re-emits motion within seconds; the next tick retries once
             // a fresh classification lands. No state machine, no fusion.
             _log.fine('motion=true discarded: activity=$lastActivity, fresh=$activityFresh');
             return;
           }
           ```
           This single-line check enforces TRK-01's "automotive" requirement. Non-automotive motion (walking, cycling, still) is simply discarded — no state machine, no classifier fusion. The stale-activity guard handles the race where motion arrives before the first activity update (or after a long dormant period).
         - Otherwise, open an auto-trip: `repository.openTrip(startedAt: mc.ts, manuallyStarted: false)`, create fresh ingestor + batcher, emit TrackingRecording.
       - Also handles resume-window logic (see auto-stop below).
       - On any motion change while recording, also call `batcher.flush()` (natural checkpoint).

       **onActivityChange event handling:**
       - Cache both `_lastActivityType` (default `'unknown'`) AND `_lastActivityAt = DateTime.now()`. The `_lastActivityAt` timestamp is the freshness anchor used by the automotive filter above.
       - If state is TrackingRecording AND `manuallyStarted == false` AND `ac.activityType` is non-automotive (anything except `in_vehicle`) → start `_dwellTimer = Timer(autoStopDwell, _onDwellExpired)`. Reset the timer if a subsequent activity is `in_vehicle` again.
       - `_onDwellExpired` → **do not close immediately.** Record `_pendingStopAt = DateTime.now()` and `_pendingStopFix = _lastAcceptedFix` (or last-known location from the ingestor). Start `_resumeTimer = Timer(resumeWindow, _closeAutoTrip)`. State stays TrackingRecording (the trip's endedAt stays NULL).
       - During the resume window, if a new `in_vehicle` motion event arrives AND `haversine(newLat/Lon, _pendingStopFix) <= resumeRadiusMeters` → cancel `_resumeTimer`, clear `_pendingStopAt`, resume normally. Otherwise on timer fire → `_closeAutoTrip()`: finalize summary with `autoStopped=true`, apply keeper threshold, transition to Idle.

       **Manual start/stop (per TRK-03):**
       - `startManual()`: if state == Idle, `repository.openTrip(startedAt: DateTime.now(), manuallyStarted: true)`, create fresh ingestor + batcher, `await facade.changePace(moving: true)`, emit TrackingRecording.
       - `stopActive()`: universal stop (per CONTEXT). Regardless of manual/auto:
         1. `batcher.flush()`
         2. `finalize()` ingestor → summary
         3. If passesKeeper → `repository.closeTrip(...)` with `autoStopped=false` (user pressed Stop)
         4. Else → `repository.deleteTrip(...)` — the row silently disappears
         5. `await facade.changePace(moving: false)`
         6. Cancel dwell/resume timers
         7. Emit TrackingIdle.
       - **Manual trip auto-stop is DISABLED (TRK-03):** if state is TrackingRecording AND `manuallyStarted == true`, the dwell timer never starts — non-automotive activity is ignored for auto-close purposes on manual trips. Manual trips end ONLY via `stopActive()`.

       **init():**
       - Subscribe to facade streams (keep the `StreamSubscription`s for `dispose()`).
       - Query `repository.activeTrip()`. If non-null:
         - Set `_currentTripId = trip.id`, seed the ingestor's state from the trip's summary columns where possible (start with distance=0, pointCount from DB — matcher will re-derive on close; the counts are advisory for the overlay).
         - Read prior points via `repository.watchPoints(tripId)` first snapshot to seed max lat/lon bbox and last-accepted position. Alternative simpler path: seed `distanceMeters` from `trip.distanceMeters ?? 0`, `pointCount` from `trip.pointCount ?? 0`, `currentSpeedKmh` from null. The ingestor rebuilds bbox from new fixes only — acceptable per CONTEXT ("reconstruct the live-tracking overlay from the in-flight trip state (duration, distance so far, current speed)").
         - Emit initial TrackingRecording state.
       - Else: emit TrackingIdle.

       **Error handling:**
       - Wrap every `repository.*` call in `Result.when` — on Err, log at severe via `Logger('tracking')`, transition to Idle, do not crash.
       - Never rethrow from stream handlers — swallow-and-log (STATE.md 01-04 pattern).

    3. `test/helpers/fake_background_geolocation_facade.dart` — reusable in tests:
       ```dart
       class FakeBackgroundGeolocationFacade implements BackgroundGeolocationFacade {
         final _loc = StreamController<FixInput>.broadcast();
         final _motion = StreamController<MotionChange>.broadcast();
         final _activity = StreamController<ActivityChange>.broadcast();
         bool started = false, moving = false, readyCalled = false;
         final List<String> notificationTexts = [];
         String? get lastNotificationText =>
             notificationTexts.isEmpty ? null : notificationTexts.last;

         @override
         Future<void> ready() async { readyCalled = true; }
         @override Future<void> start() async { started = true; }
         @override Future<void> stop() async { started = false; }
         @override Future<void> changePace({required bool moving}) async {
           this.moving = moving;
         }
         @override Future<void> setNotificationText(String t) async {
           notificationTexts.add(t);
         }
         @override Future<void> showIgnoreBatteryOptimizations() async {}
         @override Stream<FixInput> get onLocation => _loc.stream;
         @override Stream<MotionChange> get onMotionChange => _motion.stream;
         @override Stream<ActivityChange> get onActivityChange => _activity.stream;
         @override Future<FgbState> currentState() async =>
             FgbState(enabled: started, isMoving: moving);

         // Test-only emitters:
         void emitFix(FixInput f) => _loc.add(f);
         void emitMotion(bool isMoving) =>
             _motion.add(MotionChange(isMoving: isMoving, ts: DateTime.now()));
         void emitActivity(String type, {int confidence = 90}) =>
             _activity.add(ActivityChange(
               activityType: type, confidence: confidence, ts: DateTime.now(),
             ));
       }
       ```
       The `notificationTexts` list is deliberately exposed as a growing log so Plan 03-06's 30 s notification updater can be verified from tests without needing `fake_async`.

    4. `test/features/trips/domain/tracking_service_test.dart`:
       - Boot AppDatabase with in-memory executor, real TripsRepository, real `TripsRepositoryPointsSink` (from Task 1), FakeBackgroundGeolocationFacade.
       - Cases:
         - **manual round-trip**: `startManual()` → emit 10 in-vehicle fixes → `stopActive()` — asserts: one Trip row with status=pending, endedAt set, 10 trip_points, autoStopped=false.
         - **manual below keeper**: `startManual()` → emit 3 fixes within 30 s in a 20 m bbox → `stopActive()` — asserts: zero trip rows, zero trip_points (trip was deleted).
         - **auto-start on motion + fresh in_vehicle**: emit activityType='in_vehicle' at t=0, then emitMotion(true) at t=1s (within freshness window) — asserts: a Trip row with manuallyStarted=false exists, state is TrackingRecording.
         - **auto-start DISCARDED on stale activity**: emit activityType='in_vehicle' at t=0, advance time past freshness window (inject `activityFreshness: Duration(milliseconds: 100)` and wait 150 ms via `Future.delayed` — real time, no fake_async needed), then emitMotion(true) — asserts: state STAYS Idle, NO trip row opened. Then emit a fresh activityType='in_vehicle' + motion(true) — trip opens.
         - **auto-start DISCARDED on non-automotive activity**: emit activityType='walking', then emitMotion(true) — asserts: state STAYS Idle, no trip row.
         - **auto-stop after dwell**: continuation of the fresh-in_vehicle case; make dwell duration injectable and set to 100 ms in tests. Emit activityType='still'. Wait past dwell + resume window. Assert trip row is closed with autoStopped=true.
         - **resume window extends trip**: start auto trip, dwell fires, then within resume window emit activityType='in_vehicle' + a fix within 500 m of stop point — assert trip row's endedAt is STILL null (same trip continues), one row not two.
         - **manual trip ignores dwell**: startManual → 5 fixes → emit activityType='still' for 3 min (via short injected dwell) → assert state is STILL TrackingRecording, trip row endedAt is still null. `stopActive()` closes it.
         - **cold-start hydration**: seed a trips row directly via repo (endedAt=null, manuallyStarted=true) → construct fresh TrackingService → `init()` → assert `currentState` is TrackingRecording with tripId matching the seeded row.
         - **SplitRequired closes+opens**: emit a fix, then emit a fix 6 min later at 800 m distance → assert two trip rows exist, first has endedAt set, second is active.

       Prefer injectable-duration knobs over `fake_async`: `autoStopDwell: Duration(milliseconds: 100)`, `resumeWindow: Duration(milliseconds: 200)`, `activityFreshness: Duration(milliseconds: 100)`. Real time, real timers, no extra dep.

    Anti-patterns to avoid:
    - Do NOT import Riverpod in `tracking_service.dart` — Task 4 handles Riverpod adapter separately.
    - Do NOT put UI concerns (timers for 1-second clock face) here — that's Plan 03-06 (widget-owned timer). The 30 s NOTIFICATION timer is a different beast and DOES live here (added by 03-06).
    - Do NOT use `Timer.periodic` for the resume window — it's a one-shot `Timer` (RESEARCH.md q3).
    - Do NOT build a "motion state machine" that fuses motion + activity across multiple events. The automotive filter is a single-line predicate on the cached activity at the instant motion=true arrives, plus a freshness check. Nothing more.
    - Do NOT hydrate by re-reading every trip_points row — the overlay needs stats only, not the polyline (P4/P7 can polyline the map later).
    - Do NOT hand the batcher a `TripPointsCompanion` — it's a `TripPoint` (domain DTO); the adapter from Task 1 handles the conversion.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/trips/domain/tracking_service_test.dart` all 10 cases green (includes the two new automotive-filter cases)
  </verify>
  <done>
    TrackingService is the phase's brain — manual/auto/dwell/resume/split/keeper all covered. TRK-01 automotive filter enforced with fresh-activity guard; stale-activity race documented and tested. Fake facade helper committed under `test/helpers/`.
  </done>
</task>

<task type="auto">
  <name>Task 3: Riverpod adapter (TrackingNotifier + providers) + main.dart wiring</name>
  <files>
    - lib/features/trips/presentation/providers/tracking_state_provider.dart
    - lib/features/trips/data/tracking_service_providers.dart
    - lib/main.dart
    - test/features/trips/presentation/tracking_notifier_test.dart
  </files>
  <action>
    1. `lib/features/trips/data/tracking_service_providers.dart`:
       ```dart
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart';
       import 'package:auto_explore/features/trips/data/fgb_background_geolocation_facade.dart';
       import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
       import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
       import 'package:auto_explore/features/trips/domain/tracking_service.dart';

       final backgroundGeolocationFacadeProvider =
           Provider<BackgroundGeolocationFacade>((ref) {
         return FgbBackgroundGeolocationFacade();
       });

       final tripsRepositoryPointsSinkProvider =
           Provider<TripsRepositoryPointsSink>((ref) {
         return TripsRepositoryPointsSink(ref.watch(tripsRepositoryProvider));
       });

       final trackingServiceProvider = Provider<TrackingService>((ref) {
         final service = TrackingService(
           facade: ref.watch(backgroundGeolocationFacadeProvider),
           repository: ref.watch(tripsRepositoryProvider),
           pointsSink: ref.watch(tripsRepositoryPointsSinkProvider),
         );
         ref.onDispose(service.dispose);
         return service;
       });
       ```

    2. `lib/features/trips/presentation/providers/tracking_state_provider.dart`:
       ```dart
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:auto_explore/features/trips/data/tracking_service_providers.dart';
       import 'package:auto_explore/features/trips/domain/tracking_service.dart';
       import 'package:auto_explore/features/trips/domain/tracking_state.dart';

       class TrackingNotifier extends Notifier<TrackingState> {
         late final TrackingService _svc;
         @override
         TrackingState build() {
           _svc = ref.watch(trackingServiceProvider);
           final sub = _svc.stateStream.listen((s) => state = s);
           ref.onDispose(sub.cancel);
           // Fire-and-forget init — hydration flips state via the stream if needed.
           // ignore: discarded_futures
           _svc.init();
           return _svc.currentState;
         }
         Future<void> startManual() => _svc.startManual();
         Future<void> stopActive() => _svc.stopActive();
       }

       final trackingStateProvider =
           NotifierProvider<TrackingNotifier, TrackingState>(TrackingNotifier.new);
       ```

    3. `lib/main.dart` — add exactly one line inside `main()` after `runApp(...)` (or before, via `WidgetsFlutterBinding.ensureInitialized` if not already there): call `facade.ready()` at boot. A clean way:
       ```dart
       Future<void> main() async {
         WidgetsFlutterBinding.ensureInitialized();
         // ... existing setupLogging, LiquidGlassSettings.platformBlurEnabled = true;, etc.
         final container = ProviderContainer();
         // Fire-and-forget ready — safe to await since ready() is idempotent.
         unawaited(container.read(backgroundGeolocationFacadeProvider).ready());
         runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
       }
       ```
       **Preserve everything else** in `main.dart` — this is a surgical add. If the existing `main` uses `ProviderScope(child: ...)` (Phase 1 pattern) instead of a container, keep that shape and instead do the `ready()` call from a `ref.listen` in the router's root widget, or from a top-level `WidgetsBindingObserver.onFirstFrame` hook. Whichever preserves the P2 shape — Claude's discretion; the requirement is `ready()` runs exactly once at boot.

       Verify against `lib/main.dart` as it stands (Phase 2 close-out): find `ProviderScope` and add the ready-call in the least invasive spot.

    4. `test/features/trips/presentation/tracking_notifier_test.dart`:
       - `ProviderContainer` with overrides:
         - `backgroundGeolocationFacadeProvider` → `FakeBackgroundGeolocationFacade`
         - `appDatabaseProvider` → in-memory
       - Cases:
         - `container.read(trackingStateProvider)` → initial state is TrackingIdle
         - `await container.read(trackingStateProvider.notifier).startManual()` → state flips to TrackingRecording, `fakeFacade.moving == true`
         - After `stopActive()` on an empty trip (no fixes → below keeper) → state back to Idle, trips table has 0 rows (deleted)
         - After `stopActive()` on a valid trip (emit 60 fixes at 1 Hz spanning 60+ s and 200+ m) → state Idle, trips table has 1 row with status=pending

    Anti-patterns to avoid:
    - Do NOT put streams subscriptions inside `build()` without `ref.onDispose` — Riverpod will crash on hot reload.
    - Do NOT recreate the `TrackingService` per Notifier build — the service is a Provider (long-lived); the notifier re-reads it.
    - Do NOT surface FGB errors in `state` as an error variant in P3 — CONTEXT stays with two states (Idle, Recording). Errors go to logs.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/trips/presentation/tracking_notifier_test.dart` all cases green
    - `flutter test` full suite green (no regression on Phase 1/2 tests)
    - `main.dart` diff is ≤ 5 lines
  </verify>
  <done>
    TrackingNotifier is the sole Riverpod entry point Wave 3 (03-06) reads. FGB `ready()` is called once at boot. Existing map screen still compiles (FAB is stub-static — Plan 03-06 wires it).
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` clean
- `flutter test` full suite green
- No regression on `test/features/map/**` from Phase 2
- Commit: `feat(03-04): TrackingService + TripsRepositoryPointsSink + Riverpod notifier + facade wiring`
</verification>

<success_criteria>
- Manual + auto trip lifecycles work end-to-end at the notifier level, verified by tests
- TRK-01 automotive filter proven by two dedicated tests (fresh-activity accept, stale-activity discard)
- Cold-start hydration proven by test
- Every FGB-side call is behind the facade — swap-out for tests is trivial
- Drift ↔ domain seam sits in the adapter — the domain layer stays Drift-free
- No UI-facing wiring yet (that's 03-06)
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-04-SUMMARY.md`
</output>
