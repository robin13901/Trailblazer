---
plan: "02-03"
title: "Location permission + blue dot + camera state (Phase 3-ready)"
phase: "02-map-glass-shell"
type: execute
wave: 2
depends_on: ["02-02"]
files_modified:
  - pubspec.yaml
  - lib/features/map/data/location_repository.dart
  - lib/features/map/data/location_repository_providers.dart
  - lib/features/map/domain/camera_state.dart
  - lib/features/map/domain/follow_mode.dart
  - lib/features/map/presentation/providers/map_controller_provider.dart
  - lib/features/map/presentation/providers/camera_state_provider.dart
  - lib/features/map/presentation/providers/location_permission_provider.dart
  - lib/features/map/presentation/widgets/map_widget.dart              # extended
  - lib/features/map/presentation/widgets/recenter_button.dart
  - lib/features/onboarding/presentation/onboarding_screen.dart        # add permission request
  - test/features/map/camera_state_test.dart
  - test/features/map/location_repository_test.dart
autonomous: true

must_haves:
  truths:
    - "On a device where location permission is granted, `MapWidget` shows the blue dot + heading cone + accuracy ring (MapLibre built-in)."
    - "On app launch the map camera opens at the current device location (or a documented fallback if unavailable / denied). Camera is NOT restored from storage (per CONTEXT.md — no persistence)."
    - "The Continue button on `OnboardingScreen` requests `Permission.locationWhenInUse` before navigating away from onboarding."
    - "A dedicated re-center control snaps the camera back to current location and re-enters follow mode (MyLocationTrackingMode.tracking)."
    - "Panning away from the location exits follow mode (`isFollowing = false`); the re-center control becomes visible."
    - "`CameraState` domain model has extension points for Phase 3: `FollowMode` enum (`none`, `location`, `locationAndHeading`) — but Phase 2 only USES `none` + `location`."
    - "Denied permission does NOT crash the map; blue dot is simply absent and camera falls back to the Phase-2 default target."
    - "`flutter test` + `flutter analyze` green."
  artifacts:
    - path: lib/features/map/domain/camera_state.dart
      provides: "Immutable camera state (lat/lng/zoom/bearing/followMode)."
      contains: "class CameraState"
    - path: lib/features/map/domain/follow_mode.dart
      provides: "Enum with Phase-3-forward slots: none / location / locationAndHeading."
      contains: "enum FollowMode"
    - path: lib/features/map/data/location_repository.dart
      provides: "Wraps permission_handler + one-shot current position read."
      exports: ["LocationRepository", "LocationReadResult"]
    - path: lib/features/map/presentation/providers/camera_state_provider.dart
      provides: "NotifierProvider<CameraState> — plain Provider, no codegen."
      contains: "class CameraStateNotifier"
    - path: lib/features/map/presentation/providers/map_controller_provider.dart
      provides: "Holder for the MapLibreMapController lifecycle."
      contains: "class MapControllerNotifier"
    - path: lib/features/map/presentation/providers/location_permission_provider.dart
      provides: "AsyncNotifier that surfaces current locationWhenInUse status."
      contains: "class LocationPermissionNotifier"
    - path: lib/features/map/presentation/widgets/recenter_button.dart
      provides: "Small floating control that re-enters follow mode."
      contains: "class RecenterButton"
  key_links:
    - from: lib/features/onboarding/presentation/onboarding_screen.dart
      to: lib/features/map/data/location_repository.dart
      via: "Continue button awaits Permission.locationWhenInUse.request()"
      pattern: "Permission.locationWhenInUse.request"
    - from: lib/features/map/presentation/widgets/map_widget.dart
      to: lib/features/map/presentation/providers/location_permission_provider.dart
      via: "ref.watch → sets myLocationEnabled on MapLibreMap"
      pattern: "myLocationEnabled"
    - from: lib/features/map/presentation/widgets/map_widget.dart
      to: lib/features/map/presentation/providers/camera_state_provider.dart
      via: "onCameraTrackingDismissed → CameraStateNotifier.setFollowMode(FollowMode.none)"
      pattern: "onCameraTrackingDismissed"
    - from: lib/features/map/presentation/widgets/recenter_button.dart
      to: lib/features/map/presentation/providers/map_controller_provider.dart
      via: "controller.updateMyLocationTrackingMode(MyLocationTrackingMode.tracking)"
      pattern: "updateMyLocationTrackingMode"
---

<objective>
Wire location permission into onboarding, show the blue dot on the map, open the camera at the user's current location, and support follow-mode toggling with a re-center control. Build a `CameraState` + `FollowMode` architecture that Phase 3 can extend to `locationAndHeading` (heading-lock during active trip) without rewriting anything.

Purpose: Satisfies MAP-04, MAP-07 (with Phase-2 override — see CONTEXT.md: camera opens at current location, no persistence), TRK-10 groundwork (whenInUse permission — Phase 3 will extend to Always).
Output: A Riverpod-Notifier-based camera + permission architecture, plus onboarding wiring.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/02-map-glass-shell/02-CONTEXT.md
@.planning/phases/02-map-glass-shell/02-RESEARCH.md
@.planning/research/PITFALLS.md
@lib/features/onboarding/presentation/onboarding_screen.dart
@lib/features/map/presentation/widgets/map_widget.dart
@pubspec.yaml
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add permission_handler; build domain + data layer</name>
  <files>
    - pubspec.yaml
    - lib/features/map/domain/follow_mode.dart
    - lib/features/map/domain/camera_state.dart
    - lib/features/map/data/location_repository.dart
    - lib/features/map/data/location_repository_providers.dart
    - test/features/map/camera_state_test.dart
    - test/features/map/location_repository_test.dart
  </files>
  <action>
    1. Add `permission_handler: ^12.0.3` to `pubspec.yaml` `dependencies:` (keep alphabetical). Run `flutter pub get`.

    2. Create `lib/features/map/domain/follow_mode.dart`:
       ```dart
       /// Camera follow modes.
       ///
       /// Phase 2 uses only [none] and [location].
       /// Phase 3 (Tracking MVP) will activate [locationAndHeading] during
       /// active trip recording — the enum slot is reserved here so that
       /// Phase 3 does not touch [CameraState]'s shape.
       enum FollowMode {
         /// User has panned/rotated freely. Camera does not follow anything.
         none,

         /// Camera follows current location (blue dot centered). No heading
         /// rotation — user rotation gestures are preserved.
         location,

         /// Phase-3 only: camera follows current location AND rotates to match
         /// current heading (bearing-lock while driving).
         locationAndHeading,
       }
       ```

    3. Create `lib/features/map/domain/camera_state.dart` **without** freezed/codegen (Phase 1 rule: no build_runner for state):
       ```dart
       import 'package:auto_explore/features/map/domain/follow_mode.dart';

       /// Immutable camera state. Manual `copyWith` + `==` (no freezed —
       /// Phase 1 locked in a no-codegen policy for state classes).
       class CameraState {
         const CameraState({
           required this.latitude,
           required this.longitude,
           required this.zoom,
           this.bearing = 0,
           this.followMode = FollowMode.none,
         });

         final double latitude;
         final double longitude;
         final double zoom;
         final double bearing;
         final FollowMode followMode;

         /// Phase-2 default: unknown position, zoom 15 (address-level),
         /// no follow. Replaced as soon as first location fix arrives OR
         /// the user pans.
         static const CameraState initial = CameraState(
           latitude: 0,
           longitude: 0,
           zoom: 15,
         );

         CameraState copyWith({
           double? latitude,
           double? longitude,
           double? zoom,
           double? bearing,
           FollowMode? followMode,
         }) => CameraState(
               latitude: latitude ?? this.latitude,
               longitude: longitude ?? this.longitude,
               zoom: zoom ?? this.zoom,
               bearing: bearing ?? this.bearing,
               followMode: followMode ?? this.followMode,
             );

         @override
         bool operator ==(Object other) =>
             other is CameraState &&
             other.latitude == latitude &&
             other.longitude == longitude &&
             other.zoom == zoom &&
             other.bearing == bearing &&
             other.followMode == followMode;

         @override
         int get hashCode =>
             Object.hash(latitude, longitude, zoom, bearing, followMode);
       }
       ```

    4. Create `lib/features/map/data/location_repository.dart`:
       ```dart
       import 'package:auto_explore/core/errors/domain_error.dart';
       import 'package:auto_explore/core/errors/result.dart';
       import 'package:permission_handler/permission_handler.dart';

       /// Read-once location repository for Phase 2.
       ///
       /// Phase 2 needs the current position ONLY to open the camera at
       /// the right place on app launch. Phase 3 replaces the "position
       /// stream" concern with `flutter_background_geolocation`; this
       /// repo does NOT provide a stream.
       ///
       /// The blue-dot on the map is rendered by MapLibre's built-in
       /// location engine; we don't provide those coordinates ourselves.
       class LocationRepository {
         const LocationRepository();

         /// Returns the current permission status without triggering a
         /// prompt.
         Future<PermissionStatus> currentStatus() =>
             Permission.locationWhenInUse.status;

         /// Requests `whenInUse` permission (idempotent — iOS shows the
         /// system prompt at most once).
         Future<PermissionStatus> requestPermission() =>
             Permission.locationWhenInUse.request();

         /// Phase 2 uses MapLibre's built-in engine for both the blue
         /// dot AND the initial camera target — via
         /// `MyLocationTrackingMode.tracking`. This method exists as
         /// an extension point but is intentionally not called in
         /// Phase 2. Returning `Err(DomainError.permission(...))` on
         /// denied keeps callers honest.
         Future<Result<bool>> hasPermission() async {
           try {
             final s = await Permission.locationWhenInUse.status;
             return Ok(s.isGranted || s.isLimited);
           } on Object catch (e, st) {
             return Err(DomainError.wrap(e, st));
           }
         }
       }
       ```

       If your `DomainError` / `Result` API from Phase 1 differs (check `lib/core/errors/` for actual signatures), adapt. Prefer the actual API over the sketch above.

    5. Create `lib/features/map/data/location_repository_providers.dart`:
       ```dart
       import 'package:auto_explore/features/map/data/location_repository.dart';
       import 'package:flutter_riverpod/flutter_riverpod.dart';

       final locationRepositoryProvider =
           Provider<LocationRepository>((ref) => const LocationRepository());
       ```

    6. Tests — `test/features/map/camera_state_test.dart` and `test/features/map/location_repository_test.dart`:

       `camera_state_test.dart`: unit-test `copyWith`, `==`, `initial`, and that `FollowMode` has exactly 3 values in the expected order.

       `location_repository_test.dart`: Use `PermissionHandlerPlatform`'s mock (`permission_handler_platform_interface` provides `MockPermissionHandlerPlatform`) to assert `requestPermission()` calls through to the platform and `currentStatus()` reflects the mocked status. If mocking permission_handler is heavy, this test can be a smoke test that constructs the repo and asserts non-null; do NOT over-engineer.
  </action>
  <verify>
    ```
    flutter pub get
    flutter test test/features/map/camera_state_test.dart
    flutter test test/features/map/location_repository_test.dart
    flutter analyze lib/features/map/ test/features/map/
    ```
    All green.
  </verify>
  <done>
    - `permission_handler` in pubspec.
    - `CameraState`, `FollowMode`, `LocationRepository` compile.
    - Tests pass.
  </done>
</task>

<task type="auto">
  <name>Task 2: Riverpod providers — map controller, camera state, location permission</name>
  <files>
    - lib/features/map/presentation/providers/map_controller_provider.dart
    - lib/features/map/presentation/providers/camera_state_provider.dart
    - lib/features/map/presentation/providers/location_permission_provider.dart
  </files>
  <action>
    All plain `Notifier` / `AsyncNotifier` — no `@Riverpod` codegen (Phase 1 rule; `riverpod_generator` is in dev_deps but the project-wide decision is to not use it while `custom_lint`/`riverpod_lint` are out).

    1. `map_controller_provider.dart`:
       ```dart
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:maplibre_gl/maplibre_gl.dart';

       class MapControllerNotifier extends Notifier<MapLibreMapController?> {
         @override
         MapLibreMapController? build() => null;

         void attach(MapLibreMapController controller) => state = controller;
         void detach() => state = null;
       }

       final mapControllerProvider =
           NotifierProvider<MapControllerNotifier, MapLibreMapController?>(
         MapControllerNotifier.new,
       );
       ```

    2. `camera_state_provider.dart`:
       ```dart
       import 'package:auto_explore/features/map/domain/camera_state.dart';
       import 'package:auto_explore/features/map/domain/follow_mode.dart';
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:maplibre_gl/maplibre_gl.dart';

       class CameraStateNotifier extends Notifier<CameraState> {
         @override
         CameraState build() => CameraState.initial;

         void updateFromMap(CameraPosition position) {
           state = state.copyWith(
             latitude: position.target.latitude,
             longitude: position.target.longitude,
             zoom: position.zoom,
             bearing: position.bearing,
           );
         }

         void setFollowMode(FollowMode mode) =>
             state = state.copyWith(followMode: mode);
       }

       final cameraStateProvider =
           NotifierProvider<CameraStateNotifier, CameraState>(
         CameraStateNotifier.new,
       );
       ```

    3. `location_permission_provider.dart`:
       ```dart
       import 'package:auto_explore/features/map/data/location_repository.dart';
       import 'package:auto_explore/features/map/data/location_repository_providers.dart';
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:permission_handler/permission_handler.dart';

       class LocationPermissionNotifier extends AsyncNotifier<PermissionStatus> {
         @override
         Future<PermissionStatus> build() {
           final repo = ref.watch(locationRepositoryProvider);
           return repo.currentStatus();
         }

         /// Called from onboarding Continue button. Refreshes state.
         Future<PermissionStatus> requestOnce() async {
           final repo = ref.read(locationRepositoryProvider);
           final result = await repo.requestPermission();
           state = AsyncData(result);
           return result;
         }

         /// Called if the user changes permission via system settings and
         /// returns to the app — Phase 2 doesn't hook this yet; Plan 02-07
         /// or Phase 3 can wire it via WidgetsBindingObserver.didChangeAppLifecycleState.
         Future<void> refresh() async {
           final repo = ref.read(locationRepositoryProvider);
           state = AsyncData(await repo.currentStatus());
         }
       }

       final locationPermissionProvider = AsyncNotifierProvider<
           LocationPermissionNotifier, PermissionStatus>(
         LocationPermissionNotifier.new,
       );
       ```
  </action>
  <verify>
    ```
    flutter analyze lib/features/map/presentation/providers/
    ```
    Zero issues.
  </verify>
  <done>
    - Three provider files exist and compile.
    - No `@Riverpod` annotations; all providers are plain top-level Provider/NotifierProvider/AsyncNotifierProvider.
  </done>
</task>

<task type="auto">
  <name>Task 3: Extend MapWidget — location + camera state wiring + recenter button</name>
  <files>
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/presentation/widgets/recenter_button.dart
  </files>
  <action>
    1. Refactor `MapWidget` (from 02-02) into a `ConsumerStatefulWidget` and add:
       - `ref.watch(locationPermissionProvider)` → set `myLocationEnabled` based on granted status.
       - `ref.watch(cameraStateProvider).followMode` → set `myLocationTrackingMode` (`tracking` when `location` or `locationAndHeading`, else `none`).
       - `onCameraTrackingDismissed` callback → `ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none)`.
       - `onCameraIdle` (or `onCameraTrackingChanged`) → update `CameraState` position/zoom via the notifier.
       - `onMapCreated` → attach to `mapControllerProvider`.
       - `dispose` → detach controller.
       - `initialCameraPosition`: if a passed-in `initialTarget` was `null` OR default sentinel, use `LatLng(52.52, 13.40)` (Berlin) as safe fallback. The camera will be re-centered onto the user location by MapLibre's tracking engine as soon as the first fix arrives. Do NOT read GPS ourselves — Pitfall 5 says MapLibre does this internally.
       - Set `myLocationRenderMode: MyLocationRenderMode.compass` (blue dot + heading cone + accuracy ring).

       Design constraints:
       - `myLocationEnabled` starts `false`; flips to `true` inside the `ref.listen` when permission becomes granted. Full widget REBUILD is acceptable — MapLibre handles the flag change without recreating the native view (verified in 02-RESEARCH.md Pitfall 5 note).
       - Wrap the widget in a Stack that overlays a `RecenterButton` when `state.followMode == FollowMode.none` AND permission is granted (so the user can snap back).

    2. Create `lib/features/map/presentation/widgets/recenter_button.dart`:
       ```dart
       import 'package:auto_explore/features/map/domain/follow_mode.dart';
       import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
       import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
       import 'package:flutter/material.dart';
       import 'package:flutter_riverpod/flutter_riverpod.dart';
       import 'package:maplibre_gl/maplibre_gl.dart';

       /// Small circular button — bottom-right (above the FAB row).
       /// Visible only when the user has panned away from location.
       ///
       /// Glass styling is deferred to Plan 02-05, which either re-skins
       /// this button or wraps it based on LiquidGlassSettings.
       class RecenterButton extends ConsumerWidget {
         const RecenterButton({super.key});

         @override
         Widget build(BuildContext context, WidgetRef ref) {
           return Material(
             color: Colors.white.withValues(alpha: 0.9),
             shape: const CircleBorder(),
             elevation: 3,
             child: InkWell(
               customBorder: const CircleBorder(),
               onTap: () async {
                 final controller = ref.read(mapControllerProvider);
                 if (controller == null) return;
                 await controller.updateMyLocationTrackingMode(
                   MyLocationTrackingMode.tracking,
                 );
                 ref.read(cameraStateProvider.notifier)
                     .setFollowMode(FollowMode.location);
               },
               child: const SizedBox(
                 width: 44, height: 44,
                 child: Icon(Icons.my_location, size: 22),
               ),
             ),
           );
         }
       }
       ```

    Verify that `MyLocationTrackingMode.tracking` is the correct enum value in `maplibre_gl` 0.26.2. If the enum shape differs, adjust.

    Rationale for the architecture: the `FollowMode` enum + the fact that follow-mode changes go through `CameraStateNotifier.setFollowMode` means Phase 3 can add a `.locationAndHeading` case, wire it to `MyLocationTrackingMode.trackingCompass` (or the equivalent in maplibre_gl), and add a `myLocationRenderMode: MyLocationRenderMode.compass` boost — all without touching `CameraState`'s shape or `RecenterButton`. That IS the extension point the CONTEXT.md required.
  </action>
  <verify>
    ```
    flutter analyze lib/features/map/
    flutter test    # existing 02-02 map_widget_test may need updating; adjust to new ConsumerStatefulWidget
    ```
    Green. If `map_widget_test.dart` breaks because the widget is now Consumer + needs a ProviderScope, update it to wrap with `ProviderScope` and continue asserting the same config flags.
  </verify>
  <done>
    - `MapWidget` now consumes `locationPermissionProvider` + `cameraStateProvider` + `mapControllerProvider`.
    - `RecenterButton` compiles and calls `updateMyLocationTrackingMode(tracking)` + notifier `setFollowMode(location)`.
    - Existing widget tests still pass (updated for ProviderScope if needed).
  </done>
</task>

<task type="auto">
  <name>Task 4: Wire location permission request into OnboardingScreen</name>
  <files>
    - lib/features/onboarding/presentation/onboarding_screen.dart
  </files>
  <action>
    Extend `OnboardingScreen` so the Continue button awaits `locationPermissionProvider.notifier.requestOnce()` BEFORE calling `repo.markDone()` + `context.go('/')`.

    Design:
    - Show a short informational paragraph above the button (per UI research): "Trailblazer needs your location to paint the roads you drive onto the map. On the next tap, iOS/Android will ask for permission." Keep copy short and honest.
    - Handle denial gracefully: if the user denies, still let them proceed (don't gate the app). The map will render without the blue dot. Show a brief SnackBar-style hint via `ScaffoldMessenger` after the request completes IF denied: "Location denied — you can enable it later in Settings." Do NOT block navigation on denial.
    - iOS `whenInUse` prompt is one-shot; on subsequent runs the request returns the cached status without a system dialog (per permission_handler docs). This is fine.
    - Log outcome via the Phase-1 `AppLogger` at `info` level (permission granted/denied); wrap any exception via `DomainError.wrap` and log at `warning`.

    Sketch (adapt to actual `AppLogger` + `DomainError` API from Phase 1):
    ```dart
    FilledButton(
      onPressed: () async {
        final scaffold = ScaffoldMessenger.of(context);
        final router = GoRouter.of(context);
        try {
          final status = await ref
              .read(locationPermissionProvider.notifier)
              .requestOnce();
          AppLogger.instance.info(
            'onboarding.location_permission',
            'status=$status',
          );
          if (!status.isGranted && !status.isLimited && context.mounted) {
            scaffold.showSnackBar(const SnackBar(
              content: Text(
                'Location denied — you can enable it later in Settings.',
              ),
            ));
          }
        } on Object catch (e, st) {
          AppLogger.instance.warning(
            'onboarding.location_permission_failed',
            DomainError.wrap(e, st).toString(),
          );
        }
        final repo = ref.read(onboardingFlagRepositoryProvider);
        await repo.markDone();
        if (!context.mounted) return;
        router.go('/');
      },
      child: const Text('Continue'),
    ),
    ```

    The existing onboarding widget test (`test/features/onboarding/...`) must still pass. If it asserts the exact Continue-button flow, either:
    (a) update the test to allow the permission call (mock `permission_handler` via its platform interface), OR
    (b) leave the test file as-is if it only checks navigation destination — since we don't gate navigation on the permission result.

    Update the widget test IF needed to inject a fake `LocationRepository` via `ProviderScope.overrides` returning `PermissionStatus.granted` (or `.denied`) synchronously.
  </action>
  <verify>
    ```
    flutter analyze lib/features/onboarding/
    flutter test test/features/onboarding/
    flutter test    # full suite
    ```
    All green.
  </verify>
  <done>
    - Onboarding Continue button requests `whenInUse` permission.
    - Denial does not block navigation; user sees a SnackBar hint.
    - AppLogger records outcome.
    - All tests (onboarding + widget_test.dart) still pass.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` → 0 issues
- `flutter test` → all pre-existing + new tests green
- Manual (checked in 02-07 real-device verification): install debug build, complete onboarding, grant location on system prompt, observe blue dot centered at current location; pan away, tap re-center, observe camera snap back and follow mode resume.
</verification>

<success_criteria>
- MAP-04 (blue dot when permission granted) achievable — MapLibre handles rendering; permission wired.
- MAP-07 partial (camera opens at current location — via `MyLocationTrackingMode.tracking` on mount; no persistence per CONTEXT.md).
- Follow-mode architecture (`FollowMode` enum + `CameraStateNotifier.setFollowMode`) supports Phase 3 heading-lock without any breaking changes.
- Denied permission does not crash the app.
</success_criteria>

<deviations>
(Executor logs. Examples: exact permission_handler API used, adjustments to `MyLocationTrackingMode` enum name, whether onboarding SnackBar copy was tweaked.)
</deviations>

<output>
After completion, create `.planning/phases/02-map-glass-shell/02-03-SUMMARY.md`:
- Frontmatter: `subsystem: location`, `affects: [02-05, 02-07, phase-3]`, `tech-stack.added: [permission_handler 12.0.3]`, `requires: [02-02]`
- Notes: extension point for Phase 3 (`FollowMode.locationAndHeading`), any deviation from the provider architecture, whether onboarding test needed a mock permission platform.
</output>
