# Phase 3 · Drive Verification Report

**Date:** 2026-07-06
**Vehicle drive:** to supermarket + return
**Device:** Samsung Galaxy S24 (Android 14), same device used for Plan 03-05 permission-ladder verification
**Verdict:** ❌ **FAIL** — SC1 partial, SC2 fail, SC3 partial, SC4 unverified, SC5 not measured

This is the deferred in-car verification called out at Phase 3 close-out (2026-07-05). It failed. Phase 3 must be reopened via a gap-closure phase before Phase 5 can consume real trips.

---

## Observations

### Drive 1 — Manual trip (app in foreground during drive)

- Tapped FAB → button turned red ✓ (SC1 UI)
- `LiveTrackingPanel` appeared ✓ (SC3 chrome)
- **Timer field ticked correctly through the whole drive** ✓ (Dart-side `TrackingDurationTicker` — works)
- **Distance field stayed at `0`** the entire drive ❌
- **Speed field stayed at `0`** the entire drive ❌
- **Map blue-dot did NOT follow position** during the drive:
  - Initial fix visible at drive start
  - Orientation updated "sometimes" early on
  - After ~30 s, NO position updates visible on the map
  - Panning the screen on arrival at the supermarket produced a redraw that snapped the dot to the current real location
- **No persistent notification** appeared in the notification bar during the drive

### Drive 2 — Auto-trip (phone locked, app backgrounded)

- Phone on lock screen at drive start
- **No notification** ever appeared on the lock screen
- Unlocked the phone mid-drive: **still no notification** in the notification bar
- Opened the app mid-drive: UI showed idle state (FAB not red, no LiveTrackingPanel) as if no recording were in progress
- **No auto-trip was recorded**

---

## Failure classes (working hypotheses)

Ranked by likelihood, without inspecting the code yet:

**H1 (highest) — FGB is not actually emitting location fixes.**
- Timer works (pure Dart, independent of FGB) → `TrackingService.startManual()` returns cleanly
- Distance + speed stuck at 0 → `TripFixIngestor.acceptFix()` never called → no fixes reach the ingestor
- No persistent notification → FGB either not started, or started but its config to show a notification isn't wired up
- Auto-trip completely absent → FGB motion-state machine (`onMotionChange`) never fires
- Root cause candidates:
  - `_facade.ready()` throws or hangs silently (masked by `_facadeReady` guard) but `start()` still proceeds against a dead SDK
  - FGB unlicensed "trial mode" behavior on Android may throttle background fixes more than we assumed
  - `bg.Config` missing `stopOnTerminate=false` / `startOnBoot=false` / notification channel config
  - `notification.title/text/priority` not actually surfacing on Android 14 (notification channel permissions?)

**H2 — Map blue-dot decoupled from tracking service.**
- Map uses MapLibre's built-in location provider (`myLocationEnabled: true`) — this is INDEPENDENT of FGB
- If MapLibre's location subscription throttles or drops when the app backgrounds, dot won't move
- On foreground return + pan, MapLibre re-samples location and renders the current fix
- STATE.md decision (Plan 02-03): "`FollowMode.locationAndHeading` slot reserved for Phase 3 heading-lock. Phase 3 wires it to `MyLocationTrackingMode.trackingCompass`"
- Question: did Plan 03-06 actually enable camera-follow during recording? The panel + FAB morph landed, but if `mapControllerProvider` was never told to switch tracking mode to `tracking` on trip start, the camera never follows — which matches the observation.

**H3 — Motion-detection filter blocking manual trip fixes.**
- STATE decision (Plan 03-04): "TRK-01 filter: single-line check at motion=true arrival: `_lastActivityType == 'in_vehicle' && DateTime.now().difference(_lastActivityAt!) <= activityFreshness`"
- If this filter also fires for MANUAL trips (which it shouldn't — manual should ignore activity gating), all fixes get discarded until a fresh `in_vehicle` activity signal arrives.
- User was in a car → eventually should have satisfied this — but if activity events never fired (see H1), fixes never accept.

**H4 — Live state stream not emitting stats updates.**
- `TripFixIngestor.totalDistanceMeters` + `pointCount` are getters added in 03-04 for live-panel consumption
- If `TrackingService` reads them once at start and emits an initial state but doesn't re-emit on every accepted fix, the panel shows the initial 0-values forever
- Timer field could still tick because `TrackingDurationTicker` computes `now - startedAt` locally in the widget (Plan 03-06 pattern)
- This is compatible with H1 (fixes never arrive) OR could be an independent bug

**H5 — Battery / OEM background killers.**
- Samsung One UI aggressive background management on unattended lock screen
- Battery optimization prompt may have been dismissed rather than allowed during Plan 03-05 ladder
- Without ignore-battery-optimizations grant, FGB dies within seconds of screen-off on Samsung

---

## Verification impact

| SC | Status | Note |
|----|--------|------|
| SC1 (manual trip persists) | ❌ FAIL | Distance/speed = 0, no polyline → nothing meaningful persisted |
| SC2 (auto-trip in background) | ❌ FAIL | No auto-trip recorded at all |
| SC3 (live overlay visible) | ⚠️ PARTIAL | Overlay renders, but shows stale zeros |
| SC4 (permission ladder + FGS + notification) | ⚠️ UNVERIFIED | Notification never observed → likely not wired or blocked |
| SC5 (60-min battery baseline) | ⏸ NOT MEASURED | Blocked on SC1/SC2 working first |

**Phase 3 03-VERIFICATION.md needs downgrade:** the "4/5 code-complete + SC5 drive-blocked" was optimistic. Real assessment: 0.5/5 verified.

---

## Recommended recovery

A **Phase 3.1** decimal insertion between Phase 3 close-out and Phase 5 (which depends on real trips). Phase 4 is unaffected — it's a dev-machine deliverable and can complete in parallel.

Suggested Phase 3.1 shape:
1. **Diagnose in-app** — add a debug HUD toggle (STATE has one flagged for Plan 10, borrow it early) showing FGB.ready() outcome, last-fix timestamp, last-activity type + timestamp, ingestor accept/reject counts, notification state.
2. **Fix FGB wiring** — validate `bg.Config` (`stopOnTerminate=false`, `startOnBoot=false`, notification channel), verify `facade.ready()` actually completes on cold start, verify `onLocation` handler subscribed and `TrackingService` receives fixes.
3. **Fix manual-vs-auto filter split** — manual trips should NOT gate on `in_vehicle` activity freshness (user explicitly asked for a trip, activity signal irrelevant).
4. **Fix map camera-follow during recording** — during an active trip, `MyLocationTrackingMode.trackingCompass` should be active on the map so the blue dot pins to camera center.
5. **Fix live stats stream** — verify `TrackingService.stateStream` emits on every accepted fix, not just start/stop.
6. **Fix notification visibility** — Android 13+ requires POST_NOTIFICATIONS permission runtime grant + FGB notification channel importance ≥ default. Verify both, add ATC-style diagnostic to Settings.
7. **Re-drive verification** — same route, real observations, before phase closes.

Timing: Phase 3.1 should slot in AFTER Phase 4 close-out (Phase 4 doesn't consume trips) and BEFORE Phase 5 start (Phase 5 matcher consumes real trips). Adding to memory + STATE queue for Phase 4 close-out to route to.

---

## Positive findings

- FAB morph animation works cleanly on-device ✓
- Glass pill (LiveTrackingPanel) renders and lays out correctly ✓
- Duration timer field is reliable ✓
- App state machine transitions Idle → Recording on tap ✓
- No app crashes, no visible errors during the drive ✓

The chrome is right. The plumbing behind it isn't.
