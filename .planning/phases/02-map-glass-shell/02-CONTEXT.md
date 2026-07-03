# Phase 2: Map + Glass Shell - Context

**Gathered:** 2026-07-03
**Status:** Ready for planning

<domain>
## Phase Boundary

A map screen with Liquid Glass chrome renders fluidly on both platforms. MapLibre + PMTiles offline base map, project-owned light/dark map styles, the full Liquid Glass UI shell (bottom nav pill, FAB stub, focus-area pill stub, settings button), and the rendering spike gate G1 resolved. No trip recording, no coverage data, no region logic — pure map + shell.

</domain>

<decisions>
## Implementation Decisions

### Map feel & behavior
- Opens at current device location at a "local area" zoom (a few neighbouring streets — roughly Google Maps address-level zoom, ~zoom 15)
- Flat 2D only — no tilt/pitch gesture
- Free rotation with two-finger twist; compass button appears when rotated; tap compass to snap back to north
- During active trips (Phase 3+): follow mode + heading-lock (camera rotates to match driving direction); architecture must support this mode being added in Phase 3

### Liquid Glass shell layout
- Bottom pill with 3 tabs: **Map / Trips / Regions** (Settings moved out to avoid crowding)
- Bottom-right circular FAB for starting trips — stub in Phase 2 (tap does nothing / shows placeholder); Phase 3 wires it up
- Top-left small Liquid Glass button for Settings (gear icon, same glass aesthetic, floating)
- Top-center/top focus-area pill — visible stub showing placeholder text (e.g. "—"); Phase 8 wires it to live region + coverage data

### Dark mode & map style
- Light mode: Google Maps-inspired — clean, colorful roads, labeled, traffic-friendly palette
- Dark mode: Deep navy (Google Maps dark feel) — softly colored roads on dark blue background
- Style switch: soft fade/crossfade when system theme changes — no abrupt re-render
- Style source: Claude's discretion — use most polished open-source base (e.g. MapTiler or similar) and customize to match the Google Maps feel; use the ui-ux-pro-max skill for color decisions

### Location & camera
- Location indicator: blue dot + accuracy ring + heading cone/chevron
- Camera always opens at current location — no persistence of last position across restarts
- Re-centering: tap the dot or a dedicated re-center button to snap camera back to current location; panning away from location exits follow mode freely
- Location permission: asked during onboarding (before the map screen loads); map shows appropriate state if denied

### Claude's Discretion
- Exact map style JSON design (colors, road widths, label sizes) — use ui-ux-pro-max skill
- Which open-source base style to fork (MapTiler, Stadia, etc.) — pick whichever achieves most polished Google Maps feel
- Compass button placement and visual design
- Re-center button placement and visual design
- Exact PMTiles bundling strategy and loading behavior
- G1 spike gate resolution approach (BackdropFilter / liquid_glass_renderer validation)
- Fallback design if G1 fails (FrostedGlassCard + gradient tint)

</decisions>

<specifics>
## Specific Ideas

- "I want it to be the local area roughly, so a few neighbouring streets" — this is the target zoom level on app open (Google Maps address-level feel, ~zoom 15)
- "Liquid Glass optic" — the settings top-left FAB should share the same glass aesthetic as the rest of the shell; not a plain icon, but visually consistent with the bottom pill and focus pill
- Shell layout rationale: if bottom pill gets too narrow with 4 items + FAB, Settings moves to top-left glass button, leaving 3 items in the pill

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 02-map-glass-shell*
*Context gathered: 2026-07-03*
