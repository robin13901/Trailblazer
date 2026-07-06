---
id: 03-1-03
phase: 03-1-tracking-fixes
plan: 03
type: execute
wave: 2
depends_on: [03-1-01]
files_modified:
  - lib/features/map/presentation/widgets/map_widget.dart
  - lib/features/map/presentation/widgets/tracking_camera_sync.dart
  - lib/features/map/presentation/screens/map_screen.dart
  - test/features/map/tracking_camera_sync_test.dart
  - test/features/map/map_widget_follow_mode_test.dart
autonomous: true
requirements: []

must_haves:
  truths:
    - "On TrackingRecording state transitions, the camera enters MyLocationTrackingMode.trackingCompass (heading-lock) on the map — verified via widget test asserting the MapLibreMap prop after a fake state change"
    - "On TrackingIdle state transitions, the camera releases follow mode — verified via widget test"
    - "The FollowMode.locationAndHeading enum branch maps to MyLocationTrackingMode.trackingCompass — the second bug identified in 03-1-RESEARCH §3.3 is closed"
    - "A user pan (onCameraTrackingDismissed) mid-trip still wins over the automatic tracking listener — the pan-dismiss handler is preserved, the tracking listener only fires on state TRANSITIONS (not every state read)"
    - "The tracking→camera sync is registered exactly once — no double-registration on hot reload — via ref.listen inside build() rather than initState()"
    - "flutter analyze and flutter test both green — behavior-sensitive UI change, so full suite runs inside the tight loop"
  artifacts:
    - path: "lib/features/map/presentation/widgets/tracking_camera_sync.dart"
      provides: "New ConsumerWidget that mounts alongside MapWidget, uses ref.listen<TrackingState> to drive cameraStateProvider.notifier.setFollowMode on trip start/stop transitions. No visible UI — this is a headless listener widget."
    - path: "lib/features/map/presentation/widgets/map_widget.dart"
      provides: "The MyLocationTrackingMode mapping on line ~174 fixed: FollowMode.locationAndHeading → MyLocationTrackingMode.trackingCompass; FollowMode.location → MyLocationTrackingMode.tracking (unchanged); FollowMode.none → MyLocationTrackingMode.none (unchanged)"
    - path: "lib/features/map/presentation/screens/map_screen.dart"
      provides: "TrackingCameraSync widget mounted inside the map Stack (or as a sibling in the Consumer subtree) so the listener runs whenever the map screen is alive"
  key_links:
    - from: "lib/features/map/presentation/widgets/tracking_camera_sync.dart"
      to: "lib/features/map/presentation/providers/camera_state_provider.dart"
      via: "ref.read(cameraStateProvider.notifier).setFollowMode(...) inside a ref.listen<TrackingState>(trackingStateProvider, ...) callback"
      pattern: "setFollowMode(FollowMode.locationAndHeading)"
    - from: "lib/features/map/presentation/widgets/map_widget.dart"
      to: "lib/features/map/domain/follow_mode.dart"
      via: "switch-on FollowMode → MyLocationTrackingMode.{none|tracking|trackingCompass} branch table on the myLocationTrackingMode prop"
      pattern: "MyLocationTrackingMode.trackingCompass"
    - from: "lib/features/map/presentation/screens/map_screen.dart"
      to: "lib/features/map/presentation/widgets/tracking_camera_sync.dart"
      via: "Stack children include TrackingCameraSync alongside MapWidget"
      pattern: "TrackingCameraSync"
---

## Goal

Close H2 — wire `trackingStateProvider` to `cameraStateProvider` so the map camera follows the driver during recording, and fix the second bug on `map_widget.dart:174` where `FollowMode.locationAndHeading` was incorrectly mapped to `MyLocationTrackingMode.tracking` (should be `.trackingCompass`).

## Context

- 03-1-RESEARCH §3.1 — `setFollowMode(...)` has only three producers in `lib/`, none of which watch tracking state. The `FollowMode.locationAndHeading` slot was reserved in STATE Plan 02-03 for Phase 3 to activate — this wiring never happened.
- 03-1-RESEARCH §3.2 — the reservation is explicit: STATE Plan 02-03 line 94 "`FollowMode.locationAndHeading` slot reserved for Phase 3 heading-lock. Phase 3 wires it to `MyLocationTrackingMode.trackingCompass`; no changes to `CameraState` or `CameraStateNotifier.setFollowMode` needed."
- 03-1-RESEARCH §3.3 — the mapping bug at `map_widget.dart:174` currently maps BOTH `location` and `locationAndHeading` to `MyLocationTrackingMode.tracking`, never reaching `.trackingCompass`. Fix: use an explicit switch or branch table.
- 03-1-RESEARCH §9 Risk 3 — register the listener via `ref.listen` inside `build()`, NOT in `initState()`. Hot reload re-registers `initState` listeners multiple times, potentially fighting the pan-dismiss handler. `ref.listen` is Riverpod-dedup'd by construction.
- STATE decision Plan 02-03 (line 91) — Riverpod `ref` must NOT be used in `ConsumerStatefulWidget.dispose()` after unmount. `ref.listen` in `build()` avoids this hazard entirely.
- Do NOT modify `CameraState` shape or `CameraStateNotifier.setFollowMode` — STATE Plan 02-03 locks these as Phase 2 API. This plan uses them additively.
- The pan-dismiss precedence (STATE Plan 02-03: `onCameraTrackingDismissed → FollowMode.none`) MUST be preserved. Fire tracking sync ONLY on TrackingRecording START and TrackingIdle transitions — not on every fix. Otherwise a mid-trip pan would immediately snap back on the next fix arrival.
- Riverpod codegen OFF — plain `Provider<T>` / `Notifier` (STATE Plan 01-01).
- Package imports only — `package:auto_explore/…`.
- `withValues(alpha:)` — never `withOpacity()`.
- Ralph-Loop tight loop: `flutter analyze` + `flutter test` (behavior-sensitive UI change).

## Tasks

<task type="auto">
  <name>Task 1: TrackingCameraSync listener widget + MapScreen mount</name>
  <files>
    lib/features/map/presentation/widgets/tracking_camera_sync.dart
    lib/features/map/presentation/screens/map_screen.dart
    test/features/map/tracking_camera_sync_test.dart
  </files>
  <intent>Wire tracking state transitions to camera follow mode without stomping user pan-dismiss.</intent>
  <action>
    **Step 1 — Listener widget.** Create `lib/features/map/presentation/widgets/tracking_camera_sync.dart`:

    ```dart
    // Headless widget: no visible UI. Listens to trackingStateProvider and
    // drives cameraStateProvider on trip start/stop transitions.
    //
    // Fires ONLY on state TRANSITIONS (previous != next), not every state read.
    // A user pan (onCameraTrackingDismissed) mid-trip sets FollowMode.none;
    // subsequent same-state re-emits from tracking (per accepted fix — see
    // 03-1-RESEARCH §5.1) do NOT re-arm follow mode. Only a fresh
    // TrackingIdle → TrackingRecording edge triggers the compass lock.
    import 'package:auto_explore/features/map/domain/follow_mode.dart';
    import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
    import 'package:auto_explore/features/trips/domain/tracking_state.dart';
    import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
    import 'package:flutter/widgets.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';

    class TrackingCameraSync extends ConsumerWidget {
      const TrackingCameraSync({super.key});

      @override
      Widget build(BuildContext context, WidgetRef ref) {
        ref.listen<TrackingState>(trackingStateProvider, (previous, next) {
          // TrackingIdle → TrackingRecording: activate heading-lock.
          if (previous is TrackingIdle && next is TrackingRecording) {
            ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.locationAndHeading);
          }
          // TrackingRecording → TrackingIdle: release follow.
          if (previous is TrackingRecording && next is TrackingIdle) {
            ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
          }
          // TrackingRecording → TrackingRecording (per-fix re-emit): NO-OP.
          // Preserves user pan-dismiss precedence — the pan handler already
          // pushed FollowMode.none; we must not fight it on the next fix.
        });
        return const SizedBox.shrink();
      }
    }
    ```

    **Step 2 — Mount in MapScreen.** Add `TrackingCameraSync()` as a Stack child (or Column sibling — whatever the current MapScreen shape is) alongside the existing `MapWidget`. Order doesn't matter — the widget renders nothing.

    Confirm: if `MapScreen` is currently a `ConsumerWidget` returning a `Stack`, add `TrackingCameraSync()` as the last child; the SizedBox.shrink won't affect hit-testing.

    **Step 3 — Widget test.** `test/features/map/tracking_camera_sync_test.dart`:
    - Pump a `ProviderScope` with `trackingStateProvider` overridden to a controllable notifier and `cameraStateProvider` in default state.
    - Trigger `TrackingIdle → TrackingRecording` → read `cameraStateProvider` → assert `followMode == FollowMode.locationAndHeading`.
    - Trigger `TrackingRecording → TrackingIdle` → assert `followMode == FollowMode.none`.
    - Simulate user pan mid-trip: while `TrackingRecording`, manually push `FollowMode.none` via `setFollowMode` → then trigger a same-state re-emit (`TrackingRecording → TrackingRecording` with updated distance) → assert `followMode` stays `FollowMode.none` (pan wins).
  </action>
  <verify>
    `flutter analyze` — zero errors.
    `flutter test test/features/map/tracking_camera_sync_test.dart` — green (all 3 assertions).
    grep for `TrackingCameraSync` in `lib/` returns exactly 2 hits (widget decl + MapScreen mount).
    grep for `ref.listen<TrackingState>` in `lib/features/map/` returns exactly 1 hit.
  </verify>
  <done>
    TrackingCameraSync widget exists, mounted in MapScreen, and correctly drives follow mode on trip transitions while preserving pan-dismiss precedence. Widget test green.
  </done>
</task>

<task type="auto">
  <name>Task 2: Fix FollowMode → MyLocationTrackingMode mapping in map_widget.dart</name>
  <files>
    lib/features/map/presentation/widgets/map_widget.dart
    test/features/map/map_widget_follow_mode_test.dart
  </files>
  <intent>Close the second half of H2 — the mapping bug at `map_widget.dart:174`.</intent>
  <action>
    Current code (around line 150-176):
    ```dart
    final isFollowing =
        cameraState.followMode == FollowMode.location ||
        cameraState.followMode == FollowMode.locationAndHeading;
    ...
    myLocationTrackingMode: isFollowing
        ? MyLocationTrackingMode.tracking
        : MyLocationTrackingMode.none,
    ```

    New code — explicit switch on FollowMode preserves both existing modes and closes the bug:
    ```dart
    final trackingMode = switch (cameraState.followMode) {
      FollowMode.none => MyLocationTrackingMode.none,
      FollowMode.location => MyLocationTrackingMode.tracking,
      FollowMode.locationAndHeading => MyLocationTrackingMode.trackingCompass,
    };
    ...
    myLocationTrackingMode: trackingMode,
    ```

    The `isFollowing` local can stay in place (still used by other props if any), or be reduced to `trackingMode != MyLocationTrackingMode.none` if the code needs it downstream. Preserve the surrounding code shape — do not refactor beyond the mapping.

    Verify `MyLocationTrackingMode.trackingCompass` is exported from `maplibre_gl` 0.26.2 (it is per STATE Plan 02-03 decision line 94 — "wires it to `MyLocationTrackingMode.trackingCompass`"; the enum value has existed since 0.14).

    **Widget test — `test/features/map/map_widget_follow_mode_test.dart`.** Use the existing `FakeMapLibrePlatform` from `test/helpers/fake_maplibre_platform.dart` (STATE Plan 02-02 decision):
    - Pump MapWidget with `cameraStateProvider` overridden to `followMode: FollowMode.locationAndHeading` → capture the `myLocationTrackingMode` argument passed into `MapLibreMap` constructor (via the fake's tracker) → assert `MyLocationTrackingMode.trackingCompass`.
    - Repeat for `FollowMode.location` → `MyLocationTrackingMode.tracking`.
    - Repeat for `FollowMode.none` → `MyLocationTrackingMode.none`.

    If `FakeMapLibrePlatform` doesn't yet expose the tracked prop (my_location_tracking_mode), extend it — it's Wave 1 test infrastructure additive to STATE Plan 02-02's helper.
  </action>
  <verify>
    `flutter analyze` — zero errors (in particular: the exhaustive switch produces no "missing case" warning — FollowMode has exactly 3 variants).
    `flutter test test/features/map/map_widget_follow_mode_test.dart` — green (all 3 mappings verified).
    `flutter test` full suite — green.
    grep for `MyLocationTrackingMode.trackingCompass` in `lib/features/map/` returns exactly 1 hit.
  </verify>
  <done>
    Mapping switch is exhaustive over FollowMode; trackingCompass is reachable; widget test verifies all three branches.
  </done>
</task>

## Verification

- `flutter analyze` clean at repo root.
- `flutter test` full suite green (behavior-sensitive UI change: camera follow mode, so full suite runs inside the tight loop per project CLAUDE.md).
- grep for `ref.listen<TrackingState>` in `lib/features/map/` → 1 hit (TrackingCameraSync).
- grep for `MyLocationTrackingMode.trackingCompass` in `lib/features/map/` → 1 hit (map_widget.dart mapping).
- Manual on-device verification is DEFERRED to Wave 3 (03-1-05): on trip start, the map should visibly lock to heading-up; on stop, it should release; a mid-trip pan should stay panned.

## SC alignment

- **SC1:** NOT this plan (03-1-01 owns).
- **SC2:** NOT this plan (03-1-02 owns).
- **SC3 (Auto trip):** NOT this plan directly — but the camera-follow will kick in on auto-trip start too once TrackingCameraSync is wired.
- **SC4:** NOT this plan (03-1-02 owns).
- **SC5 (Map camera follows during recording; releases on stop or user-pan):** DIRECTLY SATISFIED by this plan in its entirety. Task 1 wires the state → camera sync; Task 2 fixes the enum mapping so trackingCompass actually reaches the map.
- **SC6:** BLOCKING contributor. Wave 3 drive re-verifies visually.

## Deviation Handling

- If the exhaustive `switch (cameraState.followMode)` fires an analyzer info-level warning about missing case in a sealed enum, that's expected only if `FollowMode` is not a sealed enum in the current codebase — check `follow_mode.dart` and use `.name` / default-case fallback if it's a plain `enum`. Plain Dart `enum`s work with `switch` expressions in Dart 3+ (`enum FollowMode { none, location, locationAndHeading }` gives exhaustive switches automatically).
- If `TrackingCameraSync` inside a Stack causes a "widget doesn't take space" warning, ignore it — `SizedBox.shrink()` is the canonical pattern for headless listener widgets.
- If a widget test breaks because `ref.listen` requires the widget to be pumped-and-rebuilt-with-state-change, use `tester.pumpAndSettle()` between the state override change and the assertion. `ref.listen` fires synchronously on state change during a build, so this shouldn't be needed, but if it is — pumpAndSettle is the fix.
- If the tracking sync fires spuriously on hot reload (dev-time only, not production), verify the widget is mounted exactly once in MapScreen. `ref.listen` inside `build()` is Riverpod-idempotent — the listener registration dedups across rebuilds of the same widget instance.
- Iterate up to 3 times per task.
