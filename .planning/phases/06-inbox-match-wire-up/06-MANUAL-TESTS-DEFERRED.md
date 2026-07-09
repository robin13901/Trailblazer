# Phase 6 — Deferred Manual Tests (on-device)

All Phase 6 code is complete, analyzer-clean, and 531 unit/widget tests pass. The
items below require a real device + a drive, so they are **deferred for the user
to run at a later stage** (per `defer-in-car-verification`). Phase 6 is closed
code-complete; these do not block Phase 7 planning/execution.

**Build/run command (always — never `--release`, and the MapTiler key is required or the map is blank):**
```bash
flutter run -d <device> --dart-define-from-file=env/dev.json
```

## Status legend
- ☐ = to verify on device
- ✅(proven) = already confirmed on-device this session

## Checklist

### Crash / stability
- ✅(proven) **Trips tab stays alive with trips actively matching.** Forced on-device 2026-07-09: the 96 km / 6,295-point commute trip matched to 814 driven-way intervals with the app alive at stable ~906 MB (previously OOM-crashed at 30–45 s). Corridor filter + single-flight admin parse fix confirmed.
- ☐ Open the Trips tab with 2+ pending/matching trips present; confirm no freeze and no crash over several minutes of use.

### Inbox + History UI (06-05)
- ☐ Inbox cards show place names, date · duration · distance, dormant vehicle chip. (No map thumbnail — removed by request.)
- ☐ **Keep**: tap Keep → card disappears silently; trip moves to History.
- ☐ **Discard**: tap Discard → confirmation modal → confirm → trip vanishes and is NOT in History (hard-deleted).
- ☐ History tab lists confirmed trips; a still-matching trip shows the progress indicator.
- ☐ Tap a row → TripDetailScreen: raw polyline (muted) + matched intervals (accent), stat strip (duration/distance/matched %), delete works.
- ☐ Style-swap sanity: toggle system dark mode on the detail screen → overlays re-appear (Pitfall Q1).
- ☐ Navigate `/trips/999999` (nonexistent) → graceful, no crash.

### Real matching % (06-07)
- ☐ During a live match, the History row shows a determinate "Matching… NN%" that advances, then resolves to matched.

### Heading (06-07)
- ☐ While recording a manual trip and driving, the map rotates to the driving direction (motion-vector bearing).
- ☐ When not recording, the map is north-up / free-pan (does not force-rotate).

### Manual-only recording (06-08) — supersedes TRK-01/02/03
- ☐ Walking around with the app backgrounded produces **no** auto-trip and **no** notification.
- ☐ A notification appears **only** while a manual recording is active (FAB started), including screen-off.
- ☐ Stopping the manual trip (FAB) ends the foreground service + notification.

### Golden corpus tooling (06-06)
- ☐ In a debug build, TripDetailScreen shows the "Export as golden fixture" FAB.
- ☐ Tapping it writes `gps_trace.json` + `ways.json.gz` + `expected_ways.json` under `<AppDocs>/golden_export/<slug>/`.
- ☐ (Corpus growth) Export ≥3 seed fixtures from real drives; pull + commit per `test/fixtures/golden_trips/README.md`. Target ≥20 remains the Phase-6 inheritance goal (can land during any later drive).

## Notes
- FGB works only in `--debug`/`--profile` (no paid license) — see `fgb-license-and-release-builds`.
- If you report any issue here, it routes to a new gap-closure plan under Phase 6; otherwise reply "approved" and Phase 6 is fully signed off.
