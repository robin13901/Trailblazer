---
phase: 10-coverage-recompute-region-totals
plan: 02
subsystem: map-presentation
tags: [maplibre, riverpod, live-puck, live-trail, tracking, flutter]

# Dependency graph
requires:
  - phase: 10-coverage-recompute-region-totals/10-01
    provides: live trail bridge and applier pattern (LiveTrailBridge/LiveTrailApplier)
  - phase: 06-live-nav
    provides: liveFixProvider, TrackingState, TrackingCameraSync, 06-05 map-crash invariants
provides:
  - LivePuckApplier: abstract seam + MapLibre circle-layer impl for single-point live puck
  - LivePuckBridge: headless widget driving puck from liveFixProvider same-tick as trail
  - Native MapLibre dot suppressed while recording (myLocationEnabled=false in MapWidget)
  - LivePuckBridge mounted in MapScreen alongside LiveTrailBridge
affects:
  - Any future plan touching MapWidget location config or LiveTrailBridge lifecycle
  - On-device visual QA checklist (puck riding line tip — deferred drive confirm)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Same-tick bridge pair: LiveTrailBridge + LivePuckBridge both consume liveFixProvider in one listen, so line and puck update atomically each fix"
    - "Native-dot suppression: trackingStateProvider gates myLocationEnabled in MapWidget; render mode forced to .normal when suppressed to satisfy MapLibreMap assert"
    - "Test timer-safety: trackingStateProvider overridden with _IdleTrackingNotifier in all MapWidget tests to prevent TrackingService.init() from leaving pending timers"

key-files:
  created:
    - lib/features/map/presentation/providers/live_puck_applier.dart
    - lib/features/map/presentation/widgets/live_puck_bridge.dart
    - test/features/map/live_puck_bridge_test.dart
  modified:
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/presentation/map_screen.dart
    - test/features/map/map_widget_test.dart
    - test/features/map/map_widget_follow_mode_test.dart

key-decisions:
  - "Circle layer (not symbol) for the live puck: simpler, no image asset, headings deferred to v2 — heading parameter kept in API for future symbol rotation without caller changes"
  - "myLocationEnabled=false while recording, not a visibility toggle: cleanest way to satisfy MapLibreMap's compass-mode assert while native dot is suppressed"
  - "_IdleTrackingNotifier override in MapWidget tests: real TrackingService.init() is async and spawns background timers; override prevents timersPending assertion failures"

patterns-established:
  - "Parallel bridge pattern: for each MapLibre programmatic layer that needs same-tick updates, pair an Applier (seam) + Bridge (headless widget) following LiveTrailBridge/LivePuckBridge"

# Metrics
duration: 35min
completed: 2026-07-17
---

# Phase 10 Plan 02: Live Puck Sync Summary

**LivePuckBridge draws our own location dot from liveFixProvider same-tick as the trail; native MapLibre dot suppressed while recording via trackingStateProvider gate in MapWidget**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-07-17T12:00:00Z
- **Completed:** 2026-07-17T12:37:07Z
- **Tasks:** 2
- **Files modified:** 7 (4 modified, 3 created)

## Accomplishments

- LivePuckApplier: abstract seam + MapLibreLivePuckApplier; adds circle-layer GeoJSON point source; `addOrUpdate(LatLng, {heading})` + `remove()`; null-controller guards; try/catch source-absent on first call (mirrors LiveTrailApplier pattern)
- LivePuckBridge: headless ConsumerStatefulWidget; `ref.listen(liveFixProvider)` → `applier.addOrUpdate` same tick as trail; `ref.listen(trackingStateProvider)` → `applier.remove` on TrackingIdle; `mapStyleLoadedTickProvider` tick change → `_scheduleReadd` from `_lastPoint` (Pitfall 1 style-reload re-add)
- MapWidget: watches `trackingStateProvider`; `isRecording = trackingState is TrackingRecording`; `locationEnabled = isGranted && !isRecording`; `myLocationRenderMode` gated on `locationEnabled` (not raw `isGranted`) to keep MapLibreMap assert satisfied
- MapScreen: LivePuckBridge mounted as zero-size Positioned outside `isMapTab` guard, right after LiveTrailBridge
- 7 new widget tests for LivePuckBridge all green; existing map_widget and follow_mode tests fixed to override trackingStateProvider

## Task Commits

1. **Task 1: Live-puck applier + bridge from the liveFix feed** - `8cb2512` (feat)
2. **Task 2: Suppress native dot while recording + mount the bridge** - `b10023e` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `lib/features/map/presentation/providers/live_puck_applier.dart` — Abstract LivePuckApplier seam + MapLibreLivePuckApplier production impl; circle layer at top of stack
- `lib/features/map/presentation/widgets/live_puck_bridge.dart` — Headless bridge; liveFixProvider → puck position same-tick as trail; style-reload re-add; stop clears puck
- `test/features/map/live_puck_bridge_test.dart` — 7 widget tests: headless render, first-fix, heading forwarding, multi-fix update, stop removal, style-reload re-add, no-op without known point
- `lib/features/map/presentation/widgets/map_widget.dart` — Added trackingStateProvider watch; locationEnabled = isGranted && !isRecording; render mode gated on locationEnabled
- `lib/features/map/presentation/map_screen.dart` — LivePuckBridge Positioned mounted after LiveTrailBridge
- `test/features/map/map_widget_test.dart` — Added _IdleTrackingNotifier + trackingStateProvider override to pumpMapWidget
- `test/features/map/map_widget_follow_mode_test.dart` — Same _IdleTrackingNotifier override added to _pumpAndReadMap

## Decisions Made

- **Circle layer for the live puck (not symbol):** No image asset needed; heading parameter retained in API for future directional arrow without caller changes. A symbol layer with bearing rotation can replace the circle in a later plan.
- **myLocationEnabled=false while recording (not opacity/visibility trick):** The cleanest suppression; simultaneously satisfies MapLibreMap's compass assert (`compass` mode requires `myLocationEnabled=true`); we force `normal` render mode when suppressing.
- **_IdleTrackingNotifier in MapWidget tests:** The real TrackingNotifier calls `_svc.init()` (fire-and-forget async), which spawns timers. Without the override, `testWidgets` throws `timersPending` on teardown. Override returns `TrackingIdle` synchronously — no timers, no DB dependency.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] _IdleTrackingNotifier override added to existing MapWidget tests**

- **Found during:** Task 2 — first test run after adding `ref.watch(trackingStateProvider)` to MapWidget
- **Issue:** All 12 existing map_widget/map_widget_follow_mode tests failed with `timersPending` assertion because MapWidget now reads `trackingStateProvider`, which instantiates the real `TrackingNotifier` → calls `TrackingService.init()` → leaves a pending async timer
- **Fix:** Added `_IdleTrackingNotifier` (synchronous `TrackingIdle`, no-op start/stop) + `trackingStateProvider.overrideWith(_IdleTrackingNotifier.new)` to `pumpMapWidget` and `_pumpAndReadMap`
- **Files modified:** test/features/map/map_widget_test.dart, test/features/map/map_widget_follow_mode_test.dart
- **Verification:** All 12 previously-failing tests pass; full suite 893 green
- **Committed in:** b10023e (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 2 — missing critical test infrastructure)
**Impact on plan:** Fix was mandatory for test correctness. No scope creep.

## Issues Encountered

- **Parallel-wave staging (known issue):** Task 1's three new files (`live_puck_applier.dart`, `live_puck_bridge.dart`, `live_puck_bridge_test.dart`) were swept into d9d481b (Phase 10-03 Stage-H commit) by the parallel-wave metadata hygiene issue noted in MEMORY.md. Confirmed the committed versions matched the intended content; committed the 1-line comment-order fix to the test as the Task 1 record commit.

## Deferred Device Confirm

**SC6 on-device visual confirm: puck riding the line tip (no lag-then-jump) — DEFERRED**

Per the project's defer-in-car-verification convention (see MEMORY.md: "Close Trailblazer phases code-complete when the last checkpoint is a real drive; batch drives across phases later"), the puck sync visual is a device-only check and has been deferred to the next drive session along with other accumulated on-device confirms from Phase 10.

What to verify on-device:
1. Start a manual trip recording.
2. Drive / walk a short distance.
3. Confirm the blue circle puck tracks the leading tip of the live coverage line — no visible lag-then-jump.
4. Confirm the native MapLibre blue dot is NOT visible during recording (suppressed).
5. Stop the trip; confirm puck disappears and native dot reappears when location is granted.

## Next Phase Readiness

- F5 (live puck lag) is code-complete; on-device confirm batched to next drive
- Phase 10-03 (Stage H per-region totals) was already committed; 10-04 and beyond can proceed
- No blockers

---
*Phase: 10-coverage-recompute-region-totals*
*Completed: 2026-07-17*
