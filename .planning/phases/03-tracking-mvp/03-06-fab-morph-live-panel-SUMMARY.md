---
phase: 03-tracking-mvp
plan: "06"
subsystem: ui
tags: [flutter, riverpod, animated-switcher, timer, foreground-service, notification, liquid-glass, tracking]

# Dependency graph
requires:
  - phase: 03-tracking-mvp
    provides: TrackingService, TrackingNotifier, trackingStateProvider, TrackingIdle, TrackingRecording (03-04); GlassPill, GlassCircle, map_screen _BottomChrome chrome layout (02-05, 02-06)
provides:
  - TripFab ConsumerWidget: morphs Start (glass circle) ↔ Stop (solid red circle) via AnimatedSwitcher 200ms
  - TrackingDurationTicker: safe StatefulWidget-owned Timer.periodic(1s) with cancel-on-dispose
  - LiveTrackingPanel: GlassPill overlay above FAB row, visible only during TrackingRecording
  - 30s notification updater: _notificationTicker inside TrackingService, fire-and-forget setNotificationText
  - Widget tests: trip_fab_morph_test.dart (7 cases), live_tracking_panel_test.dart (3 cases); glass_shell_layout_test.dart updated; tracking_service_test.dart extended (case 11); 141 tests total
affects: [03-07-baseline-drive, phase-04-osm-pipeline, phase-08-chrome-polish]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - _StartVariant + _StopVariant private widgets with ValueKey for AnimatedSwitcher identity
    - TrackingDurationTicker builder-pattern StatefulWidget for safe periodic rebuilds
    - notificationInterval optional constructor param on TrackingService for test-time injection
    - LiveTrackingPanel conditional visibility via state is! TrackingRecording → SizedBox.shrink

key-files:
  created:
    - lib/features/trips/presentation/widgets/tracking_duration_ticker.dart
    - lib/features/trips/presentation/widgets/live_tracking_panel.dart
    - test/features/map/trip_fab_morph_test.dart
    - test/features/trips/presentation/live_tracking_panel_test.dart
  modified:
    - lib/features/map/presentation/widgets/trip_fab.dart
    - lib/features/map/presentation/map_screen.dart
    - lib/features/trips/domain/tracking_service.dart
    - test/features/map/glass_shell_layout_test.dart
    - test/features/trips/domain/tracking_service_test.dart

key-decisions:
  - "FAB morph via _StartVariant/_StopVariant private widgets + AnimatedSwitcher(duration: 200ms) + ValueKey('start'/'stop') for correct cross-fade identity"
  - "TrackingDurationTicker is a standalone StatefulWidget (builder pattern) — timer cancel in dispose() prevents leaks on hot reload or state change; never embed Timer in a ConsumerWidget directly"
  - "LiveTrackingPanel placed in _BottomChrome above recenter/FAB row, map tab only (showPanel: isMapTab); collapses via SizedBox.shrink when not TrackingRecording"
  - "_notificationTicker added to TrackingService as Timer.periodic(notificationInterval, default 30s); optional constructor param for test injection; fire-and-forget unawaited setNotificationText; started in _openTrip + init() hydration, stopped in _closeTrip + stopActive() + dispose()"

patterns-established:
  - "ValueKey-based AnimatedSwitcher: each variant carries its key as a constructor const, AnimatedSwitcher uses duration 200ms — avoids same-type flicker"
  - "Service-layer ticker ownership: long-lived timers (dwell, resume, notification) all live inside TrackingService, not in notifiers or widgets — survives Riverpod recreate and widget unmount"

# Metrics
duration: ~30min (execution deferred close-out; widget tests drove complexity)
completed: 2026-07-05
---

# Phase 3 Plan 06: FAB Morph + Live Tracking Panel Summary

**Morphing trip FAB (glass Start / solid-red Stop via AnimatedSwitcher), LiveTrackingPanel GlassPill overlay with 1s TrackingDurationTicker, and 30s Android notification updater wired inside TrackingService — full user-visible recording surface for Phase 3**

## Performance

- **Duration:** ~30 min (widget test authoring was the bulk of implementation time)
- **Started:** 2026-07-05 (Wave 3 execution)
- **Completed:** 2026-07-05
- **Tasks:** 2/3 automated (Task 3 deferred — see Deferred Verification section)
- **Files modified:** 9 (5 created, 4 modified + 1 test updated)

## Accomplishments

- Rewrote `TripFab` as a `ConsumerWidget` that watches `trackingStateProvider` and cross-fades between `_StartVariant` (P2 glass circle, red-dot record icon) and `_StopVariant` (solid red circle, white square stop icon) via `AnimatedSwitcher(duration: 200ms)`. Semantics label flips `'Start trip'` / `'Stop trip'`.
- Introduced `TrackingDurationTicker`, a `StatefulWidget` owning a `Timer.periodic(1s)` that cancels on `dispose()`, exposed via a builder pattern receiving `DateTime now` — eliminates the Pitfall 4 timer-leak in `ConsumerWidget`.
- Built `LiveTrackingPanel` (GlassPill overlay: `Recording · MM:SS · X.X km · N km/h`) that is visible only during `TrackingRecording` and invisible (collapses to `SizedBox.shrink`) otherwise. Slotted above the recenter/FAB row in `_BottomChrome`, shown on map tab only.
- Extended `TrackingService` (Plan 03-04 territory, additive only) with `_notificationTicker`: `Timer.periodic(notificationInterval, ...)` calling `unawaited(facade.setNotificationText(...))`. Started in `startManual()`, `_openAutoTrip()`, and `init()` hydration; stopped in `stopActive()`, `_closeAutoTrip()`, and `dispose()`. Optional `notificationInterval` constructor param (default 30 s) enables test-time injection.
- 141 tests passing; `flutter analyze` clean (no issues).

## Task Commits

1. **Task 1: FAB morph + duration ticker + live panel widgets** — `fd66c8f` (feat)
2. **Task 2: Slot LiveTrackingPanel + 30s notification updater** — `813ba1c` (feat)
3. **Task 3: On-device end-to-end trip lifecycle** — DEFERRED (see below)

## Files Created / Modified

**Created:**
- `lib/features/trips/presentation/widgets/tracking_duration_ticker.dart` — `StatefulWidget` owning `Timer.periodic(1s)`; builder pattern providing `DateTime now`
- `lib/features/trips/presentation/widgets/live_tracking_panel.dart` — `ConsumerWidget`; GlassPill overlay with live stats; invisible when `TrackingIdle`
- `test/features/map/trip_fab_morph_test.dart` — 7 widget test cases: idle/recording state, Semantics labels, tap calls `startManual`/`stopActive`
- `test/features/trips/presentation/live_tracking_panel_test.dart` — 3 cases: idle collapses, recording renders correctly, duration advances with `pump()`

**Modified:**
- `lib/features/map/presentation/widgets/trip_fab.dart` — rewrote as `ConsumerWidget` with `_StartVariant`/`_StopVariant` + `AnimatedSwitcher`
- `lib/features/map/presentation/map_screen.dart` — added `LiveTrackingPanel` slot in `_BottomChrome`; `showPanel: isMapTab` guard
- `lib/features/trips/domain/tracking_service.dart` — added `_notificationTicker` field, `_startNotificationTicker()`, `_stopNotificationTicker()`, `notificationInterval` constructor param
- `test/features/map/glass_shell_layout_test.dart` — added `trackingStateProvider` override + Phase 3 tap assertion
- `test/features/trips/domain/tracking_service_test.dart` — added case 11: 100 ms interval, 350 ms trip → ≥3 notifications; count frozen after `stopActive()`

## Decisions Made

- **FAB morph via `_StartVariant`/`_StopVariant` + `AnimatedSwitcher` + `ValueKey`s:** Private variants carry their `ValueKey` as a constructor const, giving `AnimatedSwitcher` stable identity for correct cross-fade between unlike subtrees. Avoids same-type same-key no-animation glitch.
- **`TrackingDurationTicker` as a standalone `StatefulWidget`:** Never embed `Timer.periodic` directly inside a `ConsumerWidget.build()` body — Riverpod rebuilds the widget on every state change, recreating the timer each time. Extracting to a `StatefulWidget` that persists across rebuilds is the canonical Pitfall-4 mitigation (RESEARCH.md).
- **`LiveTrackingPanel` placement in `_BottomChrome` (map tab only):** Panel sits above the recenter/FAB row and below the bottom-nav pill, mirroring the Phase 2 "Column above FAB" chrome layout spec. `showPanel: isMapTab` guard respects the P2 decision to hide all trip chrome when not on the map tab (STATE.md 02-06).
- **`_notificationTicker` ownership inside `TrackingService`:** The timer must survive Riverpod notifier recreate and widget unmount (Android background recording). `TrackingService` is long-lived and already owns the dwell/resume timers — keeping all three together is the correct lifecycle boundary.

## Deviations from Plan

None - plan executed exactly as written for Tasks 1 and 2.

---

**Total deviations:** 0 auto-fixed
**Impact on plan:** Clean execution; Task 3 (on-device verification) deferred by explicit user decision, not a code deviation.

## Deferred Verification

**Task 3 (on-device end-to-end trip lifecycle) was explicitly deferred by the user** to the end of Phase 3, to be run during the Plan 03-07 60-minute baseline drive. The widget-test coverage (141 tests) is the automated gate that has passed.

### Verification steps still outstanding (to be performed in-car with Plan 03-07):

1. **FAB morph** — `flutter run --debug` on Samsung Galaxy S24; tap FAB; verify `_StartVariant` glass circle → `_StopVariant` red circle + white square icon in ~200 ms.
2. **LiveTrackingPanel appearance** — verify `Recording · 00:00 · 0.0 km · — km/h` appears above the FAB row immediately on tap.
3. **1s panel updates** — watch the MM:SS counter advance every second for at least 10 s.
4. **30s notification update** — wait 30 s; confirm Android foreground-service notification text updates to match the panel.
5. **Distance accumulation** — drive/walk ~200 m; verify distance in panel climbs realistically.
6. **Screen-lock persistence** — lock screen for 60 s; confirm notification stays visible.
7. **Notification-tap foregrounding** — tap notification; verify app foregrounds to map with overlay still showing.
8. **Stop flow and DB row** — tap red Stop FAB; verify panel disappears, FAB morphs back to glass circle, notification clears, and a `pending` trip row is created in the DB (check debug log from `TripsRepository.closeTrip`).
9. **Sub-threshold micro-trip guard** — start a trip, wait < 30 s, tap Stop; verify NO trip row created (keeper threshold).

Optional stretch:
- **Cold-start hydration** — force-stop app mid-drive via Recent Apps, reopen; verify `LiveTrackingPanel` and `TripFab` reconstruct from in-flight trip row (hydration path in `TrackingService.init()`).

## Issues Encountered

None.

## Next Phase Readiness

- Plan 03-07 (60-minute baseline drive) is unblocked — widget-test gate passed, code committed.
- During the 03-07 drive, also execute the 9-step Task 3 verification above (combined in-car session).
- iOS visual (blue bar + panel + FAB morph) is code-complete but not device-tested; deferred to a future macOS+iOS pass.
- All 03-04 public APIs preserved — one new optional `notificationInterval` constructor param, backward-compatible.

---
*Phase: 03-tracking-mvp*
*Completed: 2026-07-05*
