# Phase 6: Inbox + Match Wire-Up - Context

**Gathered:** 2026-07-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Confirmed trips flow end-to-end from raw GPS into driven-way intervals and invalidate the coverage cache; rejected trips vanish cleanly. Delivers: inbox UI for pending trips, confirm/discard flow, matcher enqueue wiring, Trip History screen, and coverage-cache infrastructure with invalidation triggers.

**Inherited from Phase 5:** grow the golden corpus from 1 seed → ≥ 20 fixtures alongside inbox integration (record + fixture-ize real drives).

Vehicles CRUD + Bluetooth fingerprinting are **Phase 9** — see Deferred Ideas for the P6/P9 split.

</domain>

<decisions>
## Implementation Decisions

### Inbox list & preview

- **Layout:** Card list, vertical scroll (one card per pending trip). No day grouping in P6 — pure chronological (newest first is the assumed default; open to alternative).
- **Preview:** Static map thumbnail (rendered raster) per card — polyline drawn on a real map background, not a bare SVG sparkline. Rendering approach (offscreen MapLibre vs pre-baked thumbnail) is planner/researcher discretion.
- **Card fields (all required):** Date + time-of-day, duration, distance, human-readable start/end place names (reverse-geocoded from the bundled admin polygons shipped in Phase 4).
- **BT vehicle-guess badge:** Chip on the card, prominent, default-filled. NOTE: BT capture itself is deferred to P9 (see Vehicle assignment section) — so in P6 the chip renders in a **placeholder/dormant state**. The chip UI ships in P6; wiring to real BT-derived vehicle guesses comes with P9.

### Inbox actions & bulk ops

- **Primary action:** Two buttons on each card — Keep (confirm) and Discard. One-tap commit, no swipe gesture.
- **Confirm-before-discard:** Modal dialog on Discard only ("Delete raw GPS? This cannot be undone."). Keep is silent, no modal, no undo.
- **Bulk operations:** NONE in Phase 6. No multi-select mode, no "Confirm all" / "Discard all". This is an intentional deviation from ROADMAP.md SC2 which mentions bulk ops — the deviation is captured here for downstream planner + verifier alignment. Users decide trip-by-trip.
- **Post-Keep UX:** Global queue indicator — the confirmed card disappears from the inbox immediately, but a persistent "N trips matching in background" indicator appears above the inbox (or on Home) until the matcher queue drains. Trip does not remain in inbox with a "Matching…" pill; it moves to Trip History with an in-flight state (see Trip History section).

### Vehicle assignment (P6 vs P9)

- **Vehicle data model in P6:** Add a **nullable `vehicle_id` column** to trips. NO Vehicle table in P6. All confirmed trips have `vehicle_id = NULL` until P9. Phase 9 will introduce the Vehicles table + backfill/migrate NULLs to the first real vehicle.
- **BT fingerprint capture:** **Deferred entirely to P9.** No fingerprint storage on trips in P6. Trips confirmed during the P6→P9 window will simply have no BT data (acceptable — reconstruction not required).
- **`counts_for_coverage` flag:** **Not needed and not shipped in P6.** All confirmed trips count for coverage — globally in P6, and later per-vehicle in P9. This is a deliberate deviation from ROADMAP.md P6 SC5 (which lists a `counts_for_coverage` toggle as an invalidation trigger) — captured explicitly so downstream agents understand. Reintroduce in P9 if/when needed.
- **Retroactive vehicle change + cache invalidation:** **Not built in P6.** Meaningless with no vehicles to reassign to. Wire this mechanism in P9 alongside the picker. ROADMAP.md SC4 (retroactive change) and part of SC5 (vehicle toggle invalidation) are deferred to P9.
- **Coverage-cache invalidation triggers active in P6** (narrowed set):
  1. New driven_way_intervals written after a match.
  2. Trip deleted from Trip History.
  3. OSM extract updated (future Phase 10 concern — hook may be a stub in P6).
  - REMOVED from P6: `vehicle counts_for_coverage` toggle (whole flag deferred).

### Trip History UX

- **Location:** Sub-tabs inside the existing Trips tab — top-level toggle between "Inbox" (pending) and "History" (confirmed + in-flight). Trips tab default landing = Inbox when pending items exist, History otherwise (planner discretion on the "default landing" rule).
- **History content:** Confirmed trips + in-flight matching trips (with spinner/pill on the row until matcher completes). REJECTED trips are NOT shown in History — rejection = hard delete of raw GPS at Discard time; no soft-tombstone. This is a deviation from ROADMAP.md SC4 ("Trip History shows confirmed + rejected trips") — captured explicitly.
- **Row tap:** Full-screen detail view — map with the trip's raw polyline + driven-way intervals overlaid, stats (duration, distance, matched-way count, matched %), delete button. Not a bottom sheet or inline expansion.
- **Delete UX:** Hard delete + confirmation modal ("This will affect your coverage. Delete?"). Deletion drops the trip row + its driven_way_intervals + raw GPS, and invalidates the coverage cache for affected regions. No undo. No soft-delete. No 30-day purge queue.

### Claude's Discretion

- Static map thumbnail render approach: offscreen MapLibre snapshot vs pre-baked at trip-stop time vs cached SVG-over-tile — planner picks based on perf + battery cost.
- Inbox default sort order (assumed newest first, no user-facing sort control in P6).
- Empty-state copy + illustration (both Inbox empty and History empty).
- Exact global-queue-indicator visual: pill above inbox vs banner on Home vs both — Liquid Glass aesthetic decides.
- Reverse-geocoded place name granularity for start/end labels: Ortsteil vs Gemeinde vs Landkreis — pick the level that reads best; can be zoom-independent since it's on a card.
- Handling of "matcher produced 0 driven intervals" trips (fail-matched): planner + researcher decide whether these need a distinct status pill or just show as "0 matched" and let the user delete.
- App-DB migration version bump for `trips.vehicle_id` column: naming, default value (NULL), migration test coverage.
- Inbox → History transition animation (card fly-out, list refresh, etc.).

</decisions>

<specifics>
## Specific Ideas

- **Confirm/Discard buttons on card:** think Gmail-like decisiveness — two clear buttons, no hidden gestures required for the primary flow.
- **Discard modal wording:** must call out that raw GPS is deleted and the action is permanent (this is why the modal is only on Discard — Keep is recoverable, Discard isn't).
- **Global queue indicator:** users need to know the app is still doing work in the background after they've tapped Keep, even though the card is gone. Design goal: reassuring, not alarming.
- **Trip History full-screen detail with matched-way overlay** is essentially a preview of what Phase 7 will render app-wide — the same rendering path can be reused later.

</specifics>

<deferred>
## Deferred Ideas

- **Vehicles CRUD, Bluetooth fingerprinting, `counts_for_coverage` flag, retroactive vehicle reassignment + cache invalidation** — all Phase 9. In P6, `trips.vehicle_id` stays NULL and no vehicle UI exists.
- **Bulk confirm-all / discard-all** — deviation from ROADMAP.md SC2. Not shipping in P6; can be added later if drive volume makes trip-by-trip painful. Note for future backlog.
- **Rejected-trips visible in History** — deviation from ROADMAP.md SC4. Not shipping; Discard = hard delete. Add to backlog if a user later asks for a rejection audit trail.
- **`counts_for_coverage` invalidation trigger** — deferred with the flag itself to P9.
- **Soft-delete + trash-bin recovery for trips** — not in P6; hard delete only.
- **OSM extract update invalidation trigger** — infrastructure to invalidate `coverage_by_region` on extract swap belongs in P10 (Settings + Backup). P6 may stub the hook.
- **Golden corpus expansion 1 → ≥ 20 fixtures** — inherited from Phase 5. Executed alongside the P6 inbox drives, not a P6 planning gray area but must appear in the P6 plan tasks.

</deferred>

---

*Phase: 06-inbox-match-wire-up*
*Context gathered: 2026-07-09*
