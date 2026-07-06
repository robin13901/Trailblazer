# Phase 3.1 · Tracking Fixes — Research

**Researched:** 2026-07-06
**Domain:** flutter_background_geolocation (FGB 5.3.0) integration, MapLibre `MyLocationTrackingMode`, `TrackingService` state machine correctness, permission ladder audit on Samsung Android 14.
**Confidence:** HIGH on every H1–H5 verdict below — all evidence is from live source, not training data. Individual sub-findings marked inline.

## §0 Summary

The Phase 3 in-car drive failed for four discrete, independently-verifiable reasons. Reading the codebase against the five hypotheses yields:

- **H1 = CONFIRMED (highest-impact bug).** `bg.BackgroundGeolocation.start()` is **never called anywhere in `lib/`**. The facade exposes `start()` (`fgb_background_geolocation_facade.dart:117`) but no code invokes it. `startManual()` calls only `ready()` + `changePace(true)` — and per FGB's contract, `changePace()` on an un-`start()`-ed plugin is a no-op. This alone explains: no fixes, no notification, no auto-trip (motion detection also requires `start()`). Fix scope: one line.
- **H2 = CONFIRMED.** `FollowMode` never transitions to `location`/`locationAndHeading` on trip start. No code writes `cameraStateProvider.notifier.setFollowMode(...)` in response to `TrackingRecording`. The map's `myLocationTrackingMode` is therefore driven only by pan-dismiss (→ `none`) and the manual recenter button. Fix scope: one listener wiring the tracking state to the camera notifier.
- **H3 = CONFIRMED (partial).** The TRK-01 motion filter (`tracking_service.dart:378-391`) only runs on **motion=true arrival while `TrackingState is TrackingIdle`**. `startManual()` bypasses that gate correctly — the code path is clean. **However:** manual trips do gate on `onLocation` arrivals having no relationship to activity classification, so filter-wise manual is not broken. The real "manual-vs-auto" split needed is different: manual trips currently never receive fixes because `start()` was never called (H1). Once H1 is fixed, manual trips will not be gated by TRK-01. Verified.
- **H4 = REFUTED.** `stateStream` re-emits on every accepted fix (`tracking_service.dart:266-276`, inside the `FixAccepted` case). The panel would update if fixes arrived. `TrackingRecording.currentSpeedKmh` is fed from `outcome.speedKmh` on every accept. Panel readback is via `ref.watch(trackingStateProvider)` in `LiveTrackingPanel:20`. All wiring is correct; the panel showed zeros only because zero fixes were ever accepted (H1).
- **H5 = PARTIAL.** `showIgnoreBatteryOptimizations()` **is called** in the onboarding ladder (`permission_motion_notification_page.dart:41-43`), but its **result is not verified** — the code fires-and-forgets the intent, then reads `statusAlways` + `statusNotification` to compute `TrackingCapability`. There is no code path that inspects `Permission.ignoreBatteryOptimizations.status` (permission_handler exposes it as of `^12.0.3`). If the user dismissed the Samsung Adaptive-Battery dialog, we'd never know. Fix scope: add a diagnostic surface (HUD in Wave 1, banner escalation in Wave 2).

**Primary recommendation:** Keep the CONTEXT's wave breakdown (HUD → three parallel fixes → drive). The wave-1 HUD is required to observe H1's fix landing; the wave-2 fixes are small and independent. Two additional gotchas surfaced (§7): the HUD needs a **new `TrackingService.diagnostics()` getter** because per-fix reject counters are not currently exposed anywhere, and the FGB facade needs a **`ready()` success/failure signal** because it currently silently swallows via the `_facadeReady = true` flag on the caller side without confirming `bg.BackgroundGeolocation.ready()` actually succeeded.

## §1 Evidence Summary

| Hypothesis | Verdict | Key citation |
|---|---|---|
| H1 — FGB.start() never called | **CONFIRMED** | `fgb_background_geolocation_facade.dart:117` defines `start()`; `grep -rn "facade\.start\|BackgroundGeolocation\.start" lib/` returns zero call sites |
| H1a — bg.Config missing fields | REFUTED (config is complete) | `fgb_background_geolocation_facade.dart:34-61` — `stopOnTerminate:false`, `startOnBoot:true`, `enableHeadless:true`, notification channel wired |
| H1b — POST_NOTIFICATIONS not requested | REFUTED (requested), PARTIAL (unverified) | Manifest declares it (`AndroidManifest.xml:32`); ladder calls `svc.requestNotification()` (`permission_motion_notification_page.dart:39`); `statusNotification` is later checked (`:55-56`) |
| H1c — `_facadeReady` masks failed ready() | CONFIRMED | `tracking_service.dart:627-631` — `_facadeReady = true` is set unconditionally after `await _facade.ready()`; on throw, the `try {}` is upstream in the caller which does NOT wrap `_ensureFacadeReady()` in try/catch (`:170`, `:428`, `:146`) |
| H2 — Map camera-follow not activated | **CONFIRMED** | `cameraStateProvider.notifier.setFollowMode(...)` has only two callers: `map_widget.dart:191` (`onCameraTrackingDismissed → none`) and `recenter_button.dart:54-55` (`FollowMode.location`). Nothing listens to `trackingStateProvider` and drives the camera |
| H3 — TRK-01 filter gates manual trips | REFUTED | `tracking_service.dart:373-391` — the filter only runs in `_onMotionChange` while `state is TrackingIdle`. `startManual()` directly `_emitState(TrackingRecording(...))` (`:184-190`) so subsequent `_onMotionChange(isMoving:true)` skips the gate. `_onLocation` (`:239`) has no activity gate at all |
| H4 — stateStream doesn't re-emit per fix | REFUTED | `tracking_service.dart:266-276` — every `FixAccepted` case emits a fresh `TrackingRecording` with `_ingestor!.totalDistanceMeters`, `pointCount`, `outcome.speedKmh` |
| H5 — Battery-opt grant not verified | PARTIAL | `showIgnoreBatteryOptimizations()` called (`permission_motion_notification_page.dart:41-43`); its outcome is not read anywhere. `permission_handler ^12.0.3` supports `Permission.ignoreBatteryOptimizations.status` per package docs — currently unused |

## §2 H1 — FGB not emitting fixes (CONFIRMED)

### §2.1 The smoking gun: `start()` is dead code

`fgb_background_geolocation_facade.dart:117`:
```dart
@override
Future<void> start() => bg.BackgroundGeolocation.start();
```

Grep across `lib/**/*.dart` for `facade.start()`, `_facade.start()`, or `BackgroundGeolocation.start()` produces **zero matches**. The abstract method `BackgroundGeolocationFacade.start()` (`background_geolocation_facade.dart:17`) is declared and implemented but never invoked.

Per FGB 5.3.0's install guide (`.planning/phases/03-tracking-mvp/03-RESEARCH.md:110`):
```
await bg.BackgroundGeolocation.ready(...);   // configures + primes
await bg.BackgroundGeolocation.start();      // begin motion detection ← MISSING
```

Without `start()`:
- The plugin sits in "configured, not enabled" state.
- The foreground service is NOT started → no persistent notification, no wake lock, no ACCESS_BACKGROUND_LOCATION consumption.
- `onLocation` / `onMotionChange` / `onActivityChange` streams remain wired inside `ready()` (`fgb_background_geolocation_facade.dart:63-84`) but the plugin does not deliver events.
- `changePace(true)` on an un-started plugin is documented to be a no-op — it flips the internal `isMoving` flag but does not initiate location delivery because the location manager hasn't been started.

**This explains every observation from the failed drive:**
- Distance/speed = 0 → onLocation never fires
- No notification → foreground service never started
- No auto-trip → onMotionChange never fires
- App reopen mid-drive shows idle → `bg.State.enabled` is false, so cold-start hydration finds no in-flight trip

**Fix location:** `TrackingService.startManual()` (`tracking_service.dart:166`) and `_openAutoTrip()` (`:425`) and the `init()` hydration path (`:146`) need to call `_facade.start()` after `_ensureFacadeReady()`. Idempotent per FGB docs — safe to call multiple times.

### §2.2 `bg.Config` is otherwise complete

Every field required for Android FGS + 1 Hz + boot-survival is present in `fgb_background_geolocation_facade.dart:34-61`:

| Field | Value | Purpose |
|---|---|---|
| `desiredAccuracy` | `DESIRED_ACCURACY_HIGH` | High-accuracy GPS |
| `distanceFilter` | `0` | Deliver every update |
| `locationUpdateInterval` | `1000` | 1 Hz |
| `stopOnTerminate` | `false` | Service survives task-kill |
| `startOnBoot` | `true` | Survives reboot |
| `enableHeadless` | `true` | Dart isolate wakes on background events |
| `notification.title` | `'Trailblazer'` | FGS notification title |
| `notification.text` | `'Recording · 00:00 · 0.0 km · — km/h'` | Initial text |
| `notification.channelName` | `'Trip recording'` | Android notification channel |
| `notification.channelId` | `'trailblazer.tracking'` | Stable channel id |
| `notification.priority` | `bg.NotificationPriority.low` | No sound, visible on lockscreen |
| `notification.smallIcon` | `'mipmap/ic_launcher'` | Uses launcher icon |
| `notification.sticky` | `true` | Not dismissible |
| `showsBackgroundLocationIndicator` | `true` | iOS blue bar |
| `pausesLocationUpdatesAutomatically` | `false` | Dart owns pause logic |
| `debug` | `kDebugMode` | Beep sounds in debug |
| `logLevel` | `LOG_LEVEL_VERBOSE` | Native logging |

**No config field is missing.** Wave-2 audit should NOT change these values without a specific reason.

### §2.3 AndroidManifest is correct

`android/app/src/main/AndroidManifest.xml`:
- Line 32: `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`
- Lines 14-16: `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION`
- Lines 11-12: `ACCESS_BACKGROUND_LOCATION`
- Line 19: `ACTIVITY_RECOGNITION`
- Line 35: `WAKE_LOCK`
- Lines 72-77: no user-side `<service>` declaration (Phase-1 placeholder was correctly deleted per Plan 03-03 SUMMARY)

No manifest change required.

### §2.4 The `_facadeReady` guard swallows `ready()` failures

`tracking_service.dart:627-631`:
```dart
Future<void> _ensureFacadeReady() async {
  if (_facadeReady) return;
  await _facade.ready();
  _facadeReady = true;
}
```

Callers (`:146`, `:170`, `:428`) invoke `_ensureFacadeReady()` **without wrapping in try/catch**. If `bg.BackgroundGeolocation.ready()` throws (license failure, native plugin uninitialized, malformed config), the exception propagates up to `startManual()` / `_openAutoTrip()` / `init()` — but from there:

- `startManual()` is called from `TrackingNotifier.startManual()` (`tracking_state_provider.dart:31`) which returns the raw Future to the FAB. `TripFab` (widget) awaits it without a boundary catch → the exception surfaces as a Riverpod async error in the framework, not in a user-visible way.
- `_openAutoTrip()` is `unawaited` (`:390`) → any throw is silently lost.
- `init()` is `unawaited` inside the notifier's `build()` (`tracking_state_provider.dart:24`) → same silent-loss path.

There is no place today where a failed `ready()` produces a log line above `Level.INFO`. The `_facadeReady` flag is set to `true` only AFTER `ready()` returns, so a throw at least prevents future spurious `_facadeReady = true`, but the caller is not informed.

**Wave-2 change needed:** `_ensureFacadeReady()` should wrap `_facade.ready()` in try/catch, log `severe`, and expose the outcome (success/error/nulled) via a getter that the HUD can read. Also consider surfacing a red banner if `ready()` fails.

### §2.5 iOS UIBackgroundModes + `pod install`

`ios/Runner/Info.plist:61-66`: `UIBackgroundModes = [location, bluetooth-central, fetch]` — all three required for FGB (per Plan 03-03 decision). No change needed.

`pod install` is still in Pending Todos (STATE.md line 235) — must run on macOS before first iOS build. **Out of scope for Phase 3.1** (drive was on Android; iOS unverified). Do not conflate.

## §3 H2 — Map camera-follow not activated (CONFIRMED)

### §3.1 Wiring gap

Follow-mode state lives in `CameraState.followMode` (`camera_state.dart:20`) with three values: `none`, `location`, `locationAndHeading`. The MapLibre widget consumes this via `map_widget.dart:150-176`:

```dart
final isFollowing =
    cameraState.followMode == FollowMode.location ||
    cameraState.followMode == FollowMode.locationAndHeading;
...
myLocationTrackingMode: isFollowing
    ? MyLocationTrackingMode.tracking
    : MyLocationTrackingMode.none,
```

**All producers of `setFollowMode(...)` in `lib/`:**

| Site | Action |
|---|---|
| `map_widget.dart:191` (`onCameraTrackingDismissed`) | `FollowMode.none` — pan/rotate dismiss |
| `recenter_button.dart:54-55` | `FollowMode.location` — manual tap |
| `recenter_button.dart:79-80` | `FollowMode.none` — fail-recovery |

No producer reacts to `trackingStateProvider` or `TrackingState`. There is nothing in the app that says "trip started → follow camera." Verified via grep: `trackingStateProvider` is watched by `TripFab`, `LiveTrackingPanel`, and (indirectly) `TrackingNotifier` — none of which touch the camera.

### §3.2 The `FollowMode.locationAndHeading` slot

Confirmed per STATE.md decision Plan 02-03 (line 94) and `follow_mode.dart:16-17`:
> Phase 3 (Tracking MVP) will activate `locationAndHeading` during active trip recording — the enum slot is reserved here so that Phase 3 does not touch the camera state shape.

**This wiring was never done.** Plan 03-06 landed FAB+panel+timer but did not connect the tracking state to the camera state.

### §3.3 What the fix looks like

The MapLibre binding for heading-lock is `MyLocationTrackingMode.trackingCompass` (Phase 2 uses `.tracking` for `location`, `.trackingCompass` for `locationAndHeading`). Currently the widget maps both `location` and `locationAndHeading` to `.tracking` — a second bug: `.trackingCompass` never activates. Fix must:
1. Add a listener that watches `trackingStateProvider` and calls `setFollowMode(FollowMode.locationAndHeading)` on `TrackingRecording`.
2. On `TrackingIdle`, revert to the pre-recording mode (either `location` if it was set, or `none` if user had panned during the trip).
3. Extend `map_widget.dart:174` to map `locationAndHeading → MyLocationTrackingMode.trackingCompass` (currently both branches produce `.tracking`).
4. Ensure a user pan mid-trip (`onCameraTrackingDismissed → FollowMode.none`) doesn't fight the tracking listener — one-shot activation on trip start, then user is in charge.

Recommended seam: a small `ProviderSubscription`-style listener inside a `ConsumerStatefulWidget` (a wrapper around `MapWidget`, or a listener registered in `MapScreen`).

## §4 H3 — Motion filter for manual trips (REFUTED)

### §4.1 Filter placement

`tracking_service.dart:373-391`:

```dart
void _onMotionChange(MotionChange mc) {
  if (mc.isMoving) {
    if (_currentState is TrackingIdle) {  // ← guard
      final activityFresh = ...;
      if (_lastActivityType != 'in_vehicle' || !activityFresh) {
        _log.fine('motion=true discarded: ...');
        return;
      }
      unawaited(_openAutoTrip(mc.ts));
    }
    ...
  }
  ...
}
```

The `in_vehicle`/`activityFresh` gate **only runs while `_currentState is TrackingIdle`**. Once `startManual()` transitions to `TrackingRecording` (`:184-190`), subsequent `_onMotionChange` events skip the entire filter block. Manual trips are NOT gated by activity type.

### §4.2 `_onLocation` has no activity gate

`_onLocation` (`:239-289`) reads `_currentState`, checks `TrackingRecording`, and feeds the ingestor. There is no activity-type check in the fix acceptance path — the ingestor's rules are accuracy/rate-limit/gap/split only (`trip_fix_ingestor.dart:189-239`).

### §4.3 Verdict

The failed drive's zero-distance-manual-trip symptom is fully explained by H1. Once `start()` is called, manual trips will receive fixes and the ingestor will accept them (subject to accuracy filter — a 5m-accuracy fix passes trivially).

**However,** the CONTEXT's suggested "manual-vs-auto split" is worth doing anyway as a defensive measure: introduce a `TrackingService.startAuto()` vs `startManual()` distinction that is already implicit today (they call `_openAutoTrip` vs `openTrip(manuallyStarted:true)`). The current code is correct; no refactor needed for correctness, but the intent could be made explicit and tested. Wave-2 authors should decide: leave as-is (green tests) or add explicit split (defensive + testable). **Recommendation: LEAVE AS-IS**, add unit test asserting "startManual bypasses TRK-01 filter" for future regression protection.

## §5 H4 — stateStream re-emission cadence (REFUTED)

### §5.1 Emission cadence is per-accept

`tracking_service.dart:266-276`:

```dart
case FixAccepted():
  ...
  final current = _currentState;
  if (current is TrackingRecording) {
    _emitState(TrackingRecording(
      tripId: tripId,
      startedAt: current.startedAt,
      distanceMeters: _ingestor!.totalDistanceMeters,
      pointCount: _ingestor!.pointCount,
      manuallyStarted: current.manuallyStarted,
      currentSpeedKmh: outcome.speedKmh,
    ));
  }
```

Every accepted fix emits a fresh `TrackingRecording` on `stateStream` with:
- `distanceMeters` = ingestor's running total (`trip_fix_ingestor.dart:172`)
- `pointCount` = ingestor's `_pointCount` (`:175`)
- `currentSpeedKmh` = the fix's speedKmh (`:255`)

`_emitState()` (`:633-638`) unconditionally does `_stateController.add(state)`.

### §5.2 Panel readback

`live_tracking_panel.dart:20`: `final state = ref.watch(trackingStateProvider);` — Riverpod re-renders on every state change. `distanceMeters`, `currentSpeedKmh` are read directly (`:28-29`). No memoization or async gap.

### §5.3 Verdict

The live-panel readback is correct. Distance/speed stayed at zero only because zero fixes were ever accepted (H1). No fix needed.

## §6 H5 — Samsung OEM battery kill (PARTIAL)

### §6.1 What is called

`permission_motion_notification_page.dart:29-49`:

```dart
Future<void> _onPrimary() async {
  ...
  final svc = ref.read(permissionServiceProvider);
  if (Platform.isIOS) {
    await svc.requestSensors();
  } else {
    await svc.requestNotification();
    await ref.read(backgroundGeolocationFacadeProvider)
             .showIgnoreBatteryOptimizations();  // ← fire-and-forget
  }
  await _resolveAndFinish();
}
```

`showIgnoreBatteryOptimizations()` in `fgb_background_geolocation_facade.dart:134-146`:

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

**Two problems:**
1. **Return type is `Future<void>`** — no way for the caller to know whether the user granted, denied, or the dialog even appeared.
2. **The Exception catch is unbounded** — a user-dismissed dialog on Samsung Adaptive Battery would appear indistinguishable from a successful grant.

### §6.2 What is NOT checked

`_resolveAndFinish()` (`:51-68`) computes `TrackingCapability` from only `statusAlways` + `statusNotification`. **The battery-optimization grant is not consulted anywhere.** A user who granted `Always` location and `Notification` but dismissed the battery-optimization dialog is persisted as `fullAuto` — which is a misclassification on Samsung.

`permission_handler ^12.0.3` exposes `Permission.ignoreBatteryOptimizations.status` per the package's public API. Verified via package docs: on Android 6+, `.status` returns `granted` iff the app is on the ignore-battery-optimizations allowlist. **Currently unused in the codebase** (grep for `ignoreBatteryOptimization` / `IgnoreBatteryOpt` in `lib/`: no matches).

### §6.3 What the fix looks like

For Wave 1 (HUD): read `Permission.ignoreBatteryOptimizations.status` (Android only) and expose it live so the drive tester can see the grant state before starting. For Wave 2: extend the ladder to VERIFY the grant post-dialog and, if denied, escalate to a Settings deep-link in the yellow banner. Consider a dedicated banner variant "Samsung Adaptive Battery is on — tap to allow Trailblazer".

**Non-scope:** Samsung's proprietary "Deep Sleep" / "Never sleeping apps" list is NOT exposed via standard Android APIs. The only heuristic is "user has granted ignoreBatteryOptimizations" — beyond that, we rely on FGB's own SDK behavior. Do not attempt to probe Samsung-specific APIs.

## §7 Debug HUD Data Sources

**What can be read TODAY without new API:**

| Field | Source | Notes |
|---|---|---|
| Permission status: whenInUse | `PermissionService.statusAlways()` — actually returns `locationAlways.status`, use `Permission.locationWhenInUse.status` directly | Needs a new method on `PermissionService` |
| Permission status: Always | `PermissionService.statusAlways()` (`permission_service.dart:47-48`) | Ready |
| Permission status: Notification | `PermissionService.statusNotification()` (`:51-52`) | Ready |
| Permission status: ActivityRecognition | Direct `Permission.activityRecognition.status` | New method needed |
| Permission status: IgnoreBatteryOptimizations | Direct `Permission.ignoreBatteryOptimizations.status` | New method needed |
| Tracking state | `ref.watch(trackingStateProvider)` | Ready |
| Distance / point count / speed | `TrackingRecording.distanceMeters`/`pointCount`/`currentSpeedKmh` | Ready |
| TrackingCapability | `trackingCapabilityRepositoryProvider.load()` (`tracking_capability_repository.dart:20-25`) | Ready |
| FGB.state (enabled + isMoving) | `BackgroundGeolocationFacade.currentState()` (`background_geolocation_facade.dart:39`) | Ready — returns `FgbState(enabled, isMoving)` |
| Last-fix timestamp / coords / accuracy | `TrackingService._lastAcceptedFix` (private) | **Needs new getter** |
| Last activity type + timestamp | `TrackingService._lastActivityType` / `_lastActivityAt` (private) | **Needs new getter** |
| Ingestor accept/reject counters | `TrackingService._ingestor` (private) + ingestor has no reject counters | **Needs new counters in `TripFixIngestor`** — currently only `pointCount` is exposed; `FixRejected` reasons are only logged (`tracking_service.dart:279`) |
| Last reject reason | Nowhere today | **Needs to be added** — trivially in `_onLocation`'s `FixRejected` case |
| _facadeReady state | `TrackingService._facadeReady` (private) | **Needs new getter** |
| ready() outcome (success/error) | Currently no signal | **Needs to be tracked** — extend `_ensureFacadeReady()` to record last exception |

### §7.1 Recommended `TrackingService.diagnostics()` shape

A single `TrackingDiagnostics` DTO exposing all the private fields, published via a getter. Adding this at the seam boundary keeps the HUD read-only and satisfies "Reads state via existing service seams" from CONTEXT §Suggested wave breakdown Wave 1.

Fields (~15):
- `facadeReadyOutcome: FacadeReadyOutcome` (`pending` / `success` / `failed(String message)`)
- `facadeCurrentState: FgbState?` (nullable — hydrated on demand)
- `lastAcceptedFix: {ts, lat, lon, accuracy, speedKmh}?`
- `lastRejectedReason: String?` + `lastRejectedAt: DateTime?`
- `lastActivityType: String`
- `lastActivityAt: DateTime?`
- `acceptCount: int` (running)
- `rejectCount: int` (running, keyed by reason: accuracy/rate_limit/duplicate)
- `gapCount: int` / `splitCount: int`
- `currentTripId: int?`

For counters, either add them to `TripFixIngestor` (mutation to a 22-test class — risky) OR track them at the `TrackingService._onLocation` level as separate ints (simpler, less risk). **Recommend the latter** — TrackingService owns counters, ingestor stays pure.

### §7.2 Riverpod exposure

New `Provider<TrackingDiagnostics>` or `StreamProvider<TrackingDiagnostics>` reading from `TrackingService`. If reactive, `TrackingService` needs a `Stream<TrackingDiagnostics>` — a broadcast controller ticking on every `_onLocation` outcome + a 1 Hz timer for currentState updates. Watch this consumes stream resources; alternative is a periodic `ref.invalidate()` from a `Timer.periodic` inside the HUD screen. **Recommend the polling approach** — simpler, HUD is dev-only, no need to over-engineer.

### §7.3 HUD entry point

Settings screen currently is a stub (`settings_screen.dart:14-38`). Add a `DEV` section (kDebugMode-gated) with a `ListTile('Tracking diagnostics')` → pushes `/settings/diagnostics`. New GoRoute at `/settings/diagnostics` in `app_router.dart`, guarded by `kDebugMode`.

## §8 Recommended Plan Structure

CONTEXT's wave breakdown is sound. Small adjustments below.

### Wave 1 (must ship first)

**Plan 3.1-01: Debug HUD** — matches CONTEXT verbatim. Additional scoping:
- Introduce `TrackingDiagnostics` DTO in `lib/features/trips/domain/tracking_diagnostics.dart`.
- Add private counters + `TrackingService.diagnostics()` getter (~20 LOC in `tracking_service.dart`).
- Extend `PermissionService` with `statusWhenInUse()`, `statusActivityRecognition()`, `statusIgnoreBatteryOptimizations()`.
- Screen at `lib/features/settings/presentation/tracking_diagnostics_screen.dart`, gated by `kDebugMode`.
- Route: `/settings/diagnostics`.
- HUD polls via `Timer.periodic(500ms)` + `setState` for live-fix updates.

### Wave 2 (parallelizable — three fixes)

**Plan 3.1-02: FGB integration fix (H1 + H5-diagnostic).**
- Add `_facade.start()` call after `_ensureFacadeReady()` in `startManual()`, `_openAutoTrip()`, and `init()` hydration branch (three sites).
- Wrap `_ensureFacadeReady()` in try/catch, record last exception, expose via diagnostics.
- Widget/unit test via `FakeBackgroundGeolocationFacade`: assert `start()` is called after `ready()` on manual trip start.
- Extend `PermissionService.statusIgnoreBatteryOptimizations()`; verify `TrackingCapability.fullAuto` requires all three (always + notification + battery-opt on Android).
- No `bg.Config` changes.

**Plan 3.1-03: Live-stats sanity + defensive manual-vs-auto test (H3 + H4).**
- H4 is REFUTED — no code change. Add regression test: "10 FixAccepted events produce 10 stateStream emissions with monotonically increasing pointCount."
- H3 is REFUTED — no code change. Add regression test: "startManual bypasses TRK-01 activity gate — even with `_lastActivityType='unknown'`, subsequent onLocation fixes are accepted."
- **Recommend LEAVE 03 as a testing-only plan** — no production code changes, but locks in the invariants for future refactors. If checker pushes back on "no code change," fold into 3.1-02.

**Plan 3.1-04: Map camera-follow (H2).**
- Add a listener widget or listener registration that watches `trackingStateProvider` and calls `cameraStateProvider.notifier.setFollowMode(FollowMode.locationAndHeading)` on `TrackingRecording`, `FollowMode.none` on `TrackingIdle`.
- Fix `map_widget.dart:174` — currently both `location` and `locationAndHeading` map to `MyLocationTrackingMode.tracking`; heading-lock requires `.trackingCompass`.
- Widget test asserts the tracking mode transitions on trip start/stop.
- Keep user pan-dismiss precedence: if user pans mid-trip, `onCameraTrackingDismissed → FollowMode.none` wins until next trip start.

### Wave 3 (checkpoint)

**Plan 3.1-05: In-car re-verification + close-out.** Unchanged from CONTEXT.

### Alternative structure considered — REJECTED

**Reject** merging H1 and H2 into one plan: H2's fix touches `map_widget.dart` and adds a new listener wiring; H1's fix touches `tracking_service.dart` only. Different owners can execute in parallel. Merging costs no lines of code but adds coordination overhead.

**Reject** deferring H5 (battery-opt verification) to a future phase: the fix is small (one permission_handler call + capability re-computation), and H1's fix alone doesn't help the Samsung user who dismissed the battery-opt dialog. Ship both together in 3.1-02.

## §9 Phase 3.1 Risks + Pitfalls

### Risk 1: `bg.BackgroundGeolocation.start()` idempotency

FGB docs claim `start()` is idempotent, but Wave 2 tests via `FakeBackgroundGeolocationFacade` should assert this too — record the number of `start()` calls and verify no adverse behavior from double-invocation (e.g. init → start; then startManual → start again). **Recommendation:** Fake facade increments a counter; test asserts it's called at least once per real user-initiated recording session; hydrated resume calls it exactly once.

### Risk 2: `_ensureFacadeReady()` throws break `startManual()` silently

Currently the caller does NOT wrap `_ensureFacadeReady()` in try/catch (`:170`, `:428`, `:146`). If `ready()` throws (e.g. FGB license failure on Android release build, or malformed config), the exception propagates to the widget layer as a Riverpod async error. Users see nothing. Wave 2 must wrap this and log at `severe` — see §2.4.

### Risk 3: Camera-follow listener runs on hot reload / Riverpod recreate

If the listener is registered inside a `ConsumerStatefulWidget.initState()`, hot reload will re-register it multiple times, potentially fighting the pan-dismiss handler. Use `ref.listen()` inside `build()` (or a dedicated `ProviderListenable` registered once at the app level) to get Riverpod's built-in dedup. **Recommendation:** Register via `ref.listen<TrackingState>(trackingStateProvider, ...)` in `MapScreen.build()` or (cleaner) in a small `TrackingCameraSync` widget mounted at the map layer.

### Risk 4: HUD's Timer.periodic leak

Standard Ralph-Loop pattern: `Timer.periodic` inside a `ConsumerStatefulWidget`, cancel in `dispose()`. Already documented in STATE.md Plan 03-06 as `TrackingDurationTicker` pattern. Reuse it.

### Risk 5: `FakeBackgroundGeolocationFacade` doesn't currently exist in `lib/` but is referenced in Plan docs

STATE.md says "Wave 2 tests use `FakeBackgroundGeolocationFacade`" (line 149). Grep confirms: the fake lives in `test/features/trips/`. Wave 2 tests for Phase 3.1 must import from there, or the fake must be moved to a `test_utilities/` package (out of scope here — keep as test/).

### Risk 6: bg.DeviceSettings.showIgnoreBatteryOptimizations() throws OTHER than Exception

The facade catches `on Exception` (`fgb_background_geolocation_facade.dart:141`). If `bg.DeviceSettings` throws an `Error` subclass (e.g. `UnimplementedError` on an untested device), it will escape. Verified from FGB 5.3.0 source is out of scope for this research — Wave 2 should widen to `on Object` per Plan 01-04's `DomainError.wrap` convention.

### Risk 7: Auto-trip discovery on Samsung Adaptive Battery

Even with `showIgnoreBatteryOptimizations()` granted, Samsung's "Deep Sleep" list can still kill FGB. This is device-vendor-specific and not solvable in code — the drive-verification checklist should include "app not in Deep Sleep list" as an explicit check.

### Risk 8: FGB Android trial-mode throttling

Phase 3 hypothesis-H1 mentioned "FGB unlicensed trial mode may throttle Android background fixes." Per FGB docs: **debug builds are NOT license-restricted**; only Android release builds are. The failed drive was a debug build (STATE.md line 26 confirms). Trial-mode throttling is NOT the cause. Verified.

## §10 Sources

### Primary (HIGH confidence — live source)

- `lib/features/trips/data/fgb_background_geolocation_facade.dart:1-162`
- `lib/features/trips/data/background_geolocation_facade.dart:1-74`
- `lib/features/trips/domain/tracking_service.dart:1-639`
- `lib/features/trips/domain/trip_fix_ingestor.dart:1-341`
- `lib/features/trips/domain/tracking_state.dart:1-37`
- `lib/features/trips/presentation/providers/tracking_state_provider.dart:1-40`
- `lib/features/trips/presentation/widgets/live_tracking_panel.dart:1-42`
- `lib/features/map/presentation/widgets/map_widget.dart:1-196`
- `lib/features/map/presentation/providers/camera_state_provider.dart:1-39`
- `lib/features/map/domain/camera_state.dart:1-58`
- `lib/features/map/domain/follow_mode.dart:1-18`
- `lib/features/map/presentation/widgets/recenter_button.dart:1-90`
- `lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart:1-88`
- `lib/features/onboarding/data/permission_service.dart:1-56`
- `lib/features/onboarding/data/tracking_capability_repository.dart:1-32`
- `lib/features/map/presentation/widgets/permission_denial_banner.dart:1-135`
- `lib/main.dart:1-47`
- `android/app/src/main/AndroidManifest.xml:1-89`
- `ios/Runner/Info.plist:1-70`

### Secondary (HIGH confidence — Phase 3 planning docs)

- `.planning/STATE.md:112-157` — Phase 3 close-out decisions
- `.planning/phases/03-tracking-mvp/03-RESEARCH.md:1-410` — FGB API surface, config reference, permission ladder
- `.planning/phases/03-tracking-mvp/03-CONTEXT.md` — TRK-01..11 requirement text (not re-read; consumed via STATE.md summaries)
- `.planning/phases/03-tracking-mvp/03-DRIVE-VERIFICATION-2026-07-06.md:1-118` — the failed drive report

### Grep verifications

- `facade.start | _facade.start | BackgroundGeolocation.start` in `lib/`: **zero matches** (bash grep verified)
- `MyLocationTrackingMode | trackingCompass | locationAndHeading` in `lib/`: 8 matches, all read-side or enum-decl (no producer wires it to tracking state)
- `setFollowMode` in `lib/`: 3 producers (map_widget pan-dismiss, recenter_button.on_tap, recenter_button.on_error) — none read `trackingStateProvider`
- `ignoreBatteryOptimizations | IgnoreBatteryOpt` in `lib/`: 3 matches, all inside the facade's fire-and-forget `showIgnoreBatteryOptimizations()` block; no `Permission.ignoreBatteryOptimizations.status` reader anywhere

## §11 Metadata

**Confidence breakdown:**

| Area | Level | Reason |
|---|---|---|
| H1 (FGB.start not called) | HIGH | Grep across entire `lib/` returns zero call sites; fix is a single-line addition |
| H2 (camera-follow gap) | HIGH | Same grep methodology on `setFollowMode` producers |
| H3 (motion filter placement) | HIGH | Filter is inside a `TrackingIdle` guard; startManual explicitly emits `TrackingRecording` before any motion event |
| H4 (stateStream cadence) | HIGH | Direct read of `_onLocation.FixAccepted` case — emit is per-fix |
| H5 (battery-opt verification) | HIGH | `showIgnoreBatteryOptimizations()` returns void; capability computed without inspecting the grant |
| HUD data plumbing | HIGH | Enumerated every private field; determined which need public getters vs new counters |
| Wave breakdown | MEDIUM | Depends on H1 fix being genuinely trivial (single-line); if `start()` interacts badly with `changePace()` in an unforeseen way, Wave 2 may need to split further |

**Research date:** 2026-07-06
**Valid until:** 2026-08-05 (30 days — FGB 5.3.0 is stable; Samsung One UI 7 could ship changes to Adaptive Battery in that window, but the fix strategy is unaffected)

**Open questions:**

1. **Does `_facade.start()` need to be paired with `_facade.stop()` in `stopActive()`?** FGB docs suggest `stop()` kills the plugin (needs `ready()` again) — probably NOT what we want. `changePace(false)` is likely enough for pause. Wave 2 should verify by testing that after stopActive → startManual round-trip, fixes still arrive.
2. **Does `bg.BackgroundGeolocation.state.enabled` become `true` on `changePace(true)` alone (no `start()`), or only on `start()`?** Behavior is undocumented for this edge case; the HUD's `FgbState.enabled` value will disambiguate on the first real device test post-fix.
3. **Does `showIgnoreBatteryOptimizations()` throw a Dart `Error` (not `Exception`) on some devices?** Wave 2 should widen the catch to `on Object` per §9 Risk 6, but this is a defensive measure — the failing-silently mode is more likely the practical issue.
