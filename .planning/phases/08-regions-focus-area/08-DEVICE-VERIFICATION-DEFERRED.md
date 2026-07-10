# Phase 8 Deferred Device Verification

**Status:** Deferred — code-complete, all automated gates green as of 2026-07-11
**Policy:** Per project memory "defer-in-car-verification", on-device confirms are
NEVER execution gates. All automated gates (flutter analyze + unit/widget tests)
have passed. These items are batched into a single checklist to be worked through
on the next real drive session.

---

## What to do

Run `flutter run --dart-define-from-file=env/dev.json` on the device, drive (or
walk/simulate), and tick off each item. Record PASS / FAIL per item. For any
FAIL, file a gap-closure issue referencing this file and the failing item number,
then run `/gsd:plan-phase 8 --gaps` to create a targeted fix plan.

---

## Phase 8 On-Device Visual Confirmations

### 08-03 / 08-04 — Focus Pill Live Feel

- [ ] **1. Live tracking on fast pan** — pan and zoom the map quickly across
  region boundaries; the pill's name and % track smoothly with no flicker and
  never go blank. The "hold-last-value" contract means the previous value stays
  visible while the new region is resolving (no spinner, no blank moment). Sources:
  FOC-01/04/07, CONTEXT.md line 68.

- [ ] **2. Zoom-level correctness** — zoom out past the breakpoints and confirm
  the pill name steps through admin levels:
  - zoom < 9 → a Bundesland name (e.g. "Hessen")
  - zoom 9–10 → Regierungsbezirk or Landkreis
  - zoom 11–14 → Landkreis / Samtgemeinde
  - zoom ≥ 15 → Gemeinde / Ortsteil
  Level transitions happen when crossing the documented zoom breakpoints
  (zoom_level_mapper.dart).

- [ ] **3. Water / no-region fallback** — pan the map over a large lake (e.g.
  Starnberger See) or outside Germany's border; the pill falls back to the
  nearest parent region (down to "Deutschland" at level 2) and is NEVER blank.

- [ ] **4. Pill % accuracy** — the coverage % shown in the pill for a known
  region (e.g. Grebenhain) matches the % shown in the region browser card and
  detail sheet for the same region (all three read from the same coverage_cache
  row — consistent).

### 08-04 / 08-06 — Pill Tap

- [ ] **5. Pill tap → detail sheet opens** — tap the focus pill; the draggable
  Liquid Glass bottom sheet opens showing the region currently under the map
  view (name + level badge + coverage % + km stats). The region in the sheet
  matches what the pill is currently displaying.

### 08-05 — Region Browser

- [ ] **6. Browser card list correctness** — open the Regions tab; confirm a
  single Ortsteil trip produces exactly 5 cards:
  - the Ortsteil
  - its Gemeinde
  - its Landkreis
  - its Bundesland
  - the Land (Deutschland)
  Cards are sorted % descending, each showing: level badge + name + % +
  driven / total km (no bar). No duplicate cards, no extra cards for
  unvisited regions.

- [ ] **7. Fuzzy search** — type a prefix in the search field (e.g. "greb");
  the list filters live and ranks starts-with matches first (Grebenhain before
  Grebenbach etc). Lazy scroll is smooth with no jank at Germany scale.

### 08-05 / 08-06 — Detail Sheet

- [ ] **8. Detail sheet drag + glass** — tap a region card in the browser AND
  separately tap the pill (two separate opens); each time:
  - The DraggableScrollableSheet opens at partial height (40%) with the map
    visible behind.
  - Dragging up expands to full height (85%).
  - The Liquid Glass chrome renders without a 0-dim crash during the drag.
  - Header = region name + level badge (no breadcrumb).
  - Body = coverage % (one decimal) + driven / total km only — no ways list,
    no trips list.

- [ ] **9. Jump to on map** — from the detail sheet, tap "Im Karte anzeigen":
  - The sheet closes.
  - The app switches to the Map tab.
  - The camera animates to fit the region's bounding box (with 40-pt padding
    on all sides).
  - The off-tab controller-await path (ref.listenManual) fires correctly even
    when the map was not the active tab before opening the sheet.

### 08-02 — Coverage Recompute

- [ ] **10. Recompute after confirm** — confirm a pending trip in the inbox;
  then return to the Regions tab; the newly-covered regions now appear / update
  their % correctly (coverage_cache rows were invalidated by CoverageInvalidator
  and re-populated by the compute isolate after the confirm).

---

## Recording Results

After the drive session, replace each `[ ]` with `[x]` (pass) or `[~]` (fail).
Add a note after any fail. Example:

```
- [~] 3. Water / no-region fallback — pill went blank for ~2s over Starnberger See
```

Then run `/gsd:plan-phase 8 --gaps` to generate a targeted gap-closure plan for
any failed items.
