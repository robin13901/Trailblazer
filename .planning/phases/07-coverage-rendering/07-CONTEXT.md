# Phase 7: Coverage Rendering - Context

**Gathered:** 2026-07-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Driven roads paint onto the map with correct full-vs-partial coverage semantics; the feature-state fallback gate (G2) is resolved. Delivers: per-way coloring of driven **Kfz** ways via MapLibre `feature-state` (or the sharded-GeoJSON fallback if G2 fails), full/partial coverage tiers, the 50k-segment ≥ 30 fps stress verification, and a user-facing coverage-color picker in Settings.

**Scope narrowing (locked this session):** Only driven **Kfz** ways receive Phase-7 coverage styling. Feldweg/Fußweg ways are **entirely out of scope** for Phase 7 — see the REN-02 deviation below and Deferred Ideas.

Requirements in scope: REN-01, REN-02 *(dropped — see deviation)*, REN-03, REN-04, REN-05 (Gate G2), REN-06, COV-02, COV-03.

**Requirement deviations flagged for the planner to reconcile in REQUIREMENTS.md / ROADMAP.md:**
1. **REN-01 default color:** spec says "warm green"; user chose **orange/amber** as the default explored color. Green becomes one of the 5 presets. Planner must update REN-01's default.
2. **REN-02 (dashed-blue Feldweg rendering):** **DROPPED from v1.** Feldwege render only as whatever the Phase-4 base pmtiles style already paints — no coverage overlay, no dashed-blue, no driven-state coloring. Planner must strike REN-02 from the v1 scope (mark de-scoped, not merely deferred) and update ROADMAP P7-SC1 (which currently splits Kfz feature-state vs Feldweg static secondary color).

</domain>

<decisions>
## Implementation Decisions

### Color scheme & palette (REN-01, REN-06)

- **Default explored color:** **Orange/amber** — maximum pop over both light and dark base maps. (Deviation from REN-01 "warm green" — green is now just a preset.)
- **Palette size:** **5 presets** for the explored color (curated, not a free hex/color-wheel picker). Green is one of them. Exact 5 hues are planner discretion, but must include green (to honor original REN-01 intent as an option) and read accessibly over both base-map styles.
- **Dark mode:** **Claude's discretion** — per-preset dark variant vs single value decided during implementation based on how each hue actually reads on the Phase-2/4 dark style. Must preserve the existing brightness-swap contract (light/dark style JSONs stay structurally identical — the `map_style_fade` widget assumes this).
- **Coverage tiers:** **2 visual tiers only** — fully-explored and partial. Undriven Kfz ways = base-map default (see below). No third "faint/barely seen" band.

### Partial-coverage look (COV-03, REN-03)

- **Render technique:** **Reduced opacity scaled by coverage fraction** — the whole way renders in the explored hue at an opacity proportional to how much of it is driven. This is the REN-03 documented fallback, chosen deliberately over per-driven-segment geometry coloring (too heavy) and flat single-partial-color.
- **Partial color source:** **Lighter shade of the active explored hue** — auto-derived from whatever preset is selected (e.g. pale orange under an orange preset), not a fixed independent color. "Same road, less done" reads intuitively and tracks the user's chosen preset automatically.
- **Minimum floor before a way shows partial:** **Yes, there is a floor** (stray single-clip GPS must not light up a long autobahn). Exact floor value — %-of-length vs absolute meters vs `max(5%, 50 m)` — is **Claude's discretion**, to be tuned against the golden corpus.
- **Opacity ramp start/band:** **Claude's discretion** — the min→max opacity band for just-past-floor → near-full is tuned during implementation for readability over both base maps.

### Driven-way styling (REN-01, REN-04)

- **Line width:** **Zoom-scaled boost** — near base-road width when zoomed in, boosted when zoomed out so the explored network stays legible at country scale. (Not flat same-width, not flat thicker.)
- **Emphasis:** **Flat recolor, no glow, no casing** — relies on color contrast alone. Chosen explicitly to protect the 50k-segment ≥ 30 fps gate (REN-04). No halo/glow, no outline.
- **Undriven Kfz roads:** **Left as base-map default** — no muting/desaturation "fog of war." Explored (orange) ways pop by contrast against untouched base roads.
- **Feldweg/Fußweg:** **Out of scope** — no Phase-7 styling. Renders as plain Phase-4 base geometry.

### Color-picker & live-apply UX (REN-06)

- **Location:** **Settings row** — a "Coverage color" row inside the existing Settings screen that opens the 5 preset swatches. Consistent with the app's settings pattern (not an on-map quick control).
- **Apply model:** **Pick-then-confirm** — user selects a swatch then confirms/saves; the map updates on close. (Not instant-recolor-behind-the-picker.) The "applies live without full map reload" REN-06 requirement is satisfied by the map re-styling on close **without a full map/tile reload** — the feature-state paint (or fallback source paint) updates in place.
- **Preview:** **The live map is the preview** — no separate sample-swatch mock inside the picker. Users see their actual coverage recolor when they return to the map. (Whether to add a tiny inline swatch is Claude's discretion but not required.)

### Claude's Discretion

- Gate G2 resolution (feature-state vs sharded-GeoJSON-per-5×5-km-tile) and the entire render architecture — technical, not a user gray area.
- The exact 5 preset hues (must include green; must be accessible over light + dark).
- Dark-mode strategy per preset.
- Partial minimum-coverage floor value and the opacity ramp band (tune against golden corpus).
- Whether dark-mode explored colors are hand-tuned per preset or shared.
- Any inline swatch preview inside the picker (live map is the required preview).
- Settings-row placement/label wording within the Settings screen.

</decisions>

<specifics>
## Specific Ideas

- **Orange/amber default** was chosen for "maximum pop over both light and dark base maps" — the explored network should be immediately obvious the moment the map opens (ties directly to the project core value: "when I open the map, I immediately see the roads I've already driven").
- **Partial = lighter shade + fraction-scaled opacity** should read as a natural progression toward "fully explored orange" — the same road getting more solid/vivid as you drive more of it, not a different-colored road.
- **Flat color, no glow** is a deliberate performance-first choice — the 50k-segment fps gate (REN-04) is the hard constraint; visual flourish yields to it.
- The **Phase-6 Trip History full-screen detail** (raw polyline + driven-way intervals overlay) is the same rendering path this phase generalizes app-wide — reuse where possible.

</specifics>

<deferred>
## Deferred Ideas

- **Dashed-blue Feldweg / Fußweg rendering (REN-02)** — **dropped from v1**, not merely postponed. A future "show trails/tracks" toggle could revive it in a later milestone, but there is no committed phase for it. Backlog only.
- **Per-driven-segment geometry coloring** (coloring only the exact driven interval of a partial way rather than opacity-scaling the whole way) — richer partial fidelity, deferred to v1.x. Chosen against for v1 on render-cost grounds.
- **Proportional gradient along a partial way** (color ramp from driven end to undriven end) — the COV-03 "v1.x" enhancement; v1 uses whole-way opacity scaling instead.
- **Free color-wheel / hex picker** — v1 ships 5 curated presets only; arbitrary color selection is a later enhancement.
- **"Fog of war" muting of undriven roads** — considered and declined for v1; undriven roads stay at base-map styling. Revive as an optional "focus mode" toggle later if desired.
- **On-map quick color access** — v1 keeps the picker in Settings; a map-side quick swatch is a later convenience.

</deferred>

---

*Phase: 07-coverage-rendering*
*Context gathered: 2026-07-09*
