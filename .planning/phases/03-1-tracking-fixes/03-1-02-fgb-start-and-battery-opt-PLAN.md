---
id: 03-1-02
phase: 03-1-tracking-fixes
plan: 02
type: execute
wave: 2
depends_on: [03-1-01]
files_modified:
  - lib/features/trips/domain/tracking_service.dart
  - lib/features/trips/data/fgb_background_geolocation_facade.dart
  - lib/features/trips/data/background_geolocation_facade.dart
  - lib/features/onboarding/data/tracking_capability_repository.dart
  - lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart
  - test/features/trips/tracking_service_start_test.dart
  - test/features/onboarding/tracking_capability_repository_test.dart
autonomous: true
requirements: []

must_haves:
  truths:
    - "bg.BackgroundGeolocation.start() is invoked exactly once per real recording session on-device — three call sites in TrackingService (startManual, _openAutoTrip, init() hydration) each call `await _facade.start()` after `await _ensureFacadeReady()`"
    - "A failed `bg.BackgroundGeolocation.ready()` no longer disappears silently — `_ensureFacadeReady()` wraps the call in try/catch, records the outcome via the facade's new currentReadyOutcome (03-1-01), logs at severe, and rethrows a DomainError so upstream callers can surface a red banner"
    - "showIgnoreBatteryOptimizations()'s catch clause is `on Object` (not `on Exception`) per DomainError.wrap convention — no Error subclass silently escapes the fire-and-forget"
    - "TrackingCapability on Android considers Permission.ignoreBatteryOptimizations.status alongside statusAlways + statusNotification — a user who dismissed the Samsung Adaptive-Battery dialog no longer computes as fullAuto"
    - "Manual trips receive fixes on the Wave 3 drive — the observable outcome that H1 was the root cause; verified through the HUD (03-1-01) at trip start (acceptCount > 0 within ~3s)"
    - "flutter analyze and flutter test both green — behavior-sensitive change (facade lifecycle, capability computation), so full test suite runs inside the tight loop per project CLAUDE.md"
  artifacts:
    - path: "lib/features/trips/domain/tracking_service.dart"
      provides: "_facade.start() calls after _ensureFacadeReady() at three sites; _ensureFacadeReady() now wraps ready() in try/catch + logs severe + rethrows as DomainError.wrap"
    - path: "lib/features/trips/data/fgb_background_geolocation_facade.dart"
      provides: "showIgnoreBatteryOptimizations() catch widened to `on Object`; start() unchanged (already exists) — this plan just wires it up"
    - path: "lib/features/onboarding/data/tracking_capability_repository.dart"
      provides: "Capability computation reads Permission.ignoreBatteryOptimizations.status (via PermissionService.statusIgnoreBatteryOptimizations from 03-1-01) on Android; `fullAuto` requires all three grants"
    - path: "lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart"
      provides: "Post-dialog verification of the ignoreBatteryOptimizations grant; if not granted after `showIgnoreBatteryOptimizations()`, surface Samsung-specific copy in the denial banner"
  key_links:
    - from: "lib/features/trips/domain/tracking_service.dart:startManual"
      to: "lib/features/trips/data/background_geolocation_facade.dart:start"
      via: "await _facade.start() after await _ensureFacadeReady()"
      pattern: "await _facade.start()"
    - from: "lib/features/trips/domain/tracking_service.dart:_openAutoTrip"
      to: "lib/features/trips/data/background_geolocation_facade.dart:start"
      via: "await _facade.start() after await _ensureFacadeReady()"
      pattern: "await _facade.start()"
    - from: "lib/features/trips/domain/tracking_service.dart:init"
      to: "lib/features/trips/data/background_geolocation_facade.dart:start"
      via: "await _facade.start() only on the hydration branch (when an in-flight trip is recovered)"
      pattern: "await _facade.start()"
    - from: "lib/features/onboarding/data/tracking_capability_repository.dart"
      to: "lib/features/onboarding/data/permission_service.dart:statusIgnoreBatteryOptimizations"
      via: "capability computation reads all three permission rungs before deciding fullAuto vs manualOnly"
      pattern: "statusIgnoreBatteryOptimizations"
---

## Goal

Close H1 (FGB.start() dead code) and H5 (battery-opt grant unverified) — the two same-subsystem bugs that together explain every symptom of the failed 2026-07-06 drive on Samsung Android 14. Merged into one plan because both bugs touch `fgb_background_geolocation_facade.dart` and `tracking_service.dart` — file conflicts prevent parallel execution with a separate H5 plan.

## Context

- 03-1-RESEARCH §2.1 — smoking-gun evidence: `bg.BackgroundGeolocation.start()` has zero call sites in `lib/`. The facade defines it (`fgb_background_geolocation_facade.dart:117`), but nothing calls it. Per FGB 5.3.0's install guide, `ready()` alone leaves the plugin in "configured, not enabled" state — foreground service does not start, `onLocation`/`onMotionChange`/`onActivityChange` streams never deliver events. This single missing call explains: zero distance/speed (no fixes), no notification (foreground service down), no auto-trip (motion detection dark), app-reopen shows idle (bg.State.enabled=false).
- 03-1-RESEARCH §2.4 — `_ensureFacadeReady()` masks failed `ready()` calls. Callers at lines 146, 170, 428 do NOT wrap in try/catch. A `ready()` throw disappears through `unawaited`-swallowed and framework-level Riverpod async error paths. No log line above `Level.INFO` is ever emitted. Fix: wrap in try/catch, log at severe, and rethrow as `DomainError.wrap` so the caller can surface a red banner.
- 03-1-RESEARCH §6.1 / §6.2 — `showIgnoreBatteryOptimizations()` is fire-and-forget with `on Exception` catch. On Samsung, the user's dismissal is indistinguishable from a grant. `TrackingCapability` is computed from `statusAlways + statusNotification` only — the battery-opt grant is not consulted, so a dismissing user is misclassified as `fullAuto`.
- 03-1-RESEARCH §9 Risk 6 — widen the catch to `on Object` per Plan 01-04's `DomainError.wrap` convention (`avoid_catches_without_on_clauses` already suppressed at the wrap boundary per STATE decision Plan 03-01).
- 03-1-RESEARCH §9 Risk 1 — FGB claims `start()` is idempotent; test via `FakeBackgroundGeolocationFacade` counter to prevent regression.
- 03-1-RESEARCH §9 Risk 2 — do NOT pair `start()` with `stop()` on `stopActive()`. Use `changePace(false)` for pause (already what the code does). `stop()` kills the plugin and requires another `ready()` — probably NOT what we want. Explicit open question §11.1 — verify with a Wave 3 stop→start round-trip test.
- The FGB facade seam (STATE decision Plan 03-03) MUST be preserved. `flutter_background_geolocation` is imported ONLY by `fgb_background_geolocation_facade.dart`. Wave 2 changes MUST NOT leak `bg.*` types into `tracking_service.dart` — the `start()` call already goes through the abstract facade interface, so this is preserved by construction.
- Manual trips MUST NEVER gate on activity type (CONTEXT non-negotiable). Research §4 confirms current code is correct on this front — this plan changes nothing about the motion filter placement; it only adds the missing `start()` call. Regression test for this invariant lives in plan 03-1-04.
- Ralph-Loop tight loop: `flutter analyze` + `flutter test` (behavior-sensitive change, both required per project CLAUDE.md).
- Do NOT touch `bg.Config` — research §2.2 confirms every field is correct.
- Do NOT touch AndroidManifest — research §2.3 confirms.

## Tasks

<task type="auto">
  <name>Task 1: Add missing _facade.start() calls at three sites in TrackingService</name>
  <files>
    lib/features/trips/domain/tracking_service.dart
    test/features/trips/tracking_service_start_test.dart
  </files>
  <intent>Close H1 — the smoking-gun single-line-per-site fix.</intent>
  <action>
    Edit `lib/features/trips/domain/tracking_service.dart`. Three call sites need one added line each. Preserve surrounding order — `_ensureFacadeReady()` MUST run first (its try/catch guard is Task 2); `_facade.start()` runs immediately after and before any `changePace(true)`.

    **Site 1: `startManual()` (around line 170).** Current shape (approximate):
    ```dart
    Future<void> startManual() async {
      await _ensureFacadeReady();
      await _facade.changePace(isMoving: true);
      // ... state emit + trip open ...
    }
    ```
    New shape:
    ```dart
    Future<void> startManual() async {
      await _ensureFacadeReady();
      await _facade.start();              // <-- H1 fix
      await _facade.changePace(isMoving: true);
      // ... state emit + trip open ...
    }
    ```

    **Site 2: `_openAutoTrip()` (around line 428).** Same pattern — insert `await _facade.start();` immediately after `await _ensureFacadeReady();` and before any `changePace` call.

    **Site 3: `init()` hydration branch (around line 146).** ONLY the branch where hydration recovered an in-flight trip. Do NOT call `start()` when there is no trip to resume — that would spin up the FGS unnecessarily during cold app launch. The condition to gate this is whichever branch currently transitions to `TrackingRecording` from `init()`.

    Idempotency note (from research §9 Risk 1): FGB claims `start()` is idempotent. The fake in tests should count invocations and prove no adverse behavior on double-invoke.

    **Test: `test/features/trips/tracking_service_start_test.dart`.**
    - Assert `FakeBackgroundGeolocationFacade.startCallCount == 1` after `startManual()` completes.
    - Assert `startCallCount == 2` after `startManual() → stopActive() → startManual()` (each real recording session triggers exactly one `start()`).
    - Assert `startCallCount == 1` after hydration recovers an in-flight trip on `init()` — no double-start when the same session resumes.
    - Assert `startCallCount == 0` on cold `init()` with NO in-flight trip — hydration must not spin up FGS speculatively.
    - Assert `start()` is called AFTER `ready()` in every case (invocation order matters — FGB requires ready before start).

    If `FakeBackgroundGeolocationFacade` doesn't yet expose a `startCallCount` int or an invocation-order log, add one — it's Wave 1 test infrastructure additive to the existing fake.
  </action>
  <verify>
    grep for `_facade.start()` in `lib/features/trips/domain/tracking_service.dart` returns exactly 3 hits.
    `flutter analyze` — zero errors.
    `flutter test test/features/trips/tracking_service_start_test.dart` — green (all 5 assertions pass).
    `flutter test` (full suite) — green. Existing 141+ tests pass; the new tests add to that count.
  </verify>
  <done>
    Three `_facade.start()` calls landed at the three sites. FakeBackgroundGeolocationFacade counts calls; new test file green; full suite green.
  </done>
</task>

<task type="auto">
  <name>Task 2: Wrap _ensureFacadeReady() in try/catch + widen showIgnoreBatteryOptimizations catch</name>
  <files>
    lib/features/trips/domain/tracking_service.dart
    lib/features/trips/data/fgb_background_geolocation_facade.dart
  </files>
  <intent>Stop swallowing ready() failures + widen the fire-and-forget catch per DomainError.wrap convention.</intent>
  <action>
    **Step 1 — `_ensureFacadeReady()`.** In `lib/features/trips/domain/tracking_service.dart` around line 627:

    Current shape:
    ```dart
    Future<void> _ensureFacadeReady() async {
      if (_facadeReady) return;
      await _facade.ready();
      _facadeReady = true;
    }
    ```

    New shape:
    ```dart
    Future<void> _ensureFacadeReady() async {
      if (_facadeReady) return;
      try {
        await _facade.ready();
        _facadeReady = true;
      } on Object catch (e, st) {
        // ignore: avoid_catches_without_on_clauses — DomainError.wrap boundary
        _log.severe('FGB ready() failed: $e', e, st);
        // Do NOT set _facadeReady = true — future calls should re-try.
        // The facade's currentReadyOutcome (03-1-01) already recorded the failure;
        // rethrow as DomainError so the caller can surface it (red banner path
        // is TrackingNotifier's responsibility, out of this plan's scope).
        throw DomainError.wrap(e, stackTrace: st);
      }
    }
    ```

    (Assumes `_log` is the existing `Logger('tracking_service')` field. If the file uses a different logger reference, match the existing pattern — do not introduce a new logger name.)

    **Step 2 — Widen `showIgnoreBatteryOptimizations()` catch.** In `lib/features/trips/data/fgb_background_geolocation_facade.dart` around line 141:

    Current:
    ```dart
    Future<void> showIgnoreBatteryOptimizations() async {
      try {
        final req = await bg.DeviceSettings.showIgnoreBatteryOptimizations();
        await bg.DeviceSettings.show(req);
      } on Exception {
        // Swallowed
      }
    }
    ```

    New:
    ```dart
    Future<void> showIgnoreBatteryOptimizations() async {
      try {
        final req = await bg.DeviceSettings.showIgnoreBatteryOptimizations();
        await bg.DeviceSettings.show(req);
      } on Object catch (e, st) {
        // ignore: avoid_catches_without_on_clauses — fire-and-forget UX helper;
        // caller (permission_motion_notification_page) verifies the grant
        // post-return via Permission.ignoreBatteryOptimizations.status.
        _log.warning('showIgnoreBatteryOptimizations failed: $e', e, st);
      }
    }
    ```

    (If `_log` doesn't exist in the facade file, use `Logger('fgb_facade').warning(...)` — pattern per STATE Plan 02-03 decision "Logger('...') used directly — no AppLogger.instance class".)

    No test file changes for step 2 — the widened catch is a defensive improvement and unit-testing bg.DeviceSettings behavior requires platform-channel mocks (out of scope).

    Note on interaction with Task 1: `_ensureFacadeReady` now throws on `ready()` failure. Task 1's three call sites (`startManual`, `_openAutoTrip`, `init()` hydration) already `await` `_ensureFacadeReady()` — the thrown DomainError propagates to the caller. TrackingNotifier's error boundary is out of Phase 3.1 scope; the failure is observable via the HUD's `facadeReadyOutcome: FacadeReadyFailed(...)` from 03-1-01.
  </action>
  <verify>
    `flutter analyze` — zero errors. If `avoid_catches_without_on_clauses` fires, verify the inline `// ignore:` comment is present on the exact line and matches the STATE Plan 03-01 pattern.
    `flutter test` (full suite) — green. Existing tests must not regress; the new try/catch changes the exception TYPE for `ready()` failures (now `DomainError`, previously raw), so any test asserting the raw exception type needs to be updated to expect `DomainError` — fix in place.
    Manual smoke (deferred to Wave 3 drive): a forced `ready()` failure (e.g. by installing over an incompatible FGB version) surfaces a `severe` log line and a `FacadeReadyFailed` in the HUD.
  </verify>
  <done>
    `_ensureFacadeReady` wraps `ready()` in try/catch, logs severe, and rethrows `DomainError`. `showIgnoreBatteryOptimizations` widens to `on Object` with a warning log. No behavior change on the happy path.
  </done>
</task>

<task type="auto">
  <name>Task 3: TrackingCapability considers ignoreBatteryOptimizations grant on Android</name>
  <files>
    lib/features/onboarding/data/tracking_capability_repository.dart
    lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart
    test/features/onboarding/tracking_capability_repository_test.dart
  </files>
  <intent>Close H5 — a user who dismissed the Samsung Adaptive-Battery dialog no longer computes as fullAuto.</intent>
  <action>
    **Step 1 — Repository.** In `lib/features/onboarding/data/tracking_capability_repository.dart`:

    Extend the capability resolver to read `permissionService.statusIgnoreBatteryOptimizations()` on Android (03-1-01 exposes this method). iOS returns granted, so it degrades to a no-op there.

    Rule: `fullAuto` requires ALL of `statusAlways.isGranted` + `statusNotification.isGranted` + (Android-only) `statusIgnoreBatteryOptimizations.isGranted`. Otherwise → `manualOnly`.

    Preserve the existing `!isGranted` universal predicate (STATE decision Plan 03-05) — covers denied/restricted/limited/permanentlyDenied uniformly. Do NOT use `isDenied` alone.

    **Step 2 — Onboarding ladder.** In `lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart`:

    After `await ref.read(backgroundGeolocationFacadeProvider).showIgnoreBatteryOptimizations();` returns (line ~43), verify the grant:
    ```dart
    final battOptStatus = await ref.read(permissionServiceProvider).statusIgnoreBatteryOptimizations();
    if (Platform.isAndroid && !battOptStatus.isGranted) {
      _log.info('User did not grant ignoreBatteryOptimizations — capability degrades to manualOnly.');
      // The denial banner (Plan 03-05) already handles the recovery path
      // when capability != fullAuto — no dedicated UI branch needed here.
    }
    ```

    The `_resolveAndFinish()` call directly after will now pick up the new capability from the updated repository (Step 1), so no explicit banner-copy change is required. The denial banner from Plan 03-05 remains the single recovery UI.

    Do NOT re-issue the dialog or add a Settings deep-link here — the ladder is single-pass. The denial banner (STATE Plan 03-05 decision) handles ongoing user recovery.

    **Step 3 — Test.** `test/features/onboarding/tracking_capability_repository_test.dart` (extend existing file, or create if missing):

    - `statusAlways.granted + statusNotification.granted + statusIgnoreBatteryOptimizations.granted` on Android → capability = fullAuto.
    - `statusAlways.granted + statusNotification.granted + statusIgnoreBatteryOptimizations.denied` on Android → capability = manualOnly.
    - `statusAlways.granted + statusNotification.granted` on iOS (statusIgnoreBatteryOptimizations returns granted per stub) → capability = fullAuto.
    - `statusAlways.denied + all others granted` → capability = manualOnly (regression — the classic denial path still works).

    Stub PermissionService with a fake returning fixed statuses per test case. Follow the STATE Plan 03-05 pattern of injecting via ProviderScope.overrides in tests.
  </action>
  <verify>
    `flutter analyze` — zero errors.
    `flutter test test/features/onboarding/tracking_capability_repository_test.dart` — green (all 4 assertions).
    `flutter test` (full suite) — green.
    grep for `statusIgnoreBatteryOptimizations` in `lib/features/onboarding/data/tracking_capability_repository.dart` returns ≥ 1 hit.
  </verify>
  <done>
    Capability computation reads all three grants on Android. Onboarding ladder verifies the grant post-dialog. Test file green with 4 cases covering Android grant/deny and iOS pass-through.
  </done>
</task>

## Verification

- `flutter analyze` clean at repo root.
- `flutter test` full suite green (behavior-sensitive: FGB lifecycle + capability computation).
- grep `_facade.start()` in `lib/features/trips/domain/tracking_service.dart` → 3 hits.
- grep `on Object` in `lib/features/trips/domain/tracking_service.dart` + `lib/features/trips/data/fgb_background_geolocation_facade.dart` → ≥ 2 hits combined (the two widened catches).
- grep `statusIgnoreBatteryOptimizations` in `lib/features/onboarding/` → ≥ 2 hits (repository + ladder verification).
- HUD from 03-1-01 shows `facadeReadyOutcome: FacadeReadySuccess` immediately after first tracking use on-device (Wave 3 confirmation, not this task's verify).
- Manual on-device verification of the H1 fix itself is DEFERRED to Wave 3 (03-1-05); this plan closes on the passing test suite plus the HUD's testable readiness.

## SC alignment

- **SC1 (Debug HUD):** NOT this plan (03-1-01 owns).
- **SC2 (Manual trip: fix intake within 3 s, distance + speed update every ≤5 s, polyline persists):** DIRECTLY SATISFIED by H1 fix. Adding `_facade.start()` at `startManual()` is the missing link — once FGB actually delivers fixes, the pre-existing ingestor → stateStream → panel chain (research §5.1) works.
- **SC3 (Auto trip: pending within 60 s of in_vehicle, auto-terminates after 2 min):** DIRECTLY SATISFIED by H1 fix at `_openAutoTrip`. Motion detection also requires `start()`.
- **SC4 (Persistent notification visible during any active trip):** DIRECTLY SATISFIED by H1 fix — foreground service does not launch without `start()`; once launched, the pre-existing bg.Config notification block (research §2.2) drives the notification.
- **SC5 (Map camera follows during recording):** NOT this plan (03-1-03 owns H2).
- **SC6 (In-car drive passes):** BLOCKING contributor. Without Task 1's H1 fix, the drive is guaranteed to fail again. This plan is one of three Wave 2 plans that Wave 3 gates on.

## Deviation Handling

- If FGB's `start()` throws when called on an already-started plugin (contradicting the docs' idempotency claim), catch the specific FGB exception in the facade and translate to a no-op with a `warning` log. Do NOT retry on failure without diagnosis — a repeatable throw is a real bug.
- If `DomainError.wrap` isn't the right shape for the try/catch wrap (e.g., it wants a specific subtype like `PermissionError` for permission failures), match the existing Plan 01-04 pattern — the `_ensureFacadeReady` failure is a `DomainError` sub-kind (probably `UnknownError` or a new `TrackingReadyError` if the sealed hierarchy warrants extension; defer to the existing shape).
- If `permission_motion_notification_page.dart` doesn't have a `_log` field, add a `final _log = Logger('permission_motion_notification_page');` at the file top per STATE Plan 03-05 pattern.
- If a widget test breaks because a fake PermissionService doesn't yet implement `statusIgnoreBatteryOptimizations` (added by 03-1-01), that's a Wave 1 test-fake gap — update the fake to add the method with a default `granted` return.
- Iterate up to 3 times per task; if any test remains red after 3 attempts, stop and report the exact failing test output.
