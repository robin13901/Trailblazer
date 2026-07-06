---
phase: 03-1-tracking-fixes
plan: 01
subsystem: tracking-diagnostics
tags: [debug-hud, diagnostics, observability, fgb-facade, permissions, tracking-service, riverpod]

# Dependency graph
requires:
  - phase: 03-tracking-mvp
    provides: TrackingService state machine, BackgroundGeolocationFacade abstract seam, FakeBackgroundGeolocationFacade test double, PermissionService ladder rungs
provides:
  - TrackingDiagnostics DTO + FacadeReadyOutcome sealed hierarchy (Pending/Success/Failed) — domain-pure read-only snapshot
  - TrackingService.diagnostics getter — constructs a fresh snapshot on every call
  - Private counters on TrackingService — acceptCount, rejectCount, gapCount, splitCount, lastRejectedReason, lastRejectedAt, lastAcceptedFixSample
  - BackgroundGeolocationFacade.currentReadyOutcome getter — new abstract member, wired into FGB facade + FakeBackgroundGeolocationFacade (with readyError hook)
  - PermissionService.statusWhenInUse / statusActivityRecognition / statusIgnoreBatteryOptimizations — three new read-only rungs
  - trackingDiagnosticsProvider (plain Provider<TrackingDiagnostics>)
  - TrackingDiagnosticsScreen at /settings/diagnostics — kDebugMode-guarded, Timer.periodic(500ms) HUD
  - DEV section in SettingsScreen with a Tracking diagnostics ListTile (kDebugMode-guarded)
affects:
  - 03-1-02 (FGB start + battery-opt fix) — will consume `_facade.currentReadyOutcome` for red banner + widen TrackingCapability using statusIgnoreBatteryOptimizations
  - 03-1-03 (motion filter + live-stats regression tests) — will assert accept/reject counters increment as expected
  - 03-1-04 (map camera follow) — HUD is the observation channel for the in-car drive
  - 03-1-05 (in-car verification + close-out) — HUD screenshots are the drive-report artifact

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TrackingDiagnostics DTO: domain-pure read-only snapshot constructed on-demand by a getter — no stream, no caching, HUD drives its own polling"
    - "BackgroundGeolocationFacade.currentReadyOutcome: additive abstract getter with matching state field in both prod FGB impl (records on try/catch) and FakeBackgroundGeolocationFacade (records on readyError hook)"
    - "kDebugMode-guarded GoRoute + kDebugMode-guarded Settings ListTile — const-elision tree-shakes both from release APK/IPA"
    - "Widget tests for tall ListView screens: setSurfaceSize(800×3000) + addTearDown(setSurfaceSize(800×600)) so all offstage ListTiles mount eagerly"
    - "HUD polling pattern: ConsumerStatefulWidget with Timer.periodic(500ms) — synchronous ref.read of the diagnostics provider on each tick, async-refresh microtask off the same tick for platform-channel-backed permission statuses"

key-files:
  created:
    - lib/features/trips/domain/tracking_diagnostics.dart
    - lib/features/trips/presentation/providers/tracking_diagnostics_provider.dart
    - lib/features/settings/presentation/tracking_diagnostics_screen.dart
    - test/features/trips/tracking_diagnostics_test.dart
    - test/features/settings/tracking_diagnostics_screen_test.dart
  modified:
    - lib/features/trips/data/background_geolocation_facade.dart (currentReadyOutcome getter on abstract interface)
    - lib/features/trips/data/fgb_background_geolocation_facade.dart (ready() wrapped in try/catch, records outcome, rethrows)
    - lib/features/trips/domain/tracking_service.dart (counters + LastFixSample + diagnostics getter + import)
    - lib/features/onboarding/data/permission_service.dart (three new status methods; dart:io Platform import for iOS branch)
    - lib/core/routing/app_router.dart (kDebugMode-guarded /settings/diagnostics route)
    - lib/features/settings/presentation/settings_screen.dart (kDebugMode-guarded Developer section + _DiagnosticsTile)
    - test/helpers/fake_background_geolocation_facade.dart (currentReadyOutcome + readyError hook — plan mistakenly named this file test/features/trips/…; real path is test/helpers/)
    - test/features/trips/data/background_geolocation_facade_test.dart (canary fake now implements currentReadyOutcome)
    - test/features/onboarding/fakes/fake_permission_service.dart (three new override setters + defaults)

key-decisions:
  - "Counters live on TrackingService, not TripFixIngestor — keeps the 22-test ingestor pure per 03-1-RESEARCH §7.1"
  - "Facade ready() failure recorded but exception continues to propagate — the DomainError/Result<T> boundary is Plan 03-1-02's job, not this plan's"
  - "HUD polls via Timer.periodic(500ms) + setState (per 03-1-RESEARCH §7.2) — no broadcast stream, no Riverpod watch inside the HUD (build() calls ref.read)"
  - "FacadeReadyOutcome sealed type + FacadeReadyPending initial value — three states cover pending/success/failed(message) without null semantics"
  - "kDebugMode gating is const-elided — the diagnostics route + tile disappear from release builds without any runtime check"

patterns-established:
  - "Diagnostics DTO pattern: single read-only getter on the long-lived service, constructed fresh per call, consumed by a dev-only widget with its own polling loop"
  - "Facade ready-outcome tracking: on the abstract interface as a getter; state field lives in each impl; try/catch/rethrow in the prod impl records outcome without changing the exception contract"
  - "Widget test for tall diagnostics ListView: setSurfaceSize + addTearDown pair — reuseable for future settings/inspector screens"

# Metrics
duration: 23min
completed: 2026-07-06
---

# Phase 3.1 Plan 01: Debug HUD + Diagnostic Plumbing Summary

**Dev-only tracking diagnostics HUD at `/settings/diagnostics`, backed by a `TrackingDiagnostics` DTO + counters on `TrackingService` + a `currentReadyOutcome` signal on the facade — Wave 2 (fixes) can now iterate without a real drive.**

## Performance

- Duration: 23 min (well under Phase 3 average of 30 min/plan; below the 45-60 min plan-checker estimate)
- Loop cost: 4 Ralph-Loop iterations total (1 analyze cycle after Task 1, 1 after Task 2, 2 after Task 3 for widget-test surface sizing)
- Test count: 145 → 153 (+8: 6 new diagnostics unit tests, 2 new HUD widget tests)
- Commits: 3 task commits — 818dd2d (DTO+counters+facade), 6bc6360 (permissions+provider), b7b09f6 (HUD+route)

## What ships

### Task 1: DTO + counters + facade signal (commit 818dd2d)

- `TrackingDiagnostics` DTO carrying 12 fields — every private observability field on `TrackingService` becomes a read-only snapshot.
- `FacadeReadyOutcome` sealed hierarchy — `FacadeReadyPending` / `FacadeReadySuccess` / `FacadeReadyFailed(String message)`.
- `TrackingService.diagnostics` getter — constructs a fresh snapshot per call from private state.
- Four new counters (`_acceptCount`, `_rejectCount`, `_gapCount`, `_splitCount`) plus `_lastRejectedReason` / `_lastRejectedAt` / `_lastAcceptedFixSample` — wired inside `_onLocation`'s outcome switch. `TripFixIngestor` is not touched.
- `BackgroundGeolocationFacade.currentReadyOutcome` new abstract getter — FGB prod impl wraps `ready()` in try/catch/rethrow; `FakeBackgroundGeolocationFacade` mirrors the shape with a `readyError` hook so tests can force failure without native code.
- 6 unit tests in `test/features/trips/tracking_diagnostics_test.dart` — pending → success, throwing → failed(message), accept counter, reject counter, activity change, initial state.

### Task 2: PermissionService extensions + provider (commit 6bc6360)

- `PermissionService` gains three read-only rungs: `statusWhenInUse()`, `statusActivityRecognition()`, `statusIgnoreBatteryOptimizations()` (returns granted on iOS — no equivalent concept).
- `PermissionHandlerService` prod impl uses `dart:io Platform.isIOS` for the battery-opt branch.
- `FakePermissionService` gains matching override setters (`whenInUseStatus=`, `activityRecognitionStatus=`, `ignoreBatteryOptimizationsStatus=`) with sensible defaults.
- `trackingDiagnosticsProvider` — plain `Provider<TrackingDiagnostics>` that reads through `TrackingService.diagnostics`. HUD uses `ref.read` (not watch) inside its polling tick.
- Zero production behavior change — onboarding ladder untouched; Plan 03-1-02 owns the widening of `TrackingCapability` to consider the battery-opt grant.

### Task 3: HUD screen + route + Settings entry (commit b7b09f6)

- `TrackingDiagnosticsScreen` (`ConsumerStatefulWidget`) — 500 ms `Timer.periodic` + `setState` on each tick; async-refreshes `FgbState.currentState()` + 5 permission statuses off the same tick and stores results in state.
- Ready-outcome tile is color-coded — grey pending, green success, red failed (with the exception message as subtitle, tinted at `withValues(alpha: 0.85)`).
- Renders 8 sections: FGB, Permissions, Last accepted fix, Last rejected fix, Last activity, Counters, Current trip. Every field enumerated in `must_haves.truths` is rendered.
- `kDebugMode`-guarded `GoRoute` at `/settings/diagnostics` in `app_router.dart` — the whole route entry is const-elided from release builds.
- `_DiagnosticsTile` in `SettingsScreen` — appears only in a `kDebugMode` block under a "Developer" section header. Uses `context.push` (not `go`) per STATE 02-06.
- Widget test with 2 scenarios — one fully populated snapshot, one all-null idle snapshot. Uses `setSurfaceSize(800×3000)` + `addTearDown(setSurfaceSize(800×600))` so all ListTiles mount eagerly.
- Release-mode short-circuit inside the widget as belt-and-braces (`_ReleaseModeShortCircuit`).

## Verification results

- `flutter analyze` → No issues found.
- `flutter test` → 153/153 pass (145 prior + 6 new diagnostics unit + 2 new HUD widget). Behavior-sensitive change (TrackingService counters + diagnostics getter) — full suite ran inside the tight loop per project CLAUDE.md.
- grep `TrackingDiagnostics` in `lib/` → 14 occurrences across 5 files (DTO decl, service getter body + import, provider, HUD screen, route target).
- grep `/settings/diagnostics` in `lib/` → 3 hits (route decl, docstring in HUD, Settings ListTile onTap).
- grep `ignoreBatteryOptimization` in `lib/features/onboarding/` → 1 hit (new `PermissionService.statusIgnoreBatteryOptimizations`).
- kDebugMode gating validated by inspection: `if (kDebugMode)` wraps the route in `app_router.dart` and the ListTile in `settings_screen.dart`; the HUD widget also guards its `build()` with a release-mode short-circuit.

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 — Blocking] Wrong path for `FakeBackgroundGeolocationFacade` in plan text**

- **Found during:** Task 1
- **Issue:** Plan repeatedly refers to `test/features/trips/fake_background_geolocation_facade.dart` but the file actually lives at `test/helpers/fake_background_geolocation_facade.dart`.
- **Fix:** Updated the fake at its real location; imports in the new `tracking_diagnostics_test.dart` and the widget test point at `../../helpers/…` and `../../../helpers/…` respectively.
- **Files modified:** `test/helpers/fake_background_geolocation_facade.dart`
- **Commit:** 818dd2d
- **Plan-checker note:** This was pre-flagged in the executor's prompt ("Update this plan's file references silently as you go — do NOT stop and ask").

**2. [Rule 3 — Blocking] Stability-contract canary broke on new abstract member**

- **Found during:** Task 1 (first `flutter analyze` pass)
- **Issue:** Adding `currentReadyOutcome` to `BackgroundGeolocationFacade` broke `_FakeFacade` in `test/features/trips/data/background_geolocation_facade_test.dart` — that fake exists specifically to catch interface drift, so this was expected and correct.
- **Fix:** Added `currentReadyOutcome` implementation returning `FacadeReadyPending()` on the canary fake.
- **Files modified:** `test/features/trips/data/background_geolocation_facade_test.dart`
- **Commit:** 818dd2d

**3. [Rule 3 — Blocking] `readyError = StateError(...)` tripped `only_throw_errors` lint on rethrow in fake**

- **Found during:** Task 1 (first `flutter analyze` pass)
- **Issue:** `FakeBackgroundGeolocationFacade.ready()` rethrows an `Object?` field, which `very_good_analysis` treats as "throwing a non-Error/Exception subclass" even when the value at runtime is actually a `StateError`.
- **Fix:** Added inline `// ignore: only_throw_errors` with a doc comment explaining the intent — mirroring the prod facade's `on Object catch (e) { … rethrow; }` boundary.
- **Files modified:** `test/helpers/fake_background_geolocation_facade.dart`
- **Commit:** 818dd2d

**4. [Rule 1 — Bug] Widget-test finders returning zero matches under default 800×600 surface**

- **Found during:** Task 3 (widget test first run)
- **Issue:** The diagnostics HUD's ListView has ~18 ListTiles totalling ~1100 dp of height; the default `flutter_test` surface is 800×600, so ListTiles past the fold are lazily kept offstage and `find.text(...)` returns zero matches.
- **Attempted fix 1:** `find.text(..., skipOffstage: false)` — still didn't match because the offstage tiles were not built at all under `SliverChildBuilderDelegate`'s lazy build.
- **Working fix:** Enlarge the surface to `Size(800, 3000)` via `tester.binding.setSurfaceSize` (with `addTearDown` reverting to 800×600). All ListTiles now materialise on `pump()`. This is a testing pattern worth capturing (added to `patterns-established`).
- **Files modified:** `test/features/settings/tracking_diagnostics_screen_test.dart`
- **Commit:** b7b09f6

### Not deviated (called out because plan-checker flagged)

- The plan's `files_modified` frontmatter listed `test/features/trips/tracking_diagnostics_test.dart` under `lib/features/trips/` — the plan mixed test and lib paths. Actual test file is under `test/`, as expected. No change to plan behavior; noted for future accuracy.
- No architectural change (Rule 4) triggered. Everything landed as pure additive changes to existing seams.

## Authentication Gates

None — this plan is entirely local code + tests. No CLI, no API, no external auth.

## Next Phase Readiness

**Ready for Wave 2 (parallel):**

- **03-1-02 (FGB start + battery-opt fix):** Can now call `_facade.currentReadyOutcome` from `TrackingService` (or a widget) to surface a red banner when `ready()` fails; can call `PermissionService.statusIgnoreBatteryOptimizations()` to decide whether to widen `TrackingCapability` on Android. Both surfaces are landed and tested.
- **03-1-03 (motion filter + live-stats regression tests):** Can assert against `TrackingService.diagnostics.acceptCount` / `rejectCount` in new tests instead of reaching into private state via test-only reflection. The diagnostics DTO is the correct assertion surface for defensive counter-invariants.
- **03-1-04 (map camera follow):** No direct dependency on this plan's outputs, but the HUD is the observation channel — after the fix lands, the drive tester will use the HUD to confirm the camera-mode transition alongside `MyLocationTrackingMode.trackingCompass` activation.

**Blocked on Wave 2:**

- **03-1-05 (in-car verification + close-out):** Depends on all of 03-1-02/03/04. HUD is ready for use in the drive report — screenshots go into `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md` once Wave 3 runs.

## Known gaps / concerns

- **HUD polling loop hits the FGB platform channel every 500 ms.** `facade.currentState()` may be non-trivial cost on some devices; if the drive tester notices UI stutter while the HUD is open, extend the async refresh to `pollInterval * 4` (every 2 s) — the sync `diagnostics` snapshot stays at 500 ms.
- **`_ReleaseModeShortCircuit` is unreachable code** in release builds (both route and tile are `kDebugMode`-guarded upstream), but it survives release compilation because it's referenced from the widget's `build()`. Cost: ~40 bytes of frozen release bytecode. Acceptable defensive-code tax.
- **`FacadeReadySuccess` state is displayed as green** — no design review; drive tester may want an amber "success but state.enabled=false" combined signal (Wave 2's `_facade.start()` fix will make this observable).
- **`_facade.currentState()` catches `Object`** — same pattern as the widened `on Object catch` in the FGB facade; iOS may throw before `ready()` completes and we don't want the HUD to crash.

## References

- Plan: `.planning/phases/03-1-tracking-fixes/03-1-01-debug-hud-diagnostics-PLAN.md`
- Research: `.planning/phases/03-1-tracking-fixes/03-1-RESEARCH.md` §7 (data-source map), §7.1 (DTO shape), §7.2 (polling rationale), §7.3 (entry point)
- Context: `.planning/phases/03-1-tracking-fixes/03-1-CONTEXT.md` (wave breakdown)
- Prior art:
  - Plan 03-04 (TrackingService lifecycle + `_lastActivityType` field)
  - Plan 03-06 (`TrackingDurationTicker` — same Timer.periodic pattern used inside a StatefulWidget)
  - Plan 03-05 (`FakePermissionService` — extended with three new override setters)
