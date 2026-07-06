---
id: 03-1-02
phase: 03-1-tracking-fixes
plan: 02
name: FGB start() fix + battery-opt grant
type: execute
wave: 2
depends_on: [03-1-01]
tags:
  - tracking
  - fgb
  - permissions
  - samsung-battery-opt
  - domain-error
subsystem: trips
requires: [03-1-01]
provides:
  - fgb.start-plumbing
  - tracking.ready-error-surfacing
  - tracking-capability.battery-opt-gate
affects: [03-1-05]
tech-stack:
  added: []
  patterns:
    - "DomainError.wrap boundary at TrackingService._ensureFacadeReady()"
    - "Widen fire-and-forget FGB catch clauses to `on Object`"
    - "Pure static resolveCapability() helper (no I/O) for permission-gate testability"
key-files:
  created:
    - test/features/trips/tracking_service_start_test.dart
  modified:
    - lib/features/trips/domain/tracking_service.dart
    - lib/features/trips/data/fgb_background_geolocation_facade.dart
    - lib/features/onboarding/data/tracking_capability_repository.dart
    - lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart
    - test/features/onboarding/tracking_capability_repository_test.dart
decisions:
  - "bg.BackgroundGeolocation.start() is invoked at three sites in TrackingService: startManual, _openAutoTrip, init() hydration branch — each after _ensureFacadeReady() and before any changePace call."
  - "_ensureFacadeReady() wraps _facade.ready() in try/on Object catch, logs at severe, keeps _facadeReady=false on failure (so a subsequent call retries), and rethrows as DomainError via DomainError.wrap(e, st)."
  - "FgbBackgroundGeolocationFacade.showIgnoreBatteryOptimizations() catch widened from `on Exception` to `on Object` — some OEM code paths throw Error subclasses, not Exceptions."
  - "TrackingCapability.resolveCapability(...) is a pure static helper on the repository — no I/O, no side effects — taking three PermissionStatus rungs + optional isAndroidOverride for host-agnostic tests."
  - "The onboarding page 3 verifies the ignoreBatteryOptimizations grant post-dialog (INFO log line only; the Plan 03-05 denial banner remains the single recovery UI — no re-issue, no Settings deep-link)."
metrics:
  duration: "~25 min"
  completed: 2026-07-06
---

# Phase 3.1 Plan 02: FGB start() fix + battery-opt grant Summary

**One-liner:** Wire the missing `bg.BackgroundGeolocation.start()` at three call sites in TrackingService, surface `ready()` failures via `DomainError.wrap`, widen the battery-opt catch to `on Object`, and gate `TrackingCapability.fullAuto` on the Android battery-opt grant.

## What was built

Three atomic fixes, one commit each (plus one silently absorbed by a parallel-wave sibling agent's docs commit — see Notes below):

### Task 1 — H1 fix (`_facade.start()` plumbing)
- `_facade.start()` added at three sites in `tracking_service.dart`:
  - `startManual()` after `_ensureFacadeReady()`, before `changePace(true)`.
  - `_openAutoTrip()` same pattern.
  - `init()` hydration branch — ONLY when the repository recovers an in-flight trip. Cold init with no in-flight trip does NOT invoke `start()` (no speculative FGS spin-up).
- New test file `test/features/trips/tracking_service_start_test.dart` — 5 assertions:
  1. `startManual` → `startCalls == 1` after single call.
  2. `startManual → stopActive → startManual` → `startCalls == 2`, `readyCalls == 1` (ready is cached per service instance).
  3. Cold init with NO in-flight trip → `startCalls == 0`, `readyCalls == 0`.
  4. Hydration branch → `readyCalls == 1`, `startCalls == 1` (ordering: ready before start).
  5. Auto-trip path (`in_vehicle` + `motion=true`) → `readyCalls == 1`, `startCalls == 1`.
- Used the existing `FakeBackgroundGeolocationFacade.startCalls` int (per plan-checker guidance — DID NOT add a `startCallCount`). No structural changes to the fake.

### Task 2 — Surface `ready()` failures + widen battery-opt catch
- `_ensureFacadeReady()`:
  - Wrapped `_facade.ready()` in `try / on Object catch (e, st)`.
  - Logs `_log.severe('FGB ready() failed: $e', e, st)`.
  - Keeps `_facadeReady = false` on failure so a subsequent call retries.
  - Rethrows via `DomainError.wrap(e, st)` (positional stack-trace arg per the sealed class signature).
- `FgbBackgroundGeolocationFacade.showIgnoreBatteryOptimizations()`:
  - Catch clause widened from `on Exception` to `on Object`.
  - Added `Logger('fgb_facade').warning(...)` — was silently swallowed before.
  - Static `_log` field added (mirrors STATE Plan 02-03 pattern: `Logger('...')` used directly, no AppLogger.instance).
- No test file changes required — the existing `tracking_diagnostics_test.dart` (Plan 03-1-01) already exercises the throw path via `readyError` and catches at the test boundary.

### Task 3 — TrackingCapability gates on Android battery-opt grant
- New pure static `TrackingCapabilityRepository.resolveCapability({...})` helper:
  - Takes `PermissionStatus always`, `PermissionStatus notification`, `PermissionStatus ignoreBatteryOptimizations`, optional `bool? isAndroidOverride`.
  - Rule: `fullAuto` iff always.isGranted AND (on Android) notification.isGranted AND (on Android) ignoreBatteryOptimizations.isGranted. Otherwise `manualOnly`.
  - Uses the universal `!isGranted` predicate (STATE Plan 03-05).
  - `isAndroidOverride` lets host-agnostic tests exercise both branches.
- `permission_motion_notification_page.dart` `_resolveAndFinish()` now:
  - Reads `svc.statusIgnoreBatteryOptimizations()` post-dialog.
  - Constructs the capability via `TrackingCapabilityRepository.resolveCapability(...)`.
  - Logs `INFO` when Android battery-opt not granted (the Plan 03-05 denial banner remains the single recovery UI — no re-issue, no Settings deep-link here).
  - Added `Logger('permission_motion_notification_page')` static field per STATE Plan 03-05 pattern.
- Test file `tracking_capability_repository_test.dart` extended with 6 new `resolveCapability` cases (grant / deny / permanentlyDenied on Android; iOS pass-through; classic always-denied path; notification-denied path).

## Deviations from Plan

**None architectural.** Three small mechanical divergences from the plan sketch:

1. **`avoid_catches_without_on_clauses` ignore-comments removed.** The plan sketch included inline `// ignore: avoid_catches_without_on_clauses` on the two widened catches. But `on Object catch` counts as an `on` clause in Dart 3.5, so the analyzer emits `unnecessary_ignore` for those comments. Removed the ignores; the widened catches still record the DomainError.wrap decision inline via a plain comment.

2. **`resolveCapability` is a pure static helper on the repository class**, not an instance method that reads platform state internally. The plan text said "Extend the capability resolver to read `permissionService.statusIgnoreBatteryOptimizations()`..." — but keeping the repository stateless and pushing the async read into the caller (the onboarding page + any future banner refresh) keeps the helper testable without any I/O mock. Added `bool? isAndroidOverride` param so tests exercise both branches deterministically.

3. **Task 3 commit was silently absorbed by a sibling agent's docs commit.** The parallel Plan 03-1-04 orchestrator's final `docs(3.1-04): complete regression-tests-motion-filter-and-cadence plan` commit (`28b6d1d`) contains the exact byte-for-byte diff of my three Task 3 files, though its commit message says "Zero production code touched." This is a Wave 2 parallel-execution hygiene collision — the sibling agent's `git add` picked up my working-tree changes before I could commit them separately. Impact: the code is landed and green; the audit trail attributes Task 3's H5 fix to a `docs(3.1-04)` commit rather than a `fix(3.1-02)` commit. Files affected: `lib/features/onboarding/data/tracking_capability_repository.dart`, `lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart`, `test/features/onboarding/tracking_capability_repository_test.dart`. All three are 100% my Task 3 work; the 3.1-04 test files it committed alongside are that plan's own H3/H4 regression tests. Recommend a follow-up amend or `git notes` cross-link before push if the orchestrator wants clean per-plan attribution.

## Commits

Note the Task 3 attribution collision described in Deviations above.

| # | Hash | Type | Subject |
|---|------|------|---------|
| 1 | `1facbf5` | fix(3.1-02) | add missing `_facade.start()` at three sites in TrackingService |
| 2 | `939f5eb` | fix(3.1-02) | surface FGB `ready()` failures + widen battery-opt catch |
| 3 | absorbed into `28b6d1d docs(3.1-04)` | fix(3.1-02) | TrackingCapability considers ignoreBatteryOptimizations on Android |

## Verification

- `flutter analyze` — **No issues found.**
- `flutter test test/features/trips/ test/features/onboarding/ test/features/settings/ test/widget_test.dart` — **94/94 green.**
- `grep -c "_facade.start()" lib/features/trips/domain/tracking_service.dart` → **3** (matches plan requirement).
- `grep -n "on Object" lib/features/trips/domain/tracking_service.dart lib/features/trips/data/fgb_background_geolocation_facade.dart` → **3 hits** (≥ 2 required).
- `grep -rn "statusIgnoreBatteryOptimizations" lib/features/onboarding/` → **3 hits** (definition + impl + call site).
- New test file `tracking_service_start_test.dart` (5 assertions) — all green on first run.
- Extended `tracking_capability_repository_test.dart` (4 existing + 6 new resolveCapability) — all green.

Parallel-lane tests owned by Plan 03-1-03 (`test/features/map/*camera_sync*`, `test/features/map/router_shell_test.dart`) were NOT touched and are outside this plan's verification surface.

## SC alignment

- **SC1 (Debug HUD):** N/A — owned by 03-1-01.
- **SC2 (Manual trip fixes within 3 s, distance/speed update, polyline persists):** **Directly satisfied by Task 1.** Adding `_facade.start()` in `startManual()` is the missing link — the pre-existing ingestor → stateStream → panel chain works once FGB actually delivers fixes.
- **SC3 (Auto trip pending within 60 s, auto-terminates after 2 min):** **Directly satisfied by Task 1** (`_openAutoTrip`).
- **SC4 (Persistent notification visible during any active trip):** **Directly satisfied by Task 1** — FGS does not launch without `start()`.
- **SC5 (Map camera follows during recording):** N/A — owned by 03-1-03.
- **SC6 (In-car drive passes):** **Blocking contributor.** Wave 3 (03-1-05) gates on this plan + the two parallel plans in Wave 2.

## Notes for Wave 3 (03-1-05)

- The HUD from 03-1-01 will show `facadeReadyOutcome: FacadeReadySuccess` immediately after first tracking use on-device. If the drive fails again, the HUD's `facadeReadyOutcome: FacadeReadyFailed(...)` shape now surfaces the raw platform error message — no more silent swallow.
- If FGB's `start()` throws when the plugin is already started (contradicting the docs' idempotency claim), the deviation guidance says: catch the specific FGB exception in the facade and log-and-continue. Not yet needed; the fake counts multiple `start()` calls with no visible issue.
- The `on Object` widening in `showIgnoreBatteryOptimizations` should be validated against a real Samsung dialog (any Error subclass previously fell through the fire-and-forget). No test coverage possible without a live platform channel; watch the drive-verification logs.

## Next Phase Readiness

- **Blockers cleared for 03-1-05 (Wave 3):** H1 + H5 both closed. H2 (03-1-03) and any residual H4 regression coverage (03-1-04) close in parallel. When all Wave 2 plans land, 03-1-05 batches the in-car drive re-verification against 03-VERIFICATION.md's deferred checklist.
- **No new pending todos.** The Task 3 attribution collision (Notes above) is a git-hygiene follow-up, not a technical debt item.
