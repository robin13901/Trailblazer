# Phase 3: Tracking MVP - Context

**Gathered:** 2026-07-05
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 3 delivers **trip recording** — manual (FAB) and automatic (background, via `flutter_background_geolocation`) — that produces `pending` trip rows in the App DB with GPS polylines, motion-activity per fix, speeds, distance, and duration. This is the *source* end of the pipeline; the inbox UI, matching, and coverage rendering are downstream (P6 / P5 / P7).

Scope anchor:
- FAB start/stop → manual trip in App DB
- Background auto-detect (`flutter_background_geolocation`) → auto-trip in App DB
- Live-tracking overlay visible on the map during any active trip
- iOS whenInUse → Always → Motion permission ladder + Android FGS + battery-optimization plumbing
- 60-minute driving battery baseline artifact committed to repo

Explicitly **out of scope** (belongs to other phases):
- Trip inbox UI, confirm/reject, bulk actions → Phase 6
- Map-matching HMM → Phase 5
- Coverage cache invalidation → Phase 6
- Vehicle assignment / Bluetooth fingerprints → Phase 9 (Phase 3 uses the P1 placeholder default vehicle)
- Rendering driven roads → Phase 7

</domain>

<decisions>
## Implementation Decisions

### Trip lifecycle
- **Auto-trip START:** trust `flutter_background_geolocation` defaults (motion + speed + accuracy fusion). No custom motion-state machine on top of FGB in Phase 3.
- **Auto-trip END:** 2-minute non-automotive dwell AND user has not resumed driving within the **resume window: 15 min + 500 m radius from the stop point**.
  - Resume within window & radius → extend the current trip (gas station / drive-thru = one trip)
  - Resume outside window OR outside radius → new trip
- **Manual + auto interaction:** FAB is the **universal stop control**. If an auto-trip is running and the user taps the FAB, it stops the currently-active trip (same effect as natural end). No manual/auto split; no parallel trips; the DB never has two simultaneous active rows.
- **App opened mid-auto-trip:** reconstruct the live-tracking overlay from the in-flight trip state (duration, distance so far, current speed). Same visual as if the app had been open the whole time.

### Live-tracking overlay UX
- **Content:** `Recording · 12:34 · 8.2 km · 42 km/h` — duration, distance, current speed. No avg speed, no road-name (deferred until P4/P5 make it cheap).
- **Position:** bottom of the map, above the bottom-nav pill. Glass panel styled to match existing chrome (P2 GlassPill idiom).
- **FAB behavior:** morphs to a **red circular Stop button** during any active trip (same 64 dp size, same corner as P2). Single "trip control" widget — location never moves.
- **Interactivity:** **read-only**. No tap-to-expand, no long-press to pause, no tap-to-stop from the panel itself. Stopping is exclusively via the red Stop FAB. Simpler = safer for a driving context.

### Permission ladder & persistent notification
- **Onboarding walk-through: upfront in onboarding.** All three permission steps happen back-to-back at first launch with rationale screens between them:
  1. whenInUse location
  2. Always location (with rationale: "so we can log trips even when the app is closed")
  3. Android battery-optimization exemption ("ignore battery optimizations")
- On iOS the equivalent chain: whenInUse → Always → Motion & Fitness (asked in same flow).
- **whenInUse-only fallback:** **manual trips only.** Auto-tracking is fully disabled with a greyed-out settings toggle labelled "Requires Always location". No foreground-only auto mode.
- **Denial handling:** **never re-prompt via the OS dialog.** After a single denial, show a persistent yellow banner on the map: `Enable Always for auto-trips → Settings`. Tapping the banner deep-links to the OS Settings page for the app.
- **Persistent notification (Android FGS + iOS blue location bar):** **live stats, updates every ~30 s.**
  - Text: `Recording · 12:34 · 8.2 km · 42 km/h`
  - Icon: app icon
  - Tap opens the app straight to the map with the live-tracking overlay in view
  - Not dismissible while trip is active (Android FGS requirement)
  - No inline Stop action button in v1 (defer — nice-to-have, not essential)

### GPS quality & discard rules
- **Fix frequency:** **fixed 1 Hz** during an active trip. Simple, predictable battery cost, matches typical HMM matcher input expectations (P5).
- **Accuracy filter:** **strict — drop any fix with horizontalAccuracy > 25 m.** Rationale: cleaner input for the P5 matcher; tunnels / urban canyons produce a *legitimate* gap that the split-trip rule handles below.
- **No-signal gap handling: split trip after long gap.**
  - If GPS drops out for **> 5 min AND** the first recovered fix is **> 500 m from the last known fix** → close the current trip and open a new one at the recovered fix.
  - Otherwise → record a gap in the polyline (last-fix timestamp + first-recovered-fix timestamp), never interpolate.
- **Trip-keeper threshold — discard when ALL of:**
  - duration < 60 s, OR
  - total distance < 100 m, OR
  - bounding-box diagonal < 50 m (parking-lot shuffle)
  - Trips below any of these thresholds never reach `pending`; they're dropped silently. Raw GPS is not retained for dropped micro-trips.

### Claude's Discretion
- Exact schema/repository layout for `trips` and `trip_points` writes (Drift, following P1 patterns).
- Motion-activity storage: sampled per-fix vs debounced — Claude to research FGB's emit cadence and pick.
- Onboarding rationale screen **copy** — Claude drafts, user reviews in `/gsd:execute-phase`.
- Yellow denial banner exact wording + design (must respect P2 Liquid Glass chrome idiom).
- Deep-link URI for "→ Settings" on both platforms.
- FAB red-Stop styling (Material red 700 vs custom Liquid Glass red).
- Battery-baseline artifact format: Claude picks between Markdown table, JSON file, or CSV — must be diffable, ideally with a committed reference measurement + a re-run script under `tool/`.
- Reference device for the battery baseline: Samsung Galaxy S24 (Android 14) — the same device used for the P2 close-out smoke test.
- Driving profile for baseline: 60 minutes mixed (urban + Landstraße + Autobahn), screen off, notification visible, real driving (not emulator).
- Whether the "Never re-prompt via OS" rule should have an escape hatch (e.g. a Settings screen button that triggers `openAppSettings()` — likely yes, but Claude decides UX).
- Foreground-service notification channel ID and importance (Android).

</decisions>

<specifics>
## Specific Ideas

- The FAB **morphing to red Stop** is the anchor pattern for "there is an active trip." One widget, one location, one meaning — no separate Stop button elsewhere in the UI.
- Live-tracking overlay lives in the **same visual language as the P2 focus-area pill** — glass, rounded, three-value layout — but sits at the bottom above the nav pill so both are visible simultaneously.
- The **15 min + 500 m** resume window intentionally treats a gas-station stop or drive-thru as *one trip* — this matches how the user thinks about "the drive to Grebenhain" even if there was a fuel stop in the middle.
- Motion-activity per fix is a P3 responsibility even though the matcher (P5) is the primary consumer — the raw signal must be captured now so re-matching after schema tweaks works without re-driving.
- Persistent notification with **live stats updated every ~30 s** is intentional — the user should be able to glance at their lock screen and see "yep, it's still recording, and my drive is going well." Static "Trailblazer is recording" is too invisible.

</specifics>

<deferred>
## Deferred Ideas

- **Inline "Stop trip" action button in the notification** — nice UX, but adds broadcast-receiver plumbing and lock-screen tap surface risk. Reconsider after Phase 6 (inbox) is live.
- **Tap-to-pause overlay (long-press to add gap marker)** — useful for private areas (driveways, sensitive addresses). Track for a future privacy-focused phase or opt-in Settings toggle.
- **Foreground-only auto mode (whenInUse + auto-detect while app open)** — rejected in favor of "manual only if Always denied" for simpler mental model. Revisit if user testing shows Always denial rate is high.
- **Current-road name / speed limit hint in the overlay** — requires P4 (OSM Pipeline) + P5 (matcher) to be cheap enough for real-time lookup. Add to overlay in Phase 7 or later once feasibility is clear.
- **Elevation storage / barometric altimeter fusion** — not in v1 requirements (no VEH / TRK bullet); add to backlog if user asks post-v1.
- **User-configurable accuracy filter / fix rate** — the strict 25 m + 1 Hz decision is Trailblazer's opinion. Expose as an advanced Settings toggle in P10 only if diagnostics HUD (SET-05) reveals real-world need.
- **Motion-activity confidence threshold override** — currently trusting FGB defaults; if golden corpus (P5) shows classification errors driving matcher failures, insert a decimal phase to tune.

</deferred>

---

*Phase: 03-tracking-mvp*
*Context gathered: 2026-07-05*
