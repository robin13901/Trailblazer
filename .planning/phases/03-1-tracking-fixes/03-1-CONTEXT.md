# Phase 3.1 · Tracking Fixes — CONTEXT

**Created:** 2026-07-06
**Trigger:** Failed in-car drive verification on Samsung Galaxy S24 (Android 14) — `.planning/phases/03-tracking-mvp/03-DRIVE-VERIFICATION-2026-07-06.md`
**Type:** Gap-closure / decimal phase, inserted between Phase 3 and Phase 4
**Blocks:** Phase 5 (matcher's golden corpus depends on real captured trips)

## Why this phase exists

Phase 3 closed 2026-07-05 as "code-complete, in-car drive deferred". The batched drive on 2026-07-06 revealed four discrete failure classes in the real world:

| Failure | Observed | SC impact |
|---------|----------|-----------|
| FGB fixes not arriving in the ingestor | Distance + speed stayed at 0 during entire manual drive | SC1 fail |
| Map camera doesn't follow position during trip | Blue dot only moved when user manually panned the map | SC3 partial |
| Persistent notification never appeared | Nothing in the notification bar, foreground or lock screen | SC4 unverified |
| Auto-trip completely silent | No recording, no notification, no UI hint on app reopen | SC2 fail |

The chrome (FAB morph, glass panel, timer, state machine) all worked. Everything downstream of "fix arrives from FGB" is broken.

## Working hypotheses (from drive report — ordered by likelihood)

**H1 — FGB isn't emitting fixes on-device.**
- Timer works (pure Dart, doesn't need FGB)
- Distance/speed = 0 → `TripFixIngestor.acceptFix()` never called → no fixes arrive
- No notification → FGB either not started, or notification channel not wired
- Auto-trip absent → `onMotionChange` never fires
- Candidates:
  - `_facade.ready()` fails or hangs silently, masked by `_facadeReady` guard
  - `bg.Config` missing `stopOnTerminate=false` / `startOnBoot=false` / notification channel config
  - Android 13+ `POST_NOTIFICATIONS` runtime permission never granted → FGB's foreground service dies silently or launches without notification
  - FGB unlicensed "trial mode" may throttle Android background fixes more than assumed

**H2 — Map blue-dot decoupled from tracking service.**
- Map uses MapLibre's built-in location provider (`myLocationEnabled: true`) — this is INDEPENDENT of FGB
- If MapLibre's location subscription throttles or drops when app is foregrounded but idle, dot won't move
- Panning triggers a re-sample which snaps to current fix — matches observed behavior
- Plan 02-03 STATE decision reserved `FollowMode.locationAndHeading` slot for Phase 3 to wire to `MyLocationTrackingMode.trackingCompass` on trip start — this may not have happened in Plan 03-06

**H3 — Motion-detection filter gating manual-trip fixes.**
- STATE decision Plan 03-04: `_lastActivityType == 'in_vehicle' && DateTime.now().difference(_lastActivityAt!) <= activityFreshness`
- If this fires for MANUAL trips (which it should NOT — the user explicitly asked for a trip), all fixes discarded until fresh `in_vehicle` activity signal arrives
- Interacts with H1 — if activity events never fired, fixes never accept either way

**H4 — `stateStream` not re-emitting on each accepted fix.**
- `TripFixIngestor.totalDistanceMeters` + `pointCount` getters added in Plan 03-04 for live-panel consumption
- If `TrackingService` reads them once at start and doesn't re-emit on every accepted fix, panel shows initial 0-values forever
- Timer can still tick because `TrackingDurationTicker` computes `now - startedAt` locally in the widget (Plan 03-06 pattern)
- Compatible with H1 (no fixes at all) OR could be independent bug (fixes arrive but panel doesn't re-render)

**H5 — Samsung OEM background killers.**
- Samsung One UI aggressive background management on unattended lock screen
- Battery optimization prompt may have been dismissed rather than allowed during Plan 03-05 ladder
- Without ignore-battery-optimizations grant, FGB dies within seconds of screen-off on Samsung
- Verifiable via a permission-inspector view

## Non-negotiables

- **Every fix cycle costs a real drive.** Without on-device introspection, we cannot iterate. Wave 1 MUST be a debug HUD before any hypothesis-fix wave runs.
- **Preserve the abstract facade seam (Plan 03-03).** `BackgroundGeolocationFacade` is the only import site for `flutter_background_geolocation`. Wave 2+ fixes must not leak FGB types into the domain layer.
- **Widget/unit tests are necessary but not sufficient.** Every plan closes with an in-car verification checklist, not a green test suite. Phase 3.1 close-out requires a passing drive report.
- **Manual trips must not gate on activity type.** TRK-01's motion filter is for auto-trips only; manual trips are user-authorized regardless of activity signal.

## What NOT to touch

- Chrome/UI layer — FAB morph, glass panel, timer, state machine all work
- App DB schema — Plan 03-01's v2 migration is fine
- Ingestor logic — 22 unit tests green; the bug is upstream (fixes never arrive) or downstream (state doesn't re-emit)
- Phase 4 files — `tool/osm_pipeline/**`, `assets/tiles/**`, `assets/map_style_*.json` — none of these are in Phase 3.1's lane

## Suggested wave breakdown

**Wave 1 (must ship first, blocking prerequisite):**
- Plan 3.1-01: Debug HUD (dev-only, reachable from Settings)
  - Live view of FGB ready state, last-fix timestamp + coords + accuracy + speed, last activity type + timestamp, ingestor accept/reject counters + last reject reason, persistent-notification state, POST_NOTIFICATIONS grant, battery-optimization grant, Samsung's Adaptive Battery status where readable
  - Read-only; no persisted state
  - Reads state via existing service seams (no new API surfaces required in domain code)

**Wave 2 (parallelizable — three fixes, all independent, run in parallel after HUD lands):**
- Plan 3.1-02: FGB integration audit + fix (H1 + H5)
  - Verify `bg.Config` completeness: `stopOnTerminate=false`, `startOnBoot=false`, notification channel config, `notificationTitle`/`notificationText`/`notificationChannelName`
  - POST_NOTIFICATIONS runtime request added to permission ladder (Android 13+)
  - Diagnostic: log FGB ready-state outcome to logger + HUD; failure = red banner
  - Battery-optimization grant verification: Samsung-friendly explanation copy in the ladder
- Plan 3.1-03: Manual trip motion-filter split (H3) + live-stats stream fix (H4)
  - `TripsRepository` / `TrackingService` distinguish `startManual()` (no activity gate) from auto-trip start (activity gated)
  - `stateStream` re-emits on every `acceptFix` outcome, not just start/stop
  - Widget tests via `FakeBackgroundGeolocationFacade` cover both
- Plan 3.1-04: Map camera-follow during recording (H2)
  - On trip start: `mapControllerProvider.setTrackingMode(MyLocationTrackingMode.trackingCompass)`
  - On trip stop OR user-pan: release to `MyLocationTrackingMode.none`
  - Widget test asserts the mode transitions

**Wave 3 (checkpoint — user runs the drive):**
- Plan 3.1-05: In-car verification + phase close-out
  - Re-drive the 2026-07-06 route (or equivalent — supermarket-and-back with manual + auto)
  - HUD screenshots documenting FGB ready, fixes arriving, notification present
  - Passing drive report at `.planning/phases/03-1-tracking-fixes/03-1-DRIVE-VERIFICATION-<date>.md`
  - Phase 3 03-VERIFICATION.md updated from "code-complete" to "SC1–SC5 verified"
  - Update REQUIREMENTS.md TRK-01..11 + QUA-06 → Complete
  - Close Phase 3.1

## Success criteria (mirror ROADMAP)

1. Debug HUD shipped and shows all listed fields live
2. Manual trip: fix intake within 3 s, distance + speed update every ≤5 s, polyline persists on stop with non-zero distance
3. Auto trip: `pending` within 60 s of `in_vehicle`, auto-terminates after 2 min non-automotive dwell
4. Persistent notification visible during any active trip on both platforms; text updates at 30 s cadence
5. Map camera follows during recording; releases on stop or user-pan
6. In-car drive passes and produces a passing verification report

## Reference documents

- `.planning/phases/03-tracking-mvp/03-DRIVE-VERIFICATION-2026-07-06.md` — the failed drive report + all hypotheses
- `.planning/phases/03-tracking-mvp/03-CONTEXT.md` — Phase 3 context, TRK-01..11 requirement text
- `.planning/phases/03-tracking-mvp/03-RESEARCH.md` — Phase 3 research (motion filter, dwell timer, FGB config)
- `.planning/phases/03-tracking-mvp/03-VERIFICATION.md` — current "code-complete, drive-deferred" status; to be updated at close
- `lib/features/trips/data/fgb_background_geolocation_facade.dart` — FGB config site
- `lib/features/trips/data/background_geolocation_facade.dart` — abstract interface (do NOT leak FGB types past this)
- `lib/features/trips/domain/trip_fix_ingestor.dart` — pure-Dart ingestor with 22 unit tests
- `lib/features/trips/data/tracking_service.dart` — timer + state machine + notification ticker
- `lib/features/map/data/camera_state.dart` — CameraState + FollowMode enum (has `locationAndHeading` slot reserved for this)
