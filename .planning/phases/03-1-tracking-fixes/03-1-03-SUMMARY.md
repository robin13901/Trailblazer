---
phase: 03-1-tracking-fixes
plan: 03
subsystem: map-camera-tracking
tags: [camera-follow, tracking, riverpod, ref-listen, maplibre, follow-mode, transitions, h2]

# Dependency graph
requires:
  - phase: 02-map-glass-shell
    provides: FollowMode enum (STATE 02-03 reserved locationAndHeading slot), CameraState + CameraStateNotifier, cameraStateProvider, MapWidget mapping FollowMode -> MyLocationTrackingMode
  - phase: 03-tracking-mvp
    provides: TrackingState sealed hierarchy (TrackingIdle / TrackingRecording), trackingStateProvider (NotifierProvider<TrackingNotifier, TrackingState>)
  - phase: 03-1-tracking-fixes
    plan: 01
    provides: TrackingDiagnostics + counters — enables the in-car HUD observation channel that Plan 03-1-05 will use to verify the follow-mode fix
provides:
  - TrackingCameraSync headless ConsumerWidget (lib/features/map/presentation/widgets/tracking_camera_sync.dart) — listens to trackingStateProvider via ref.listen<TrackingState> inside build(), sets cameraStateProvider.followMode to locationAndHeading on Idle->Recording, to none on Recording->Idle, and NO-OP on Recording->Recording re-emits (pan-dismiss precedence preserved)
  - Exhaustive FollowMode -> MyLocationTrackingMode switch in MapWidget — locationAndHeading now reaches MyLocationTrackingMode.trackingCompass (closes second bug from 03-1-RESEARCH §3.3)
  - test/features/map/tracking_camera_sync_test.dart — 4 tests: Idle->Recording transition, Recording->Idle transition, Recording->Recording NO-OP after user pan, headless-render smoke
  - test/features/map/map_widget_follow_mode_test.dart — 3 tests: FollowMode.none/location/locationAndHeading each map to the correct MyLocationTrackingMode
affects:
  - 03-1-05 (in-car verification + close-out) — H2 fix ready for on-device drive verification (SC5: map camera follows during recording; releases on stop or user-pan)
  - Phase 5 (HMM matcher) — reliable heading-locked recording gives cleaner GPS traces for map-matching regression testing

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "ref.listen<T>(provider, (previous, next) { ... }) inside ConsumerWidget.build() — Riverpod-dedup'd listener registration, safe on hot reload (unlike initState/dispose registration), avoids the STATE 02-03 'ref in dispose()' hazard"
    - "Headless listener widget (SizedBox.shrink) wrapped in Positioned(top:0, left:0, width:0, height:0, child:...) — mounts in a Stack without sizing the Stack and without intercepting hit-tests on chrome layered on top"
    - "Exhaustive switch expression over a Dart 3 enum for enum-to-enum mapping — analyzer confirms exhaustiveness; single line per branch; drift-safe when new variants are added"
    - "Transition-only listener semantics: fire on `previous is X && next is Y` guards, NO-OP on same-state re-emits — preserves user-pan precedence when the source stream emits on every fix (03-1-RESEARCH §5.1)"

key-files:
  created:
    - lib/features/map/presentation/widgets/tracking_camera_sync.dart
    - test/features/map/tracking_camera_sync_test.dart
    - test/features/map/map_widget_follow_mode_test.dart
  modified:
    - lib/features/map/presentation/map_screen.dart (mount TrackingCameraSync as a zero-size Positioned Stack child)
    - lib/features/map/presentation/widgets/map_widget.dart (isFollowing bool -> exhaustive switch trackingMode; myLocationTrackingMode reads trackingMode)

key-decisions:
  - "TrackingCameraSync fires on state TRANSITIONS only (`previous is TrackingIdle && next is TrackingRecording` and inverse). TrackingRecording -> TrackingRecording (per-fix re-emit from 03-1-RESEARCH §5.1) is a NO-OP. This preserves pan-dismiss precedence: if the user pans mid-trip and MapWidget's onCameraTrackingDismissed sets FollowMode.none, the next fix arriving does NOT re-arm follow mode."
  - "ref.listen inside build() (NOT initState) per 03-1-RESEARCH §9 Risk 3 — hot reload cannot double-register; Riverpod dedups the listener per widget instance. Also sidesteps STATE 02-03 line 92 hazard (ref unsafe in dispose after unmount)."
  - "The MapWidget mapping switch is exhaustive over FollowMode (3 variants: none, location, locationAndHeading). Analyzer enforces exhaustiveness at compile time — adding a fourth variant is a hard error, no silent fallthrough."
  - "TrackingCameraSync is a ConsumerWidget (not ConsumerStatefulWidget) — no state, no timers, no side effects outside the ref.listen callback. Rebuilds are free."
  - "Widget rendered as SizedBox.shrink() wrapped in `Positioned(top:0, left:0, width:0, height:0, ...)`. A bare `Positioned(child:...)` defaults to fill (intercepts hit-tests on chrome above); a bare TrackingCameraSync() as a non-Positioned Stack child sizes the Stack to its child (SizedBox.shrink=0x0), collapsing everything. Zero-size Positioned rect gives both: no chrome hit-test interception, no Stack sizing side effect."
  - "Mount site is MapScreen root Stack (alongside MapWidget), NOT inside the map-tab-only chrome branch. Rationale: TrackingCameraSync must stay listening whether the user is on the Map tab or has switched to Trips/Regions mid-recording. The map is still in the tree (indexedStack semantics preserve it per STATE 02-06), so the sync stays coherent regardless of tab."

patterns-established:
  - "State-transition listener pattern: `ref.listen<Sealed>(provider, (prev, next) { if (prev is A && next is B) doThing(); })` guarded by type checks — clean, exhaustive over a sealed hierarchy, no manual bookkeeping"
  - "Zero-size Positioned wrap for headless Stack listener widgets — reusable for any future 'observe + side-effect' widget mounted alongside a Stack of visible chrome"

# Metrics
duration: 19min
completed: 2026-07-06
---

# Phase 3.1 Plan 03: Map Camera-Follow During Recording Summary

**Closes H2 — map camera now heading-locks (MyLocationTrackingMode.trackingCompass) during a recording session and releases on stop, while a mid-trip user pan still wins.**

## Performance

- Duration: 19 min (fastest in Phase 3.1 so far: 03-1-01 = 23 min, 03-1-02 = ~40 min, 03-1-04 = ~35 min; on par with Phase 1's docs-only plans)
- Loop cost: 4 Ralph-Loop analyze cycles (2 for Task 1 comment_references + setter/getter lint, 1 for Task 2 unnecessary import, 1 for the layout regression fix that surfaced router_shell_test failures)
- Test count: 178 → 178 (+7 new tests in this plan, offset by no removals; prior baseline was 175 before Plan 03-1-04's 3 regression tests landed — subtotal for Plan 03-1-03 is 4 sync + 3 mapping = 7 new)
- Commits: 3 task commits — 53473e1 (TrackingCameraSync + MapScreen mount), afc2b20 (FollowMode->MyLocationTrackingMode exhaustive switch + test), 33b46a2 (zero-size Positioned wrap fix)

## What shipped

### The H2 close-out — two independent bugs fixed together

**Bug 1 — no tracking→camera wiring** (03-1-RESEARCH §3.1 / §3.2)

Prior to this plan, `setFollowMode(...)` had exactly three producers in `lib/`:

1. `MapWidget.onCameraTrackingDismissed` — pan dismisses → `FollowMode.none`
2. `RecenterButton` — user tap → `FollowMode.location`
3. Recenter error-recovery paths

None of these watched `trackingStateProvider`. The `FollowMode.locationAndHeading` slot reserved by STATE Plan 02-03 line 94 for Phase 3 was never activated. Trip start / stop transitions had no effect on the camera; the map stayed in whatever `FollowMode` the user last set.

**Fix:** new `TrackingCameraSync` `ConsumerWidget` at `lib/features/map/presentation/widgets/tracking_camera_sync.dart`. Uses `ref.listen<TrackingState>(trackingStateProvider, ...)` inside `build()` to observe state changes. Callback fires on precisely two transitions:

- `TrackingIdle → TrackingRecording` → `setFollowMode(FollowMode.locationAndHeading)`
- `TrackingRecording → TrackingIdle` → `setFollowMode(FollowMode.none)`

Same-state re-emits (`TrackingRecording → TrackingRecording` from per-fix updates that Plan 03-1-04 verified as the canonical `stateStream` cadence, 03-1-RESEARCH §5.1) are a **NO-OP**. This is the pan-dismiss precedence contract: if the user pans mid-trip, the pan handler pushes `FollowMode.none`; the next accepted fix would otherwise re-arm follow mode and stomp the user. By listening only on transitions, we let the pan win.

**Registration site: `ref.listen` inside `build()`, not `initState()`.** Per 03-1-RESEARCH §9 Risk 3, `initState`-registered listeners can double-register on hot reload if the widget rebuilds under a new state key. `ref.listen` inside `build()` is Riverpod-idempotent — the framework dedups the listener across rebuilds of the same widget instance. This also sidesteps STATE 02-03 line 92: no need to touch `ref` in `dispose()`.

**Mount site: `MapScreen` root `Stack`, alongside `MapWidget`, wrapped in a zero-size `Positioned`.** Reasoning captured in key-decisions.

**Bug 2 — the mapping table was wrong** (03-1-RESEARCH §3.3)

`lib/features/map/presentation/widgets/map_widget.dart:174` (pre-fix):

```dart
final isFollowing =
    cameraState.followMode == FollowMode.location ||
    cameraState.followMode == FollowMode.locationAndHeading;
...
myLocationTrackingMode: isFollowing
    ? MyLocationTrackingMode.tracking
    : MyLocationTrackingMode.none,
```

Both `FollowMode.location` AND `FollowMode.locationAndHeading` collapsed to `MyLocationTrackingMode.tracking`. `MyLocationTrackingMode.trackingCompass` was **unreachable**. Even after wiring Bug 1's fix, the map would have heading-tracked without compass rotation — no different from `FollowMode.location`.

**Fix:** replaced with an exhaustive switch expression:

```dart
final trackingMode = switch (cameraState.followMode) {
  FollowMode.none => MyLocationTrackingMode.none,
  FollowMode.location => MyLocationTrackingMode.tracking,
  FollowMode.locationAndHeading => MyLocationTrackingMode.trackingCompass,
};
...
myLocationTrackingMode: trackingMode,
```

Analyzer enforces exhaustiveness. Future variants added to `FollowMode` will be a hard compile error rather than a silent bug.

### The regression I introduced and immediately fixed

**Auto-fixed under Rule 1** (see Deviations section).

Task 1's initial mount used a bare `TrackingCameraSync()` as a non-Positioned Stack child. In a `Stack`, non-Positioned children determine the Stack's own size — `SizedBox.shrink()` collapses the whole stack to 0×0. Router-shell tap tests started failing (map chrome not laid out, so "Trips" text off-screen).

The first attempted fix (`Positioned(child: TrackingCameraSync())`) also failed because a bare `Positioned` with no anchors defaults to filling the parent, intercepting hit-tests on the chrome layered on top.

Final fix: `Positioned(top: 0, left: 0, width: 0, height: 0, child: TrackingCameraSync())`. Zero-size rect at (0,0) — occupies no space, hits no gestures. All 178 tests green.

## Testing

### `test/features/map/tracking_camera_sync_test.dart` (new, 4 tests)

- `TrackingIdle → TrackingRecording sets FollowMode.locationAndHeading` — starting state has `CameraState.initial.followMode == FollowMode.location`; after emitting a `TrackingRecording`, camera state flips to `locationAndHeading`.
- `TrackingRecording → TrackingIdle sets FollowMode.none` — initial recording state manually set to `locationAndHeading`; emitting `TrackingIdle` flips to `none`.
- `TrackingRecording → TrackingRecording re-emit does NOT re-arm follow mode after a user pan` — the pan-dismiss precedence assertion. Start recording (sync arms `locationAndHeading`), simulate user pan (`FollowMode.none`), emit a same-state `TrackingRecording` with updated `distanceMeters` — assert follow mode stays `none`.
- `renders a SizedBox.shrink (no visible UI)` — headless-render smoke, catches any accidental UI additions.

### `test/features/map/map_widget_follow_mode_test.dart` (new, 3 tests)

Uses the STATE 02-02 `FakeMapLibrePlatform` helper to intercept the `MapLibreMap` constructor and read the `myLocationTrackingMode` argument:

- `FollowMode.none → MyLocationTrackingMode.none`
- `FollowMode.location → MyLocationTrackingMode.tracking`
- `FollowMode.locationAndHeading → MyLocationTrackingMode.trackingCompass` (the H2 close-out assertion)

Uses `_FixedCameraStateNotifier` (extends `CameraStateNotifier`) to force each `FollowMode` value directly, bypassing the notifier's setter API.

### Test count evolution

Before this plan (post-03-1-04): 175 tests
This plan: +7 (4 tracking_camera_sync + 3 map_widget_follow_mode)
After this plan: 178 tests green

Router-shell tests (5) that broke transiently during the layout regression: fixed and passing again by 33b46a2. Previously-skipped `TODO(I551358)` tests in the same file remain skipped (STATE line 250 pending).

## Deviations from Plan

### Auto-fixed (Rule 1 — Bugs I introduced during execution)

**1. `TrackingCameraSync` Stack-child sizing regression**

- **Found during:** Task 1 verification (full test suite run)
- **Issue:** The initial mount used a bare `const TrackingCameraSync()` as a non-Positioned Stack child. Flutter's `Stack` sizes itself to the non-Positioned child's intrinsic size (`SizedBox.shrink()` = 0×0), so the chrome layered on top laid out into a collapsed 0×0 rect. Router-shell tests started failing on tap targets (widget "off-screen").
- **Attempted fix 1 (failed):** wrapped in `const Positioned(child: TrackingCameraSync())`. A bare `Positioned` with no anchors defaults to filling the parent — the invisible widget intercepted hit-tests on the chrome.
- **Final fix:** `const Positioned(top: 0, left: 0, width: 0, height: 0, child: TrackingCameraSync())`. Zero-size Positioned rect at (0,0). No sizing side-effect, no hit-test interception. Layout preserved.
- **Files modified:** `lib/features/map/presentation/map_screen.dart`
- **Commit:** `33b46a2`
- **Pattern captured:** Any future headless Stack listener widget should use this exact Positioned wrap.

### Not deviations (deferred verification)

- **In-car drive verification** — the `flutter analyze` + `flutter test` gate has passed, but the SC5 acceptance ("map visibly locks to heading-up on trip start; releases on stop; pan stays panned") is a real-device visual check batched into Plan 03-1-05 alongside 03-1-02's FGB start / battery-opt drive tests. Recorded in STATE Pending Todos.

## Authentication gates

None.

## Verification against plan `<must_haves>`

| # | Must-have | Status |
|---|-----------|--------|
| 1 | Idle→Recording activates `MyLocationTrackingMode.trackingCompass` (heading-lock) | PASS — `map_widget_follow_mode_test.dart` asserts the mapping; `tracking_camera_sync_test.dart` asserts the trigger |
| 2 | Recording→Idle releases follow mode | PASS — same tests |
| 3 | `FollowMode.locationAndHeading → MyLocationTrackingMode.trackingCompass` mapping fix landed | PASS — exhaustive switch in `map_widget.dart:150` |
| 4 | Mid-trip user pan wins over the sync listener | PASS — `tracking_camera_sync_test.dart` "re-emit does NOT re-arm follow mode after a user pan" |
| 5 | Sync registered exactly once (no double-register on hot reload) | PASS — `ref.listen` inside `build()`, Riverpod-idempotent per widget instance |
| 6 | `flutter analyze` + `flutter test` both green | PASS — analyze clean at repo root; 178/178 tests green |

Plan `<verification>` extras:
- `grep ref\.listen<TrackingState> lib/features/map/` → 1 hit (in `tracking_camera_sync.dart`)
- `grep MyLocationTrackingMode\.trackingCompass lib/features/map/` → 1 hit (in `map_widget.dart`)

## Follow-ups

- **03-1-05 (in-car drive):** visual verification of SC5 (heading-lock on start, release on stop, pan-persists) is deferred to the batched drive session with 03-1-02's FGB start / battery-opt fixes.
- **STATE.md `Router shell tap tests` pending (line 250):** untouched — the four `TODO(I551358)` skipped tests remain skipped. This plan restored the 5 currently-active router-shell tests to green (they briefly regressed during the layout iteration).
