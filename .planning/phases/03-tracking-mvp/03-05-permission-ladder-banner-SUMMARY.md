---
phase: 03-tracking-mvp
plan: 05
subsystem: ui
tags: [permission_handler, riverpod, shared_preferences, onboarding, flutter, android, ios]

# Dependency graph
requires:
  - phase: 01-scaffolding
    provides: shared_preferences, permission_handler dep, OnboardingFlagRepository, AppPrefs pattern
  - phase: 02-map-glass-shell
    provides: MapScreen Stack layout + glass idioms (withValues, 12 dp margins, tab-visibility pattern)
  - phase: 03-tracking-mvp (03-03)
    provides: BackgroundGeolocationFacade interface + backgroundGeolocationFacadeProvider
provides:
  - PermissionService abstract interface + PermissionHandlerService real impl (ph-prefixed import)
  - permissionServiceProvider (plain Provider<PermissionService>, override target)
  - FakePermissionService test double (scriptable statuses, call log)
  - TrackingCapability enum (fullAuto / manualOnly) + TrackingCapabilityRepository (SharedPreferencesAsync, prefsKey='tracking_capability')
  - trackingCapabilityRepositoryProvider + trackingCapabilityProvider (FutureProvider)
  - PermissionRationalePage shared layout widget (icon/title/body/primary/optional-secondary)
  - Three onboarding pages: PermissionWhenInUsePage, PermissionAlwaysPage, PermissionMotionNotificationPage
  - OnboardingScreen: PageView NeverScrollableScrollPhysics, 3-page flow
  - backgroundGeolocationFacadeProvider (Provider<BackgroundGeolocationFacade>) + FakeBackgroundGeolocationFacade
  - PermissionDenialBanner: yellow glass strip, WidgetsBindingObserver resume-invalidation, onTap→openAppSettings
  - permissionDenialBannerVisibleProvider (FutureProvider<bool>, !isGranted semantics)
  - MapScreen: banner slotted at top of map Stack, map-tab-only
  - 5 test files: tracking_capability_repository_test, onboarding_ladder_test (9 cases), permission_denial_banner_test (4 cases), app_router_test (patched), widget_test (patched)
affects:
  - 03-04 (TrackingNotifier wires TrackingCapability to auto-start decision)
  - 03-06 (TripFab may read trackingCapabilityProvider to surface manual-only affordance)
  - 10-settings (Settings screen reads TrackingCapabilityRepository to display/change mode)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "PermissionService seam: all permission_handler access goes through abstract interface; tests override permissionServiceProvider with FakePermissionService — no method-channel mocks"
    - "!isGranted predicate for any non-granted status (denied/restricted/limited/permanentlyDenied)"
    - "AppLifecycleState.resumed → ref.invalidate pattern for re-reading runtime state after OS detour"
    - "ph-prefixed import (import '...' as ph;) to resolve openAppSettings top-level function shadowing"
    - "backgroundGeolocationFacadeProvider placed in lib/features/trips/data/ — shared between 03-03 and 03-05 consumers"

key-files:
  created:
    - lib/features/onboarding/data/permission_service.dart
    - lib/features/onboarding/data/permission_service_provider.dart
    - lib/features/onboarding/data/tracking_capability.dart
    - lib/features/onboarding/data/tracking_capability_repository.dart
    - lib/features/onboarding/data/tracking_capability_providers.dart
    - lib/features/onboarding/presentation/widgets/permission_rationale_page.dart
    - lib/features/onboarding/presentation/pages/permission_when_in_use_page.dart
    - lib/features/onboarding/presentation/pages/permission_always_page.dart
    - lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart
    - lib/features/trips/data/background_geolocation_facade_provider.dart
    - lib/features/map/presentation/widgets/permission_denial_banner.dart
    - test/features/onboarding/fakes/fake_permission_service.dart
    - test/features/onboarding/tracking_capability_repository_test.dart
    - test/features/onboarding/onboarding_ladder_test.dart
    - test/features/map/permission_denial_banner_test.dart
    - test/features/onboarding/fakes/fake_background_geolocation_facade.dart
  modified:
    - lib/features/onboarding/presentation/onboarding_screen.dart
    - lib/features/map/presentation/map_screen.dart
    - test/core/routing/app_router_test.dart
    - test/widget_test.dart

key-decisions:
  - "PermissionService lives in lib/features/onboarding/data/ — collocated with the onboarding feature that owns the permission request UX"
  - "backgroundGeolocationFacadeProvider placed in lib/features/trips/data/ — shared with 03-04 TrackingNotifier without cross-feature coupling"
  - "TrackingCapability persisted as String via SharedPreferencesAsync, prefsKey='tracking_capability', values 'full_auto'/'manual_only'"
  - "!isGranted is the universal 'not granted' predicate — covers denied/restricted/limited/permanentlyDenied uniformly"
  - "permissionDenialBannerVisibleProvider defined in permission_denial_banner.dart (not a separate providers file) — co-location makes override target obvious to test authors"
  - "AppLifecycleState.resumed → ref.invalidate(permissionDenialBannerVisibleProvider) for Settings return re-check"
  - "FakeBackgroundGeolocationFacade added alongside FakePermissionService for full platform isolation in ladder tests"
  - "Banner copy: 'Enable Always for auto-trips — tap to open Settings' (approved as-is on-device 2026-07-05)"
  - "Page 3 Android/iOS branching: Platform.isIOS/isAndroid from dart:io — no flutter_platform_widgets dep"
  - "Banner positioned via Positioned(top: safeArea.top + 12, left: 0, right: 0) inside map Stack; only shown when currentIndex==0"

patterns-established:
  - "PermissionService seam pattern: abstract interface + real impl + provider + fake — same shape as BackgroundGeolocationFacade from 03-03"
  - "FutureProvider visibility predicate with ProviderScope override in tests (AsyncValue.data(true/false)) avoids async timing issues in widget tests"
  - "Multi-page onboarding: PageView NeverScrollableScrollPhysics + PageController lifted to parent; advance is always programmatic"

# Metrics
duration: ~75min (includes 03-05 regression fix commit + on-device checkpoint wait)
completed: 2026-07-05
---

# Phase 3 Plan 05: Permission-Ladder Onboarding + Denial Banner Summary

**3-page permission ladder (whenInUse→Always→Motion/Notification+BatteryOpt) with TrackingCapability persistence and yellow glass denial banner on map, all behind a PermissionService seam that eliminates method-channel mocking from tests**

## Performance

- **Duration:** ~75 min (including on-device checkpoint and regression fix round)
- **Started:** 2026-07-05 (Wave 2, afternoon session)
- **Completed:** 2026-07-05T~13:20Z (last commit b3b93a0)
- **Tasks:** 4 (3 auto + 1 checkpoint:human-verify, approved)
- **Files modified:** 20 (16 created, 4 modified)

## Accomplishments

- Replaced the Phase 1 single-Continue onboarding with a 3-page PageView permission ladder: whenInUse → Always → Motion/Notification+BatteryOpt, with platform-branched copy on page 3
- Delivered `PermissionService` abstract interface + `PermissionHandlerService` + `FakePermissionService` — all permission_handler calls in the codebase now flow through this seam; no method-channel mocking needed in any test
- `TrackingCapability` (fullAuto/manualOnly) persisted in SharedPreferences and re-read by the yellow denial banner on the map screen, which re-evaluates on `AppLifecycleState.resumed` after a Settings round-trip
- On-device verified 2026-07-05 on Samsung Galaxy S24, Android 14 — approved as-is, no copy revisions requested

## Task Commits

Each task was committed atomically:

1. **Task 1: PermissionService seam + TrackingCapability model + rationale widget** — `c5c0987` (feat)
2. **Task 2: 3-page permission ladder + PageView onboarding + persistence** — `a9141b8` (feat)
3. **Task 3: PermissionDenialBanner + map screen integration** — `b1cea70` (feat)
4. **Regression fix: router + widget tests for 3-page onboarding** — `b3b93a0` (fix)

**Plan metadata:** TBD (docs: complete permission-ladder-banner plan)

## Files Created/Modified

### Created
- `lib/features/onboarding/data/permission_service.dart` — Abstract `PermissionService` interface + `PermissionHandlerService` (ph-prefixed import to avoid `openAppSettings` name shadow)
- `lib/features/onboarding/data/permission_service_provider.dart` — `permissionServiceProvider` (plain `Provider<PermissionService>`)
- `lib/features/onboarding/data/tracking_capability.dart` — `enum TrackingCapability { fullAuto, manualOnly }`
- `lib/features/onboarding/data/tracking_capability_repository.dart` — `TrackingCapabilityRepository` (`SharedPreferencesAsync` injection, `prefsKey = 'tracking_capability'`)
- `lib/features/onboarding/data/tracking_capability_providers.dart` — `trackingCapabilityRepositoryProvider` + `trackingCapabilityProvider` (FutureProvider)
- `lib/features/onboarding/presentation/widgets/permission_rationale_page.dart` — Shared `PermissionRationalePage` layout (icon/title/body/primary/optional-secondary)
- `lib/features/onboarding/presentation/pages/permission_when_in_use_page.dart` — Page 1: locationWhenInUse, advances unconditionally
- `lib/features/onboarding/presentation/pages/permission_always_page.dart` — Page 2: locationAlways + "Manual only" text button skip
- `lib/features/onboarding/presentation/pages/permission_motion_notification_page.dart` — Page 3: iOS sensors / Android notification+battery; resolves final `TrackingCapability` via `!isGranted`, persists + navigates to `/`
- `lib/features/trips/data/background_geolocation_facade_provider.dart` — `backgroundGeolocationFacadeProvider` (plain `Provider`, placed in trips/data to be shared with 03-04)
- `lib/features/map/presentation/widgets/permission_denial_banner.dart` — `PermissionDenialBanner` (`ConsumerStatefulWidget` + `WidgetsBindingObserver`) + `permissionDenialBannerVisibleProvider`
- `test/features/onboarding/fakes/fake_permission_service.dart` — `FakePermissionService` (scriptable statuses, call log)
- `test/features/onboarding/fakes/fake_background_geolocation_facade.dart` — `FakeBackgroundGeolocationFacade`
- `test/features/onboarding/tracking_capability_repository_test.dart` — 4 unit test cases (empty prefs default, save/load manualOnly, save/load fullAuto, prefsKey contract)
- `test/features/onboarding/onboarding_ladder_test.dart` — 9 widget test cases (all-granted fullAuto, always-denied manualOnly, permanentlyDenied, restricted, Android-notif-denied, copy renders per page)
- `test/features/map/permission_denial_banner_test.dart` — 4 widget test cases (visible, hidden, tap→openAppSettings, restricted→visible)

### Modified
- `lib/features/onboarding/presentation/onboarding_screen.dart` — Replaced Phase 1 single-Continue body with `PageView` (3 pages, `NeverScrollableScrollPhysics`)
- `lib/features/map/presentation/map_screen.dart` — Slotted `PermissionDenialBanner` at top of map Stack via `Positioned`, map-tab-only
- `test/core/routing/app_router_test.dart` — Patched to tap through 3 permission pages; injected `FakePermissionService` + `FakeBackgroundGeolocationFacade`
- `test/widget_test.dart` — Same patch: smoke test now taps through all 3 pages

## Decisions Made

- **PermissionService seam location:** `lib/features/onboarding/data/` — permission requests belong to the onboarding feature that owns the UX for them.
- **TrackingCapability enum values + persistence key:** `fullAuto`/`manualOnly` as Dart enum; stored as `'full_auto'`/`'manual_only'` strings; `prefsKey = 'tracking_capability'`. Consistent with Plan 01-03 pattern (public `prefsKey` for test/debug parity).
- **backgroundGeolocationFacadeProvider location:** `lib/features/trips/data/` — the facade itself lives there (03-03); the provider belongs alongside it so 03-04 (`TrackingNotifier`) can watch the same provider without a cross-feature import.
- **Banner invalidation trigger:** `AppLifecycleState.resumed → ref.invalidate(permissionDenialBannerVisibleProvider)` inside `WidgetsBindingObserver`. Chosen over a periodic timer or push-based approach — O(1) reads, only triggers on actual Settings return.
- **permissionDenialBannerVisibleProvider co-located in banner file:** Makes the override target obvious to test authors; avoids a separate providers file for a widget-scoped concern.
- **Page 3 Android/iOS branching:** `Platform.isIOS/isAndroid` from `dart:io` — no `flutter_platform_widgets` dependency added.
- **!isGranted predicate uniformly applied:** Both `permissionDenialBannerVisibleProvider` and the ladder's final capability resolution use `!isGranted` (not `isDenied`) to cover `restricted`, `limited`, and `permanentlyDenied`.
- **Banner copy (approved as-is):** "Enable Always for auto-trips — tap to open Settings" — on-device review 2026-07-05 (Samsung Galaxy S24, Android 14), no revisions requested.
- **ph-prefixed import in PermissionHandlerService:** `import 'package:permission_handler/permission_handler.dart' as ph;` — avoids `openAppSettings()` method on the class shadowing the top-level `ph.openAppSettings()` function.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] app_router_test + widget_test searched for stale Phase-1 onboarding copy**

- **Found during:** After Task 3 commit — CI verification run
- **Issue:** Both test files searched for `'Welcome to Trailblazer'` (single-page copy from Phase 1) and tapped a single Continue button. After replacing `OnboardingScreen` with a 3-page PageView, those tests failed.
- **Fix:** Updated both test files to inject `FakePermissionService` + `FakeBackgroundGeolocationFacade` via `ProviderScope.overrides` and tap through all 3 permission pages. No assertion copy was broken — tests verified correct post-onboarding navigation.
- **Files modified:** `test/core/routing/app_router_test.dart`, `test/widget_test.dart`
- **Verification:** `flutter test` green (19 passing test cases across all modified test files)
- **Committed in:** `b3b93a0` (separate fix commit, not folded into task commit)

**2. [Rule 2 - Missing Critical] backgroundGeolocationFacadeProvider not yet defined when Task 2 needed it**

- **Found during:** Task 2 — `PermissionMotionNotificationPage` calls `showIgnoreBatteryOptimizations()` on the facade and needs a Riverpod provider to read it
- **Issue:** Plan 03-03 shipped the `BackgroundGeolocationFacade` interface and `FgbBackgroundGeolocationFacade` impl but did not create a Riverpod provider (the provider was deferred to 03-04/TrackingNotifier in the original plan sketch). Task 2 needed it before 03-04 existed.
- **Fix:** Created `lib/features/trips/data/background_geolocation_facade_provider.dart` as a plain `Provider<BackgroundGeolocationFacade>` in the trips/data directory. Also created `test/features/onboarding/fakes/fake_background_geolocation_facade.dart` for test isolation.
- **Files modified:** `lib/features/trips/data/background_geolocation_facade_provider.dart` (new), `test/features/onboarding/fakes/fake_background_geolocation_facade.dart` (new)
- **Verification:** `flutter analyze` clean; onboarding_ladder_test all-granted path passes with facade properly faked
- **Committed in:** `a9141b8` (part of Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 bug/regression, 1 missing critical provider)
**Impact on plan:** Both fixes essential for correctness and test isolation. No scope creep — backgroundGeolocationFacadeProvider was always needed, just earlier than planned.

## Checkpoint Outcome

**Checkpoint type:** human-verify (Task 4)
**On-device verification:** Samsung Galaxy S24, Android 14 — 2026-07-05
**Result:** APPROVED as-is, no copy revisions requested.
**Verified behaviors:**
- All 3 rationale pages render with correct copy, icons, and "Manual only" text button on page 2
- Denying "Always" lands on map with yellow banner visible at top
- Tapping banner opens OS Settings on app info page
- Granting "Always" from Settings and returning → banner disappears (AppLifecycleState.resumed re-check)
- Onboarding is not re-triggered (onboarding_done flag persists)
- No OS dialog re-appears after a single denial

## Test Coverage Summary

| Test file | Cases | Status |
|---|---|---|
| `tracking_capability_repository_test.dart` | 4 unit | Green |
| `onboarding_ladder_test.dart` | 9 widget | Green |
| `permission_denial_banner_test.dart` | 4 widget | Green |
| `app_router_test.dart` (patched) | existing + 3-page path | Green |
| `widget_test.dart` (patched) | existing + 3-page path | Green |

Total new test assertions: 17 (4 unit + 9 ladder widget + 4 banner widget). All 19 test cases green (`flutter test test/features/onboarding/ test/features/map/permission_denial_banner_test.dart`).

## Issues Encountered

None — plan executed on the first pass. The regression fix (b3b93a0) was an anticipated cleanup after the `OnboardingScreen` replacement; existing tests were known to reference Phase-1 copy.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `trackingCapabilityProvider` (FutureProvider) is ready for 03-04 `TrackingNotifier` to read and decide whether to auto-start tracking on app resume
- `backgroundGeolocationFacadeProvider` is created and shared — 03-04 can `ref.watch(backgroundGeolocationFacadeProvider)` without additional setup
- `permissionServiceProvider` + `FakePermissionService` are available for any Phase 3+ test that touches permission state
- No blockers for 03-04 (TrackingService + Notifier) or 03-06 (TripFab)

---
*Phase: 03-tracking-mvp*
*Completed: 2026-07-05*
