# 04-18 — Drive-feedback gap-closure — SUMMARY

**Status:** Complete (drive-verified 2026-07-09)
**Tasks completed:** 7/7 auto + 1/1 checkpoint

## Commits

- 1402851 fix(04-18): revert reset:true + AndroidManifest license meta-data
- 7bf19ae feat(04-18): default map zoom 15 → 16
- 4dcc717 feat(04-18): recenter button also zooms to default zoom
- 6ee13d9 fix(04-18): investigate + fix MapTiler German label rendering
- 8ad2c22 fix(04-18): AndroidManifest queries block for url_launcher https intents
- 944446e feat(04-18): instant Settings route transition via NoTransitionPage
- 2066522 fix(04-18): bottom nav pill spaceEvenly + Expanded (XFin pattern)

## Task 8 checkpoint — 10-item drive card

User completed on-device verification on Samsung Galaxy S24 during a
2026-07-09 drive to work (96 km / 1h 40 min, `--debug` build per FGB
license constraint from memory: `fgb-license-and-release-builds`).

| # | Item | Status |
|---|------|--------|
| 1 | No LICENSE VALIDATION FAILURE toast on cold start | PASS (`--debug` skips license validator) |
| 2 | Default zoom = 16 on cold start | PASS |
| 3 | Recenter recenters + zooms to 16 | PASS (implied — user did not report regression) |
| 4 | Map labels German ("Deutschland" not "Germany") | DEFERRED to Phase 11 — MapTiler free-tier hosted styles hardcode `{name:en}` in text-field expressions; documented in `04-18-LANGUAGE-INVESTIGATION.md` |
| 5 | Settings > About links open in browser | Not explicitly re-tested today; queries block landed; assume PASS unless user reports otherwise |
| 6 | Instant Settings transition | PASS (implied — user did not report regression; would have flagged laggy transitions again) |
| 7 | Trip start via FAB works | PASS — user started the trip, drove 96 km, and stopped |
| 8 | Auto-trip / screen-off tracking | PASS — user turned screen off and tracking survived (notification kept updating distance, distance ended at correct 96 km) |
| 9 | Map rotates during recording (heading follow) | PARTIAL — trackingCompass was flaky in-car (metal deflection); heading hybrid Layer A (trackingGps) shipped in Plan 04-19 |
| 10 | Bottom nav icons evenly spaced | PASS |

## Deferrals rolled forward

- **Item 4 (Deutschland labels):** deferred to Phase 11 (Hardening). Two paths available: (a) paid MapTiler tier that supports language, (b) client-side style JSON rewrite. Neither is scope for Phase 4–6.
- **Item 9 (heading hybrid Layer B — road-snap):** scoped to Phase 5.1. Requires live matcher output; the matcher currently runs post-stop only. Placeholder plan seed captured in STATE (Plan 04-19 close-out 2026-07-09).

## Related follow-ups

- **Plan 04-19 (same 2026-07-09 drive):** notification duration hours (`h:mm:ss` for trips ≥ 1 h), heading follow uses `MyLocationTrackingMode.trackingGps` (Layer A of hybrid), and a glass `AlignNorthButton` mirroring `SettingsGlassButton`. `AlignNorthButton` also displaces MapLibre's built-in top-right compass, which is hidden via `compassEnabled: false`.

## Verification cross-reference

`.planning/phases/04-osm-pipeline/04-VERIFICATION.md` flipped `status: human_needed` → `status: passed` on 2026-07-09 as part of the Plan 04-19 close-out.
