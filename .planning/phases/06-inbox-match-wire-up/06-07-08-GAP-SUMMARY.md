# 06-07 / 06-08 GAP SUMMARY — On-device checkpoint fixes

Gap-closure work triggered by the FAILED 06-05 human-verify checkpoint (2026-07-09). Two gap plans, tracked inline (no separate PLAN.md — driven by live on-device feedback):

- **06-07** — crash/freeze fix, motion-vector heading, UI polish (drop card thumbnail, real matching %)
- **06-08** — remove automatic background recording (manual-only)

## 06-07: Crash + freeze (P0)

On-device the Trips tab froze then crashed. **Measured** (not guessed) via `adb dumpsys meminfo` + `logcat -b events` + on-device DB pull:
- Baseline ~950 MB–1 GB PSS on the Map tab alone; **529 MB is the resident MapLibre GL surface** (kept alive behind tabs by `indexedStack`).
- At crash time Android's LMKD was mass-killing background apps → device-wide OOM.
- The two "matching" trips (#7/#8) are ~6,000 points / ~96 km each; their bbox holds **29,497 OSM ways / 13.7 MB** — loaded, copied 2× across the isolate, R-Tree-indexed, on top of the 529 MB map.

**Fixes:**
1. `1d64b3c` — removed the dead offstage `MapLibreMap` from TripsScreen (a 2nd GL context feeding a snapshot path that was never wired; only `renderFallback` is used).
2. `919f68b` — moved the 12 MB admin-polygon parse off the UI isolate via `compute()`.
3. `9852e21` — **single-flight guard** on `AdminRegionLookup.ensureLoaded()` — the `compute()` change introduced an async race where concurrent card lookups each spawned their own 12 MB parse; memoized the in-flight future.
4. `daf1fc1` — **corridor filter** (`way_corridor_filter.dart`): keep only ways within ~250 m of the trip polyline before the matcher isolate. ~20× reduction, no matchable-road loss (matcher candidate radius is 25 m). This is the primary OOM fix for long trips.
5. `f0c23b6` — updated `router_shell_test.dart` for the real TripsScreen (placeholder text gone) + empty-stream overrides.

**PROVEN on-device (2026-07-09):** forced the exact crash workload (trip 8 reset to `pending`, 96 km / 6,295 pts) → matcher ran to completion, trip flipped `pending`→`matched`, wrote **814 driven_way_intervals**, app stayed alive at stable ~906 MB (previously crashed at 30–45 s).

## 06-07: Motion-vector heading

The map stopped pivoting to driving direction. `MyLocationTrackingMode.trackingGps` (set in 04-19) only rotates from MapLibre's internal location engine, which never sees FGB fixes; `FixInput` had no heading field.
- `f304c48` — added `headingDegrees` to `FixInput`; `TrackingService` computes a motion-vector bearing from consecutive fixes (prefers OS course when valid; >5 m jitter guard); `bearingDegrees()` added to `haversine.dart`; heading emitted on `TrackingRecording`.
- `62b7f9e` — `TrackingCameraSync` animates the camera bearing from the recording heading; north-up when not recording.

## 06-07: UI polish
- `529ca08` — **dropped the map thumbnail from inbox trip cards** (user request; also removes a memory consumer).
- `0b7d94b` / `5ff2be7` / `8a48f8b` — **real matching % on History rows** (user request). Progress streamed from the Viterbi decoder → `MatchJobProgress` across the isolate → `matchProgressProvider` → `history_row` determinate indicator ("Matching… NN%"); indeterminate fallback when queued/fetching.

## 06-08: Manual-only recording

User: "get totally rid of the automatic background recording." Notifications fired while walking; a phantom walk auto-trip appeared in the inbox.
- `06895eb` — removed the auto-trip trigger (`_onMotionChange` idle branch + `_openAutoTrip` deleted).
- `ca7e5fd` — FGB lifecycle scoped to manual sessions: `stopActive()` calls `_facade.stop()`; config `stopOnTerminate: true`, `startOnBoot: false`, `enableHeadless: false` — no idle foreground-service notification. Manual crash-recovery hydration retained.

**Requirement impact:** this SUPERSEDES drive-verified Phase-3 requirements **TRK-01 / TRK-02 / TRK-03** (auto-start / auto-capture / auto-terminate). Deliberate scope change (2026-07-09) — see REQUIREMENTS.md.

## Verification status
- `flutter analyze` clean; full suite **524 tests green**.
- Crash fix PROVEN on-device. Heading + manual-only behavior + real-% indicator: DEFERRED to user re-drive (manual test list at phase close-out).
- **Known non-issue:** a `flutter build apk --debug` WITHOUT `--dart-define=MAPTILER_KEY` renders a blank map (no tile key) — not a regression; launch with `--dart-define-from-file=env/dev.json`.
