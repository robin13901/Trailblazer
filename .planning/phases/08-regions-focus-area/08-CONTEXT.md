# Phase 8: Regions + Focus-Area - Context

**Gathered:** 2026-07-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Browse driven-road coverage by admin region, and surface the region under the map view via a zoom-aware focus pill. Three deliverables:

1. **Focus pill** — tracks the map center, shows "{region name} / {coverage %}", picks the admin level from the current zoom, falls back to the parent region over water/gaps.
2. **Region browser** — a searchable list of area cards (one per region with coverage > 0%), sorted by coverage % descending.
3. **Region detail sheet** — opens from a card or the pill; shows the region's coverage % + km stats.

Percentages are computed via `Σ driven Kfz-length / Σ total Kfz-length` (Feldweg/Fußweg excluded from both) on a compute isolate, and cached in `coverage_by_region`. Requirements: FOC-01..07, REG-01..07, COV-04, COV-07, COV-08.

**Vehicles are Phase 9** — Phase 8 computes GLOBAL coverage only, with a clean hook for per-vehicle later.

</domain>

<decisions>
## Implementation Decisions

### Focus pill behavior
- **Content:** two lines, both center-aligned — region **name** on top, **coverage %** underneath. Name + % only (no level label, no bar in the pill itself).
- **Admin level:** auto-selected from zoom (SC1) — zoomed out → coarse (Land/Bundesland), zoomed in → fine (Ortsteil). No manual level override in v1.
- **Water / no-region fallback:** show the **parent-level** region (SC1) — e.g. over a lake, show the enclosing Gemeinde/Landkreis.
- **Update feel:** update **live during map movement** — both the name and the % should track the camera "as live as possible", NOT only on idle. Must be a **smooth transition with no flicker** in either line.
  - Anti-flicker approach is **Claude's discretion**: likely a short trailing debounce on fast pans/zooms + hold-last-value (never blank/spinner) while the new region/% resolves. The goal (smooth, no flicker on fast movement) is the fixed requirement; the exact debounce ms / technique is open.
  - This is a softening of SC1's "on camera idle (debounced 200 ms)" — user explicitly wants it to feel live, not idle-gated. Planner should treat "live + smooth + no flicker" as the target and the 200 ms idle debounce as one possible implementation detail, not a hard spec.

### Region browser
- **Structure:** ONE flat list of area **cards** — each card is a single region of **any** admin level (Land, Bundesland, Landkreis, Gemeinde, or Ortsteil all mixed in the same list). NOT per-level tabs, NOT a drill-down hierarchy.
- **Coverage-gated listing:** only regions with **coverage > 0%** appear. Consequence: a single trip in one Ortsteil produces exactly 5 cards — its Ortsteil + the Gemeinde + Landkreis + Bundesland + Land that contain it. Nothing else is listed.
- **Default sort:** coverage **% descending** (SC3).
- **Level disambiguation:** each card shows a small **level tag/badge** (e.g. "Gemeinde", "Ortsteil") so the mixed-level list stays legible.
- **Card content:** region name + coverage % + **km stats (driven km + total km)**. No progress bar (the % conveys that).
- **Search:** **global fuzzy search** across all listed regions and all levels at once (SC3) — typing "greb" finds Grebenhain regardless of its level.
- **No filter controls** — search alone is sufficient (user dropped the filter-chips idea).

### Region detail sheet
- **Presentation:** draggable **Liquid Glass bottom sheet** (partial → full height); map stays visible behind at partial height. Matches app chrome.
- **Header:** **current region only** — name + level tag. NO breadcrumb / ancestor path (deviates from SC2, confirmed).
- **Body:** coverage % + km stats (driven km + total km). Possibly **total driving time in region** — see research flag below.
- **Driven-ways list and top-trips list: DROPPED ENTIRELY** (not deferred). Deviates from SC2. Rationale: at Germany scale these become lists of thousands-to-millions of entries and are never useful. User does not want them now or later.
- **Jump to on map:** a **"Jump to on map" button** that fits the map to the region's bounding box (SC4) and closes/collapses the sheet.

### Coverage stats & percentages
- **% precision:** **one decimal** everywhere (e.g. "26.4%") — pill, cards, and sheet.
- **km stats:** **driven km + total km** (the explicit numerator/denominator of the %). NOT unique km, NOT remaining km.
- **Scope:** **global coverage only** for Phase 8 (all trips). Per-vehicle stats (SC5) are out of scope — leave a clean plumbing hook; the vehicle UI lands in Phase 9.
- **No global/summary header** in the browser — just the sorted list of area cards.

### Claude's Discretion
- Exact anti-flicker/debounce technique for the live pill (trailing debounce ms, hold-last-value, %-count animation) — goal is fixed, mechanism is open.
- Card and sheet spacing, typography, exact km formatting/rounding.
- Level-tag label wording and styling.
- Fuzzy-match algorithm and result ranking.
- Whether coverage %-count visibly animates when the pill value changes.

</decisions>

<specifics>
## Specific Ideas

- Pill layout is specifically **two centered lines** (name over %), not a single inline "{name} · {%}" string.
- The coverage-gated flat-card model is the user's own framing and should be preserved as-is: "if I only have a trip in one Ortsteil, there should initially be exactly the corresponding Land / Bundesland / Landkreis / Gemeinde / Ortsteil."
- Live pill must survive **fast pans** without number- or name-flicker — this is the acceptance feel, call it out in the plan's checkpoint.

</specifics>

<deferred>
## Deferred Ideas

- **Per-vehicle coverage stats** (SC5) — Phase 9 (vehicles). Phase 8 leaves a hook only.
- **Filter chips** (by admin level / coverage range / vehicle) — dropped for v1; search is sufficient. Re-open only if search proves inadequate.
- **Manual level override on the pill** (tap to step level up/down) — not in v1; auto-by-zoom only.

## SC deviations to reconcile in planning (flag to planner)
- **SC2 amended:** detail sheet is stats-only. NO breadcrumb, NO driven-ways list, NO top-trips list. These are removed from Phase 8 scope permanently (not deferred).
- **SC3 reframed:** region browser is a single flat coverage-gated card list (any level, mixed), NOT per-admin-level tabs. Same capability (browse coverage by region), simpler shape. Search stays; filter-by-sort alternatives (alphabetical / driven km / total km / last-driven) not requested — default %-desc only unless planner sees low-cost value.
- **SC1 softened:** pill updates live during movement (smooth, no flicker), not strictly on-idle-debounced-200ms.

## Research flags (for gsd-phase-researcher)
- **Total driving-time-per-region:** investigate whether summing per-trip driving duration attributed to each region is feasible/cheap given the current trip + interval + region-lookup data model. Ship the metric in the sheet if cheap; skip it if it requires expensive per-fix region attribution. Not important — explore, then decide.
- Confirm the compute-isolate + `coverage_by_region` cache path (COV-04/07/08, from Phase 6) can serve live-during-movement pill reads fast enough, or whether a warm in-memory cache is needed for the pill specifically.

</deferred>

---

*Phase: 08-regions-focus-area*
*Context gathered: 2026-07-10*
