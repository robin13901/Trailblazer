---
id: 03-1-04
phase: 03-1-tracking-fixes
plan: 04
type: execute
wave: 2
depends_on: [03-1-01]
files_modified:
  - test/features/trips/tracking_service_motion_filter_regression_test.dart
  - test/features/trips/tracking_service_state_stream_cadence_test.dart
autonomous: true
requirements: []

must_haves:
  truths:
    - "A test asserts that startManual() bypasses the TRK-01 activity gate — with `_lastActivityType='unknown'` (never fired), a subsequent onLocation fix is still accepted and stateStream emits a TrackingRecording"
    - "A test asserts that stateStream re-emits at least once per accepted fix, with monotonically increasing pointCount and reflecting the incoming fix's speedKmh"
    - "Both tests are pure unit tests using FakeBackgroundGeolocationFacade — no widget tree, no platform channels, no drives required"
    - "flutter analyze and flutter test both green"
  artifacts:
    - path: "test/features/trips/tracking_service_motion_filter_regression_test.dart"
      provides: "Regression test for H3 — locks in the invariant that manual trips never gate on activity classification"
    - path: "test/features/trips/tracking_service_state_stream_cadence_test.dart"
      provides: "Regression test for H4 — locks in the invariant that stateStream emits per accepted fix"
  key_links:
    - from: "test/features/trips/tracking_service_motion_filter_regression_test.dart"
      to: "lib/features/trips/domain/tracking_service.dart"
      via: "Constructs TrackingService with FakeBackgroundGeolocationFacade, calls startManual(), fires a fake onLocation event, asserts stateStream emitted a TrackingRecording with distance > 0"
      pattern: "startManual"
    - from: "test/features/trips/tracking_service_state_stream_cadence_test.dart"
      to: "lib/features/trips/domain/tracking_service.dart"
      via: "Constructs TrackingService, starts a manual trip, fires 10 fake fixes, awaits 10 stateStream emissions with strictly increasing pointCount"
      pattern: "expectLater(service.stateStream"
---

## Goal

Lock in the H3 (motion filter placement) and H4 (stateStream cadence) invariants as regression tests. 03-1-RESEARCH REFUTED both as active bugs — the current code is correct. But the failed 2026-07-06 drive appeared to symptom-match both hypotheses (because H1 masked everything downstream). Cheap tests here prevent a future refactor from breaking either invariant silently.

## Context

- 03-1-RESEARCH §4 (H3) — REFUTED. The TRK-01 motion filter (`tracking_service.dart:373-391`) only runs while `_currentState is TrackingIdle`. `startManual()` (`:184-190`) directly emits `TrackingRecording`, so subsequent `_onMotionChange` events skip the gate. `_onLocation` (`:239-289`) has no activity gate at all. Current code is correct — but this test locks it in.
- 03-1-RESEARCH §5 (H4) — REFUTED. `stateStream` re-emits on every `FixAccepted` (`tracking_service.dart:266-276`) with the ingestor's running `totalDistanceMeters` and `pointCount`. Current code is correct — but this test locks it in.
- Bias: KEEP these tests. Coverage prevents future regressions on the exact lines that the failed drive appeared to implicate. Per project CLAUDE.md, this is behavior-sensitive test infrastructure — inexpensive to write, high value against future refactors.
- If checker flags this plan as scope-thin, fold into 03-1-01 (adjacent tracking_service tests). Rationale for keeping separate: 03-1-04 owns test files with zero overlap with 03-1-01 (which owns diagnostics tests) or 03-1-02 (which owns start-call tests). Truly parallel, no shared files.
- STATE Plan 03-04 fixture-timestamp pattern: use `DateTime.now()` at test start, NOT a fixed past `DateTime`. `startManual` records `startedAt = DateTime.now()` and the keeper threshold is duration = lastFix.ts - startedAt. Mismatched timestamps cause negative durations and unexpected trip deletion at stop.
- No production code changes in this plan. If either test cannot be made green without a production-code change, the research verdict was wrong — escalate and fold the fix into 03-1-02.

## Tasks

<task type="auto">
  <name>Task 1: H3 regression — startManual bypasses TRK-01 activity gate</name>
  <files>
    test/features/trips/tracking_service_motion_filter_regression_test.dart
  </files>
  <intent>Lock in the invariant that manual trips never gate on activity classification.</intent>
  <action>
    Create the test file with these scenarios:

    ```dart
    // Regression tests for 03-1-RESEARCH H3 verdict:
    // startManual() bypasses the TRK-01 motion filter because the filter runs
    // only while _currentState is TrackingIdle. Once startManual() transitions
    // to TrackingRecording, no further gate exists.
    //
    // These tests do NOT drive a fix to the production code — they lock in
    // current-correct behavior as a regression tripwire.

    import 'package:auto_explore/features/trips/domain/tracking_service.dart';
    import 'package:auto_explore/features/trips/domain/tracking_state.dart';
    import 'package:flutter_test/flutter_test.dart';

    void main() {
      group('TrackingService — H3 regression: startManual bypasses activity gate', () {
        test('manual trip accepts fixes with _lastActivityType=unknown', () async {
          // GIVEN: TrackingService with fake facade, no activity events ever fired.
          //        (implicit: _lastActivityType is null / defaults to unknown).
          final fake = FakeBackgroundGeolocationFacade();
          final service = /* build TrackingService(facade: fake, ...) */;

          // WHEN: startManual() called; then a fake onLocation event.
          await service.startManual();
          fake.emitLocation(/* fix at Berlin coords, accuracy 5m, speedKmh 30 */);

          // THEN: stateStream emitted a TrackingRecording with pointCount >= 1.
          final st = await service.stateStream.first;
          expect(st, isA<TrackingRecording>());
          expect((st as TrackingRecording).pointCount, greaterThanOrEqualTo(1));
        });

        test('manual trip accepts fixes with _lastActivityType=on_foot (non-vehicle)', () async {
          // GIVEN: activity fires "on_foot" (deliberately non-vehicle).
          final fake = FakeBackgroundGeolocationFacade();
          final service = /* build */;
          fake.emitActivityChange('on_foot');

          // WHEN: startManual() + onLocation.
          await service.startManual();
          fake.emitLocation(/* fix */);

          // THEN: pointCount still increments — the vehicle-gate did NOT apply
          //        because startManual() transitioned OUT of TrackingIdle.
          final st = await service.stateStream.firstWhere((s) => s is TrackingRecording);
          expect((st as TrackingRecording).pointCount, greaterThanOrEqualTo(1));
        });

        test('auto trip: motion=true WHILE TrackingIdle IS gated on activity', () async {
          // Contrapositive check: the gate still fires for auto trips.
          // GIVEN: no activity, or non-vehicle activity, and TrackingIdle state.
          final fake = FakeBackgroundGeolocationFacade();
          final service = /* build; do NOT call startManual */;

          // WHEN: motion=true event arrives while idle.
          fake.emitMotionChange(isMoving: true);

          // THEN: no TrackingRecording emitted (gate rejected).
          //         Use a timeout to prove no state change.
          await expectLater(
            service.stateStream.timeout(const Duration(milliseconds: 200)).firstWhere(
              (s) => s is TrackingRecording,
              orElse: () => const TrackingIdle(),
            ),
            completion(isA<TrackingIdle>()),
          );
        });
      });
    }
    ```

    Fixture-timestamp discipline (STATE Plan 03-04): use `DateTime.now()` for all fake fix timestamps — do not hardcode past dates.

    Use whatever `FakeBackgroundGeolocationFacade` seams already exist for `emitLocation` / `emitMotionChange` / `emitActivityChange`. If those don't exist as public helpers on the fake, add them — the fake lives at `test/features/trips/fakes/fake_background_geolocation_facade.dart` (or similar). This is Wave 1 test infrastructure additive.

    Do NOT touch production code.
  </action>
  <verify>
    `flutter test test/features/trips/tracking_service_motion_filter_regression_test.dart` — all 3 tests green.
    `flutter analyze` — zero errors.
    If either "manual bypasses gate" test fails, the research verdict on H3 was wrong. STOP, do not modify the test to make it pass. Escalate: the production code needs a fix, which belongs in 03-1-02.
  </verify>
  <done>
    Regression test file exists with 3 tests, all green. No production code changed.
  </done>
</task>

<task type="auto">
  <name>Task 2: H4 regression — stateStream emits per accepted fix with monotonic pointCount</name>
  <files>
    test/features/trips/tracking_service_state_stream_cadence_test.dart
  </files>
  <intent>Lock in the invariant that stateStream re-emits on every FixAccepted with monotonically increasing pointCount.</intent>
  <action>
    Create the test file:

    ```dart
    // Regression test for 03-1-RESEARCH H4 verdict:
    // stateStream re-emits on every FixAccepted with fresh distanceMeters,
    // pointCount, and currentSpeedKmh values. The live panel readback in
    // LiveTrackingPanel:20 is a plain ref.watch — cadence is per-fix, not
    // per-timer-tick.

    import 'package:auto_explore/features/trips/domain/tracking_service.dart';
    import 'package:auto_explore/features/trips/domain/tracking_state.dart';
    import 'package:flutter_test/flutter_test.dart';

    void main() {
      group('TrackingService — H4 regression: stateStream cadence', () {
        test('10 accepted fixes produce >= 10 TrackingRecording emissions with monotonic pointCount', () async {
          final fake = FakeBackgroundGeolocationFacade();
          final service = /* build TrackingService */;
          await service.startManual();

          final emissions = <TrackingRecording>[];
          final sub = service.stateStream.listen((s) {
            if (s is TrackingRecording) emissions.add(s);
          });

          // Fire 10 fixes ~50m apart at 1 Hz. All should be accepted by the
          // ingestor (accuracy 5m, speedKmh 30 — well within thresholds).
          final baseTs = DateTime.now();
          for (var i = 0; i < 10; i++) {
            fake.emitLocation(
              ts: baseTs.add(Duration(seconds: i)),
              lat: 52.5200 + i * 0.0005,   // ~55m north per step
              lon: 13.4050,
              accuracyMeters: 5,
              speedKmh: 30,
            );
          }

          // Let the event loop drain.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await sub.cancel();

          // Expect at least 10 emissions (start emission + 10 fix emissions =
          // 11 minimum; ingestor rate-limit may collapse some — accept >= 10).
          expect(emissions.length, greaterThanOrEqualTo(10));

          // Monotonic pointCount across the emissions.
          for (var i = 1; i < emissions.length; i++) {
            expect(
              emissions[i].pointCount,
              greaterThanOrEqualTo(emissions[i - 1].pointCount),
              reason: 'pointCount must be monotonically non-decreasing across '
                  'stateStream emissions',
            );
          }

          // Last emission reflects the last fix's speed.
          expect(emissions.last.currentSpeedKmh, closeTo(30, 0.5));
        });

        test('per-fix distance is monotonic non-decreasing', () async {
          // Same setup, tighter assertion.
          final fake = FakeBackgroundGeolocationFacade();
          final service = /* build */;
          await service.startManual();

          final distances = <double>[];
          final sub = service.stateStream.listen((s) {
            if (s is TrackingRecording) distances.add(s.distanceMeters);
          });

          final baseTs = DateTime.now();
          for (var i = 0; i < 5; i++) {
            fake.emitLocation(
              ts: baseTs.add(Duration(seconds: i)),
              lat: 52.5200 + i * 0.001,   // ~110m/step
              lon: 13.4050,
              accuracyMeters: 5,
              speedKmh: 40,
            );
          }

          await Future<void>.delayed(const Duration(milliseconds: 100));
          await sub.cancel();

          for (var i = 1; i < distances.length; i++) {
            expect(distances[i], greaterThanOrEqualTo(distances[i - 1]));
          }
          // At least one meaningful accumulation.
          expect(distances.last, greaterThan(200));
        });
      });
    }
    ```

    Same fixture-timestamp discipline: `DateTime.now()`-based fake timestamps.

    Adjust the exact API of `fake.emitLocation` to match whatever the FakeBackgroundGeolocationFacade already exposes (positional vs named args, `Location` object vs kwargs). If the fake accepts a `bg.Location`-shaped payload, construct one with the right field names — but do NOT import `bg.*` types into the test file (facade seam preservation applies to tests too where reasonable).
  </action>
  <verify>
    `flutter test test/features/trips/tracking_service_state_stream_cadence_test.dart` — both tests green.
    `flutter analyze` — zero errors.
    If either cadence test fails, the research verdict on H4 was wrong. STOP, do not silently drop the assertion. Escalate: the production code needs a fix (fold into 03-1-02 or a new plan).
  </verify>
  <done>
    Regression test file exists with 2 tests, all green. No production code changed.
  </done>
</task>

## Verification

- `flutter analyze` clean at repo root.
- `flutter test` full suite green.
- Two new test files exist, both wholly under `test/features/trips/`.
- Zero production files touched — verify with `git status` showing only new files under `test/`.

## SC alignment

- **SC1/SC2/SC3/SC4/SC5:** NOT directly this plan. This plan is defensive-only.
- **SC6 (In-car drive passes):** WEAK contributor. The tests catch a future regression on H3/H4 invariants; they do not themselves close any current bug (research REFUTED both).

## Deviation Handling

- If either test FAILS on first run: STOP and escalate. Failure means the research verdict was wrong — the code has a real bug and belongs in 03-1-02 (fold into Task 1 there or open a new task).
- If the FakeBackgroundGeolocationFacade doesn't expose the emit helpers this plan needs, add them additively — this is Wave 1 shared test infrastructure. Coordinate with 03-1-02's Task 1 which also extends the fake (startCallCount). Both plans should be able to extend the fake without conflict because they touch different accessors.
- If a test is flaky due to `Future.delayed(100ms)` racing with the stateController, increase the delay to 200 ms — this is a functional test, not a perf benchmark.
- If the H4 cadence test emits FEWER than 10 emissions due to rate-limiting inside the ingestor (STATE Plan 03-02 mentions rate-limit rules), lower the assertion to `>= 5` or space the fake fixes further apart (2 s intervals). The invariant is "emits per accepted fix", not "emits per input fix" — accept fixes are what matter.
- Iterate up to 3 times per task. If a test remains red for reasons other than a research-verdict mismatch, report the exact output.
