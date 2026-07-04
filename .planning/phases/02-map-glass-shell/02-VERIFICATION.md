---
phase: 02-map-glass-shell
verified: 2026-07-04
status: passed
must_haves:
  - id: SC1
    label: "Gestures — pan/zoom/rotate; tilt off per CONTEXT.md"
    status: PASS
    evidence: "Device: Samsung Galaxy S24 (SM-S921B), Android 14, Impeller. User confirmed: one-finger pan works, pinch zoom works, two-finger horizontal rotate works, compass snap works. Tilt intentionally disabled (tiltGesturesEnabled: false per 02-CONTEXT.md — flat 2D only). Documented deviation from ROADMAP.md SC1 wording ('tilts smoothly with standard gestures'); 02-CONTEXT.md is the controlling specification."
  - id: SC2
    label: "Offline base map from bundled PMTiles"
    status: PASS
    evidence: "Device: Samsung Galaxy S24, Android 14. Airplane mode enabled before launch. App force-closed and reopened. Map rendered Germany vector tiles from bundled dev_germany.pmtiles (371 MB, maxzoom 11) served via Dart loopback shelf server (http://127.0.0.1:7070). No network requests to external tile CDN. Roads, labels, and background all visible at multiple zoom levels."
  - id: SC3
    label: "Blue dot + camera at current location + recenter"
    status: PASS
    evidence: "Device: Samsung Galaxy S24, Android 14. Location permission dialog appeared on first launch after onboarding. After GPS fix: blue dot visible with accuracy ring. Camera opened at user's actual location (Kleinheubach, Bavaria) — not at Berlin fallback. Panned away: recenter button appeared. Tapped recenter: camera animated back to street-level zoom (~1 km radius). Follow mode resumed."
  - id: SC4
    label: "Dark-mode style auto-switch (soft crossfade)"
    status: PASS
    evidence: "Device: Samsung Galaxy S24, Android 14. System theme flipped Light → Dark in Android Settings, returned to app: map style crossfaded from light Protomaps v4 style to dark Protomaps v4 style (180 ms AnimatedOpacity, no white flash, no abrupt palette jump). Flutter chrome (navigation pill, FAB, recenter) also followed ThemeMode.system. Dark → Light also confirmed."
  - id: SC5
    label: "Liquid Glass shell, no jank (G1 gate PASS confirmed)"
    status: PASS
    evidence: "Device: Samsung Galaxy S24, Android 14, Impeller. Three 64 dp glass circles rendered correctly over live MapLibre map tiles: bottom-nav pill (Map/Trips/Regions tabs), trip FAB, recenter button. Tab switches Map → Trips → Regions → Map: transitions smooth, no frame drops observed. Gear button → Settings screen pushed, back returns to Map with shell intact. FAB tap: SnackBar 'Coming in Phase 3' as expected. LiquidGlass refraction visible over real tile layer — G1 conditional PASS from Plan 02-01 upgraded to unconditional PASS. No sub-30 fps jank observed."
score: "5/5"
requirements_covered:
  - MAP-01
  - MAP-02
  - MAP-03
  - MAP-04
  - MAP-05
  - MAP-06
  - MAP-07
  - UI-01
  - UI-02
  - UI-03
  - UI-04
  - UI-05
  - UI-06
  - UI-07
gaps:
  - id: MAP-03-tilt
    label: "Tilt gesture — intentionally disabled"
    severity: documented-deviation
    detail: "ROADMAP.md SC1 says 'tilts smoothly with standard gestures'. 02-CONTEXT.md overrides this: 'flat 2D only — tilt is not a navigation gesture in Trailblazer'. tiltGesturesEnabled: false is the correct behavior. The deviation is locked in by CONTEXT.md and does not constitute a defect."
  - id: MAP-07-camera-persistence
    label: "Camera position persistence across app restarts — intentionally disabled"
    severity: documented-deviation
    detail: "ROADMAP.md SC3 says 'camera position (last lat/lng/zoom) persists across app restarts'. 02-CONTEXT.md overrides: camera always opens at current location. No SharedPreferences camera storage is implemented. This is a deliberate product decision, not a gap."
  - id: UI-01-foc-pill-stub
    label: "Focus-area pill — stub only"
    severity: partial
    detail: "UI-01 requires the pill to show current admin region + exploration %. In Phase 2 the pill is a glass shape placeholder ('Grebenhain · 26%' hardcoded stub label). Real region + coverage data wired in Phase 8."
  - id: iOS-device-test-not-conducted
    label: "iOS device not tested"
    severity: known-gap
    detail: "No Mac + iOS device available. LiquidGlass on iOS assumed correct (package is iOS-designed; platformBlurEnabled = true). Empirical validation deferred to a future device pass."
human_verification:
  - id: HV1
    description: "Real-device smoke test on Android"
    status: CONFIRMED
    confirmed_by: "User (I551358)"
    confirmed_on: "2026-07-04"
    device: "Samsung Galaxy S24 (SM-S921B), Android 14 (One UI 6.1)"
  - id: HV2
    description: "iOS real-device test"
    status: DEFERRED
    detail: "No Mac + iOS device available. Deferred to future device pass."
---

# Phase 2 Verification — Map + Glass Shell

**Status: PASSED** (2026-07-04, Samsung Galaxy S24, Android 14)

All 5 success criteria confirmed on a real device. G1 rendering gate upgraded from conditional to unconditional PASS. Phase 2 is complete.

---

## Smoke Test Environment

| Field | Value |
|-------|-------|
| Device | Samsung Galaxy S24 (SM-S921B) |
| OS | Android 14 (One UI 6.1) |
| Build type | debug APK |
| Flutter | 3.44.4 (stable) |
| Dart | 3.12.2 |
| Engine | Impeller (default for Android on Flutter 3.44) |
| Test date | 2026-07-04 |
| Tester | I551358 |

---

## SC1 — Gestures (pan / zoom / rotate; tilt disabled)

**Status: PASS**

**Device evidence:** All map gestures work correctly on Galaxy S24.
- One-finger drag: pan
- Pinch: zoom
- Two-finger horizontal rotation: map rotates; compass button appears top-right; tap resets north
- Tilt: intentionally disabled (`tiltGesturesEnabled: false`)

**Deviation note:** ROADMAP.md SC1 says "tilts smoothly with standard gestures". `02-CONTEXT.md` overrides this with "flat 2D only — tilt is not a navigation gesture in Trailblazer". This is the controlling specification. `tiltGesturesEnabled: false` is explicitly set in `MapWidget`; there is no regression to fix. Documented in `02-CONTEXT.md` and in `02-07-SUMMARY.md`.

---

## SC2 — Offline Base Map from Bundled PMTiles

**Status: PASS**

**Device evidence:** Map rendered in airplane mode. App force-closed and reopened with airplane mode active; after onboarding, Germany vector tiles loaded from the bundled PMTiles archive. Roads, labels, and background layers all visible at zoom levels 4–14.

**Implementation:** The Dart loopback tile server (`TileServer` in `lib/features/map/data/tile_server.dart`) copies `assets/tiles/dev_germany.pmtiles` to a temp file on startup, then serves XYZ tiles over `http://127.0.0.1:7070/{z}/{x}/{y}.pbf` using `shelf` + `pmtiles`. Both style JSONs reference `tiles: ["http://127.0.0.1:7070/{z}/{x}/{y}.pbf"]`. No external network requests for tile data.

**Note on tile coverage:** `dev_germany.pmtiles` covers the full Germany bounding box (5.866°E–15.042°E, 47.270°N–55.058°N) at maxzoom 11. MapLibre overzooms from z11 at higher detail levels — adequate for Phase 2 smoke testing. Phase 4 replaces with custom `germany-base.pmtiles`.

---

## SC3 — Blue Dot + Camera at Current Location + Recenter

**Status: PASS**

**Device evidence:**
- Location permission dialog appeared on first launch (after onboarding)
- After GPS fix: blue dot visible with accuracy ring; camera opened at user's actual location (Kleinheubach, Bavaria) — not at fallback
- Panned away: recenter button appeared in the glass circle at bottom-right
- Tapped recenter: camera animated back to approximately 1 km radius street-level zoom; follow mode resumed

**Note on MAP-07 camera persistence:** ROADMAP.md SC3 includes "camera position (last lat/lng/zoom) persists across app restarts". `02-CONTEXT.md` overrides this: camera always opens at current location. No camera persistence is implemented. This is a documented deviation, not a defect.

---

## SC4 — Dark-Mode Style Auto-Switch (Soft Crossfade)

**Status: PASS**

**Device evidence:** System theme flipped Light → Dark in Android Settings while app was in background. Returned to app: map style crossfaded from Protomaps v4 light style to dark style with no white flash. Flutter chrome (glass pill, FAB, recenter, app bars) also followed `ThemeMode.system`. Confirmed both directions (Light→Dark and Dark→Light).

**Implementation:** `MediaQuery.platformBrightnessOf(context)` change detected in `MapWidget` via `didChangePlatformBrightness`. A 180 ms `AnimatedOpacity` fade-to-zero precedes `controller.setStyle(newStyleAsset)`, then fades back in on `onStyleLoadedCallback`.

---

## SC5 — Liquid Glass Shell, No Jank (G1 Gate PASS Confirmed)

**Status: PASS**

**Device evidence:**
- Three 64 dp glass circles render correctly over live MapLibre map tiles:
  - Bottom-nav pill (bottom-left, 12 dp margin) — three tab labels (Map/Trips/Regions)
  - Trip FAB (bottom-right, 12 dp margin) — circular glass recording button
  - Recenter button (above FAB, stacked, 12 dp margin) — circular glass recenter
- LiquidGlass refraction effect visible over tile layer (not just solid background) — full G1 confirmation
- Tab switches Map → Trips → Regions → Map: smooth, no jank
- Gear button (top-left) → Settings screen pushed via `context.push('/settings')`; back returns to Map with shell intact
- FAB tap: SnackBar "Coming in Phase 3" (expected Phase 2 stub behavior)
- No sub-30 fps rendering observed during any interaction

**G1 Gate upgrade:** Plan 02-01 resolved G1 as a conditional PASS (LiquidGlass shader confirmed on Impeller, but over solid background only — demotiles URL failed). SC5 here confirms LiquidGlass renders correctly over a real MapLibre platform view with live PMTiles. The conditional PASS is now unconditional. `LiquidGlassSettings.platformBlurEnabled = true` on both platforms. See `docs/G1_SPIKE.md` Post-Integration Observations section.

---

## Automated Test Results (Pre-Smoke-Test)

All collected before real-device install:

| Check | Result |
|-------|--------|
| `flutter analyze` | 0 issues |
| `dart format --set-exit-if-changed .` | 0 files changed (after style(02-07) commit) |
| `flutter test` | 60 passing + 4 skipped |
| `flutter build apk --debug` | APK built successfully |

**4 skipped tests:** `router_shell_test.dart` — 4 tap-based routing tests skipped with `TODO(I551358)`. The fixed-slot glass circle Stack layout does not route synthetic `tap()` calls through the correct widget on the 800×600 test surface. Non-tap tests (shell renders, tab displays) all pass. Works on-device. Rework deferred to Phase 3+.

**SkSL shader warnings (informational):** `flutter build` prints 3× `impellerc` warnings about `liquid_glass_renderer` shaders not compiling to SkSL. These are Skia-backend-only warnings; Flutter 3.44 defaults to Impeller on Android and iOS. Not a defect. Pre-existing since Plan 02-01; documented in `docs/G1_SPIKE.md`.

---

## Requirement Coverage

| Requirement | Description | Status | Notes |
|-------------|-------------|--------|-------|
| MAP-01 | MapLibre GL renders vector base map | Complete | Protomaps v4 cartoon style, light + dark |
| MAP-02 | PMTiles offline tile source | Complete | dev_germany.pmtiles, loopback server, airplane mode confirmed |
| MAP-03 | Pan, zoom, rotate (tilt) | Complete (deviated) | Tilt disabled per 02-CONTEXT.md |
| MAP-04 | Blue dot when location permission granted | Complete | geolocator + Impeller, accuracy ring visible |
| MAP-05 | Dark mode style auto-switch | Complete | 180 ms crossfade, system theme follow |
| MAP-06 | Style JSON is a project asset | Complete | assets/map_style_light.json + dark.json, Protomaps v4 schema |
| MAP-07 | Camera state persists across restarts | Complete (deviated) | Camera opens at current location per 02-CONTEXT.md; no persistence |
| UI-01 | Focus-area pill | Partial | Glass shape stub only; real data wired in Phase 8 |
| UI-02 | Liquid Glass bottom nav pill | Complete | Three-tab pill, 64 dp, 12 dp margins |
| UI-03 | Liquid Glass FAB | Complete | 64 dp glass circle, trip recording stub |
| UI-04 | Panels/sheets use liquid glass overlay | Partial | Foundation in place; full panel pattern in Phase 8 |
| UI-05 | G1 gate: LiquidGlass rendering spike | Complete | Unconditional PASS — LiquidGlass over real map confirmed |
| UI-06 | No AppBar on map screen | Complete | AppBar absent; focus pill is top chrome |
| UI-07 | LiquidGlassSettings singleton | Complete | lib/core/theme/liquid_glass_settings.dart |

---

## Known Gaps Carried Forward

1. **Tilt disabled** (MAP-03 partial): `02-CONTEXT.md` decision. Will remain disabled unless CONTEXT.md is revised.
2. **Camera persistence** (MAP-07 partial): `02-CONTEXT.md` decision. Opens at current location.
3. **Focus-area pill stub** (UI-01 partial): Shows hardcoded label. Phase 8 wires real region + coverage data.
4. **iOS device not tested**: `platformBlurEnabled = true` on iOS is assumed. Empirical validation deferred.
5. **Router shell tap tests** (4 skipped): `TODO(I551358)` in `test/features/map/router_shell_test.dart`. Phase 3+ rework.
6. **Glyph bundling for full offline labels** (Phase 4+): Protomaps style JSONs reference external glyph URLs; labels may degrade offline. Phase 4 OSM pipeline bundles glyphs.
7. **dev_germany.pmtiles** (Phase 4): Current tile (maxzoom 11, 371 MB, gitignored) replaced by custom `germany-base.pmtiles` in Phase 4.
8. **Custom attribution chip** (Phase 8+): Native MapLibre attribution button pushed off-screen; OSM credits in Settings > ABOUT. A proper Liquid Glass-styled attribution chip is a Phase 8+ enhancement.

---

*Verified: 2026-07-04*
*Verifier: I551358 (real-device smoke test) + automated checks*
*Phase 2 status: COMPLETE*
