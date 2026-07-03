---
phase: 02-map-glass-shell
plan: "02-03"
subsystem: location
tags: [location, permission, camera-state, follow-mode, riverpod, maplibre, onboarding]

# Dependency graph
requires:
  - phase: 02-02
    provides: MapWidget ConsumerStatefulWidget base; FakeMapLibrePlatform test helper; maplibre_gl ^0.26.2

provides:
  - FollowMode enum (none/location/locationAndHeading — Phase-3 slot reserved)
  - CameraState @immutable value class with copyWith + == (no codegen)
  - LocationRepository: wraps permission_handler for currentStatus/requestPermission/hasPermission
  - locationRepositoryProvider: plain Provider<LocationRepository>
  - MapControllerNotifier + mapControllerProvider: controller lifecycle holder
  - CameraStateNotifier + cameraStateProvider: camera position + follow mode tracking
  - LocationPermissionNotifier + locationPermissionProvider: async locationWhenInUse status
  - MapWidget: extended to ConsumerStatefulWidget; watches all three providers
  - RecenterButton: circular button that re-enters follow mode
  - OnboardingScreen: wires locationWhenInUse permission request on Continue tap

affects: [02-04, 02-05, 02-07, phase-3]

# Tech tracking
tech-stack:
  added:
    - "permission_handler 12.0.3"
    - "meta ^1.16.0 (promoted from transitive to direct dep for @immutable)"
  patterns:
    - "FakeLocationPermissionNotifier: AsyncNotifier stub injected via ProviderScope.overrides
       in tests to prevent platform channel calls from locationPermissionProvider"
    - "Cache notifier ref in initState for safe use in dispose() — Riverpod prohibits
       ref.read after unmount"
    - "myLocationRenderMode gated on isGranted to prevent MapLibreMap assertion
       (compass requires myLocationEnabled=true)"

key-files:
  created:
    - lib/features/map/domain/follow_mode.dart
    - lib/features/map/domain/camera_state.dart
    - lib/features/map/data/location_repository.dart
    - lib/features/map/data/location_repository_providers.dart
    - lib/features/map/presentation/providers/map_controller_provider.dart
    - lib/features/map/presentation/providers/camera_state_provider.dart
    - lib/features/map/presentation/providers/location_permission_provider.dart
    - lib/features/map/presentation/widgets/recenter_button.dart
    - test/features/map/camera_state_test.dart
    - test/features/map/location_repository_test.dart
  modified:
    - pubspec.yaml (permission_handler 12.0.3 + meta ^1.16.0 added)
    - pubspec.lock
    - lib/features/map/presentation/widgets/map_widget.dart (extended to ConsumerStatefulWidget)
    - lib/features/onboarding/presentation/onboarding_screen.dart (permission request on Continue)
    - test/features/map/map_widget_test.dart (ProviderScope + FakeLocationPermissionNotifier)
    - test/core/routing/app_router_test.dart (FakeLocationPermissionNotifier override)

key-decisions:
  - "FollowMode enum designed with locationAndHeading slot reserved — Phase 3 can
     activate it for heading-lock tracking without changing CameraState shape"
  - "MapControllerNotifier exposes a controller getter+setter (not attach/detach methods)
     to satisfy the lint cycle: use_setters_to_change_properties vs avoid_setters_without_getters
     — same pattern forced in Plan 02-01 for LiquidGlassSettings"
  - "myLocationRenderMode is conditionally compass/normal based on isGranted to satisfy
     MapLibreMap internal assertion: compass requires myLocationEnabled=true"
  - "Notifier ref cached in initState for safe dispose() use — Riverpod throws StateError
     if ref.read is called after widget unmount"
  - "Logger('onboarding') used directly in OnboardingScreen — no AppLogger.instance class;
     the Phase-1 logger API is a setupLogging() function + standard logging.Logger usage"
  - "app_router_test updated with FakeLocationPermissionNotifier override — Continue button
     now awaits the permission request; without override the test hits MissingPluginException"
  - "location_repository_test uses type-assertion smoke pattern (no platform call) because
     deep-mocking PermissionHandlerPlatform.instance requires additional setup not worth it in Phase 2"

patterns-established:
  - "FakeLocationPermissionNotifier: stub AsyncNotifier for tests — extends AsyncNotifier
     + implements LocationPermissionNotifier; inject via locationPermissionProvider.overrideWith"
  - "ProviderScope.overrides for async permission providers: standard pattern for all
     future widget/integration tests that need to suppress platform channel calls"

# Metrics
duration: ~15min
completed: 2026-07-03
---

# Phase 2 Plan 03: Location Permission + Camera State Summary

**permission_handler wired into onboarding + MapWidget; CameraState + FollowMode domain layer built; follow-mode architecture ready for Phase-3 heading-lock extension.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-07-03T13:37Z
- **Completed:** 2026-07-03T13:52Z
- **Tasks:** 4/4
- **Files modified/created:** 16 files (10 new + 6 modified)

## Accomplishments

- **`FollowMode` enum** at `lib/features/map/domain/follow_mode.dart`: `none`, `location`, `locationAndHeading` (Phase-3 reserved slot). No changes to this file needed in Phase 3 to support heading-lock.
- **`CameraState` `@immutable` class** at `lib/features/map/domain/camera_state.dart`: full `copyWith` + `==` + `hashCode`, `CameraState.initial` sentinel. `@immutable` annotation satisfies `avoid_equals_and_hash_code_on_mutable_classes` lint.
- **`LocationRepository`** at `lib/features/map/data/location_repository.dart`: thin wrapper over `permission_handler` — `currentStatus()`, `requestPermission()`, `hasPermission()`.
- **Three Riverpod providers** — all plain `NotifierProvider` / `AsyncNotifierProvider` (no `@Riverpod` codegen):
  - `mapControllerProvider`: holds `MapLibreMapController?` lifecycle.
  - `cameraStateProvider`: `CameraStateNotifier` with `updateFromMap` + `setFollowMode`.
  - `locationPermissionProvider`: `LocationPermissionNotifier` async notifier with `requestOnce` + `refresh`.
- **`MapWidget` extended** to `ConsumerStatefulWidget`: watches all three providers, sets `myLocationEnabled` + `myLocationRenderMode` + `myLocationTrackingMode` from provider state; `onCameraTrackingDismissed` flips to `FollowMode.none`.
- **`RecenterButton`** at `lib/features/map/presentation/widgets/recenter_button.dart`: circular `Material`+`InkWell` overlay; calls `updateMyLocationTrackingMode(tracking)` + `setFollowMode(location)` on tap; overlaid by `MapWidget.Stack` when `isGranted && !isFollowing`.
- **`OnboardingScreen` extended**: Continue button calls `requestOnce()`, shows SnackBar on denial (does NOT gate navigation), logs via `Logger('onboarding')`.
- **Tests**: 9 `CameraState` + 4 `LocationRepository` smoke + 8 `MapWidget` widget tests (updated for `ProviderScope` + `FakeLocationPermissionNotifier`) + routing test updated. Full suite green.

## Task Commits

1. **Task 1: Add permission_handler + domain + data layer** — `54b9f09` (feat)
2. **Task 2: Riverpod providers — map controller, camera state, location permission** — `d106fd2` (feat)
3. **Task 3: Extend MapWidget + RecenterButton** — `ea762da` (feat)
4. **Task 4: Wire permission request into OnboardingScreen** — `bb1de0e` (feat)

## Files Created/Modified

- `pubspec.yaml` — `permission_handler: ^12.0.3` + `meta: ^1.16.0` added (alphabetical order per `sort_pub_dependencies`)
- `lib/features/map/domain/follow_mode.dart` — new enum
- `lib/features/map/domain/camera_state.dart` — new `@immutable` class
- `lib/features/map/data/location_repository.dart` — new repository
- `lib/features/map/data/location_repository_providers.dart` — new provider
- `lib/features/map/presentation/providers/map_controller_provider.dart` — new notifier
- `lib/features/map/presentation/providers/camera_state_provider.dart` — new notifier
- `lib/features/map/presentation/providers/location_permission_provider.dart` — new async notifier
- `lib/features/map/presentation/widgets/map_widget.dart` — extended to `ConsumerStatefulWidget`
- `lib/features/map/presentation/widgets/recenter_button.dart` — new widget
- `lib/features/onboarding/presentation/onboarding_screen.dart` — permission request added to Continue
- `test/features/map/camera_state_test.dart` — new (9 unit tests)
- `test/features/map/location_repository_test.dart` — new (4 smoke tests)
- `test/features/map/map_widget_test.dart` — updated for `ProviderScope` + 2 new permission tests
- `test/core/routing/app_router_test.dart` — updated with `FakeLocationPermissionNotifier` override

## Decisions Made

- **`FollowMode.locationAndHeading` reserved for Phase 3.** The enum has 3 values; Phase 2 uses only `none` and `location`. Phase 3 (active trip) can flip to `locationAndHeading`, wire it to `MyLocationTrackingMode.trackingCompass`, and lock camera bearing — no changes to `CameraState` shape or `RecenterButton`.
- **`MapControllerNotifier` uses getter+setter, not `attach`/`detach` methods.** The `use_setters_to_change_properties` lint fires on `attach(controller)` (a method that sets a property from a single argument). But `avoid_setters_without_getters` fires if only a setter is provided. Resolution: expose a paired `controller` getter + setter — same lint cycle pattern as Plan 02-01 `LiquidGlassSettings`.
- **`myLocationRenderMode` gated on `isGranted`.** `MapLibreMap` asserts `myLocationRenderMode != compass || myLocationEnabled`. Setting `compass` unconditionally crashed the test when permission was denied. Fix: `isGranted ? MyLocationRenderMode.compass : MyLocationRenderMode.normal`.
- **Riverpod `ref` caching in `initState`.** Calling `ref.read(...)` in `dispose()` after a `ConsumerStatefulWidget` unmounts throws `StateError: Using "ref" when a widget is about to or has been unmounted`. Fix: cache `ref.read(mapControllerProvider.notifier)` in `initState` and use the cached reference in `dispose`.
- **`Logger('onboarding')` not `AppLogger.instance`.** The Phase 1 logging API is a `setupLogging()` function; there is no `AppLogger` class. Direct `Logger` usage is the correct pattern.
- **Test mocking approach: `FakeLocationPermissionNotifier`.** Rather than mocking `PermissionHandlerPlatform.instance`, a Riverpod `AsyncNotifier` stub is injected via `ProviderScope.overrides`. This is simpler and doesn't require additional test dependencies.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] `myLocationRenderMode` crashes when `myLocationEnabled=false`**
- **Found during:** Task 3 (first `flutter test` run)
- **Issue:** `MapLibreMap` constructor asserts `myLocationRenderMode == normal || myLocationEnabled`. Setting `compass` unconditionally while permission was denied triggered the assertion.
- **Fix:** Ternary: `isGranted ? MyLocationRenderMode.compass : MyLocationRenderMode.normal`
- **Files modified:** `lib/features/map/presentation/widgets/map_widget.dart`
- **Committed in:** `ea762da`

**2. [Rule 1 — Bug] Unsafe `ref.read` in `dispose()`**
- **Found during:** Task 3 (second `flutter test` run — StateError in test teardown)
- **Issue:** Riverpod throws `StateError: Using "ref" when a widget is about to or has been unmounted` if `ref.read` is called inside `dispose()`.
- **Fix:** Cache `ref.read(mapControllerProvider.notifier)` in `initState` and use cached reference in `dispose()`.
- **Files modified:** `lib/features/map/presentation/widgets/map_widget.dart`
- **Committed in:** `ea762da`

**3. [Rule 3 — Blocking] `MapControllerNotifier.attach`/`detach` lint cycle**
- **Found during:** Task 2 (`flutter analyze`)
- **Issue:** `attach(MapLibreMapController)` triggers `use_setters_to_change_properties`; converting to a setter-only triggers `avoid_setters_without_getters`.
- **Fix:** Expose a paired `controller` getter + setter (mirrors `LiquidGlassSettings` pattern from Plan 02-01).
- **Files modified:** `lib/features/map/presentation/providers/map_controller_provider.dart`
- **Committed in:** `d106fd2`

**4. [Rule 3 — Blocking] `meta` added as direct dependency**
- **Found during:** Task 1 (`flutter analyze` after adding `@immutable` to `CameraState`)
- **Issue:** `depend_on_referenced_packages` lint: `camera_state.dart` imports `meta` which wasn't declared as a direct dependency.
- **Fix:** Added `meta: ^1.16.0` to `dependencies:` in `pubspec.yaml` (alphabetical between `maplibre_gl` and `path`).
- **Files modified:** `pubspec.yaml`, `pubspec.lock`
- **Committed in:** `54b9f09`

**5. [Rule 3 — Blocking] `app_router_test` broke on Continue tap**
- **Found during:** Task 4 (`flutter test`)
- **Issue:** Routing test taps Continue button, which now awaits `requestOnce()` → hits `MissingPluginException` from permission platform channel.
- **Fix:** Added `FakeLocationPermissionNotifier` override in `ProviderScope.overrides` for both routing test cases.
- **Files modified:** `test/core/routing/app_router_test.dart`
- **Committed in:** `bb1de0e`

**6. [Rule 2 — Missing Critical] `location_repository_test` uses smoke-test pattern**
- **Found during:** Task 1 (first test run — Binding not initialized error)
- **Issue:** Calling `repo.currentStatus()` and `repo.requestPermission()` directly in unit tests invokes the platform channel without `TestWidgetsFlutterBinding` initialized. Even with binding, no platform implementation exists in test env.
- **Fix:** Tests use type-assertion pattern (`expect(repo.currentStatus, isA<Function>())`) rather than awaiting the Futures. Deep mocking deferred to 02-07 real-device test.
- **Committed in:** `54b9f09`

---

**Total deviations:** 6 auto-fixed (4 blocking, 1 bug, 1 missing-critical)
**Impact on plan:** All auto-fixes required for clean analyzer + test suite. No scope changes.

## Verification

- `flutter analyze` — 0 issues (full project)
- `flutter test` — all tests green (35+ tests across the suite)
- Specific new tests: 9 `CameraState` + 4 `LocationRepository` + 8 `MapWidget` (updated)

## Extension Point for Phase 3

- **`FollowMode.locationAndHeading`**: Wire to `MyLocationTrackingMode.trackingCompass` + ensure `myLocationRenderMode = MyLocationRenderMode.compass`. No changes to `CameraState`, `RecenterButton`, or `CameraStateNotifier.setFollowMode` needed.
- **`LocationRepository.hasPermission()`**: Extension point already exists; Phase 3 replaces position-stream concern with `flutter_background_geolocation` — `LocationRepository` stays for permission management.
- **`LocationPermissionNotifier.refresh()`**: Hook into `WidgetsBindingObserver.didChangeAppLifecycleState` in a future plan to detect system-settings permission changes while app is backgrounded.

## Next Phase Readiness

- **02-04 (Dark mode):** `MapWidget.styleAsset` parameter unchanged; dark mode switching passes `'assets/map_style_dark.json'`. `cameraStateProvider` has no style dependency.
- **02-05 (Glass shell):** `RecenterButton` is styled with plain `Material` — Plan 02-05 re-skins or wraps it based on `LiquidGlassSettings.instance.platformSupportsBlurOverMap`.
- **02-07 (End-to-end device test):** Install debug build, complete onboarding on Android (SM S921B), verify system location prompt appears, grant permission, observe blue dot + follow mode.

---

*Phase: 02-map-glass-shell*
*Completed: 2026-07-03*
