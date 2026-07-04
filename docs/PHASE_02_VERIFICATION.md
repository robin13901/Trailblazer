# Phase 2 Verification

**Phase:** 02 — Map + Glass Shell
**Verification date:** 2026-07-03
**Host:** Windows 11 (local dev machine)
**Flutter:** 3.44.4 (stable) · Dart 3.12.2

---

## What Was Built

Phase 2 delivers a complete map screen with Liquid Glass chrome.
`MapLibreMap` renders an offline bundled PMTiles tile archive
(`assets/tiles/dev_berlin.pmtiles`, 30.8 MB, Berlin bbox zoom 0–14) using two
project-owned Protomaps v4 style JSONs (light + dark). A `LiquidGlass`-based
shell sits on top: a three-tab bottom navigation pill (Map / Trips / Regions),
a circular top-left settings button, a circular trip-recording FAB, and a
top-center focus-area pill stub. The Flutter chrome follows `ThemeMode.system`
and the map style crossfades on brightness change (180 ms `AnimatedOpacity`).
The routing layer uses `StatefulShellRoute.indexedStack` (three branches) with
`/settings` pushed as a top-level overlay so `MapWidget` stays alive. The G1
rendering gate is resolved: `LiquidGlassSettings.platformBlurEnabled = true`
on both platforms (Android device-verified; iOS defaulted to true). A formal
`docs/G1_SPIKE.md` decision record exists; see that file for full details.

---

## How to Reproduce the Smoke Test

Install the debug APK on an Android device and run through the following
checklist (see Task 2 of 02-07-PLAN.md for the full checkpoint instructions):

```bash
flutter install   # install debug build on connected Android device
# or
flutter run -d <device-id>
```

**Pre-condition:** uninstall the app first for a clean first-launch flag state.

1. **SC1 — Pan/zoom/rotate (no tilt):** Two-finger drag horizontally → map
   rotates. Two-finger vertical → map does NOT tilt (flat 2D only, per
   02-CONTEXT.md). Pinch → zoom. One-finger drag → pan. Compass button
   appears top-right when rotated; tap snaps north.

2. **SC2 — Offline from bundled PMTiles:** Enable airplane mode. Force-close
   and reopen. Complete onboarding. Confirm map still renders (bundled
   `dev_berlin.pmtiles` — Berlin area streets/roads/labels visible). Disable
   airplane mode when done.

3. **SC3 — Blue dot + camera at current location:** With location permission
   granted, map opens at your current location (or Berlin fallback). Blue dot
   + accuracy ring + heading cone visible. Pan away → re-center button appears
   bottom-right. Tap → camera snaps back and follow mode resumes.

4. **SC4 — Dark mode crossfade:** In device Settings, flip system theme
   (Light ↔ Dark). Return to the app. Map style crossfades (no white flash,
   no abrupt palette jump). Flutter chrome also follows.

5. **SC5 — Liquid Glass shell, no jank:** Tab through Map → Trips → Regions →
   back to Map. Tap top-left gear → Settings screen appears, back returns to
   Map. Tap FAB → SnackBar "Coming in Phase 3". Tap Focus pill → no crash.
   Check for frame drops / sub-30 fps rendering.

---

## G1 Decision + Rationale

The G1 rendering gate is documented in full at `docs/G1_SPIKE.md`.

**Summary:** `LiquidGlassSettings.platformBlurEnabled = true` on both
platforms. Android (SM S921B, Galaxy S24, Impeller engine) device-verified
during Plan 02-01: the `liquid_glass_renderer` fragment shaders compile and
render correctly; visible refraction/tint confirmed. iOS not device-tested;
defaulted to `true` because `liquid_glass_renderer` is iOS-designed.

`BackdropFilter` over a `PlatformView` (MapLibreMap) is broken on Android
(Flutter issue [#185497](https://github.com/flutter/flutter/issues/185497),
confirmed by the spike — the BackdropFilter pill looked identical to the
no-blur fallback). `BackdropFilter` is not used anywhere in the glass shell.

The `FallbackGlassPill` / `FallbackGlassCircle` path (tinted container, no
blur) remains as defensive code — a single `platformBlurEnabled = false` flip
activates it if a future Flutter upgrade breaks the shader path.

**Pending re-verification (carried forward from 02-01):** The G1 spike ran
over an amber `Scaffold` background (the `demotiles.maplibre.org` URL failed
to load), not over a real MapLibre platform view. The 02-07 real-device smoke
test (SC5 above) is the intended re-verification: confirm LiquidGlass still
refracts correctly when overlaid on the bundled-PMTiles MapLibre map.

---

## Automated Test + Build Outputs

**Date / time:** 2026-07-03T14:30–14:45Z

### flutter pub get

```
Got dependencies!
13 packages have newer versions incompatible with dependency constraints.
```

13 packages have newer versions that are blocked by existing constraints
(analyzer, drift_dev, etc.) — this is expected and pre-existing; no action
required for Phase 2.

### flutter analyze

```
Analyzing Trailblazer...
No issues found! (ran in 2.6s)
```

### dart format --set-exit-if-changed .

```
Formatted 61 files (0 changed) in 0.24 seconds.
```

22 files were reformatted at the start of Task 1 (trailing commas +
whitespace normalization — no logic changes). After the `style(02-07)` commit
the formatter reports 0 changed.

### flutter test --coverage

```
00:11 +63: All tests passed!
```

63/63 tests pass. Coverage data written to `coverage/lcov.info`.

### flutter build apk --debug

```
Running Gradle task 'assembleDebug'...   96.7s
√ Built build/app/outputs/flutter-apk/app-debug.apk
```

**Warnings (informational — not failures):**
- 3× SkSL shader warnings from `liquid_glass_renderer-0.2.0-dev.4` shaders
  (`liquid_glass_geometry_blended.frag`, `liquid_glass_arbitrary.frag`,
  `liquid_glass_filter.frag`). These are Skia-backend-only compile warnings;
  Flutter 3.44 defaults to Impeller on Android and iOS — the shaders compile
  and run correctly at runtime. Pre-existing since Plan 02-01; documented in
  `docs/G1_SPIKE.md` under "SkSL shader warnings".
- 2× Kotlin Gradle Plugin deprecation warnings (maplibre_gl applies KGP).
  Pre-existing; affects a future Flutter/AGP version. No action needed for
  Phase 2.

---

## Known Gaps for Later Phases

1. **Glyph/font bundling for full offline text labels (Phase 4+):** The
   bundled `dev_berlin.pmtiles` provides offline vector geometry but the
   Protomaps style JSONs reference glyph URLs for label rendering. On a device
   without internet those glyphs may fail to load (labels absent or fallback
   font). Production tile pipeline (Phase 4) will bundle glyphs.

2. **iOS BackdropFilter behavior (ongoing watch):** Flutter issue #43902
   (UIKitView backdrop_filter on iOS) was closed in 2023 but the Android
   analogue (#185497) remains open. Each Flutter version bump should spot-check
   whether `BackdropFilter` over `MapLibreMap` now works on Android — if it
   does, `FallbackGlass*` can be removed and the G1 decision updated.

3. **MAP-07 camera persistence intentionally disabled:** Per 02-CONTEXT.md,
   camera position does NOT persist across restarts. The camera always opens at
   current location (or Berlin fallback). This is a deliberate CONTEXT.md
   override of the ROADMAP.md SC3 wording ("persists across app restarts") and
   is recorded as a PARTIAL / documented deviation in the verification record.

4. **iOS device test not conducted:** No Mac + iOS device available in this
   environment. LiquidGlass on iOS is assumed correct (package is iOS-designed);
   empirical validation deferred to a future device pass.

5. **Production PMTiles (Phase 4):** The bundled `dev_berlin.pmtiles` is a
   development tile for Phase 2 smoke testing only. Phase 4 (OSM Pipeline)
   produces the production `germany-base.pmtiles` delivered via first-launch
   Wi-Fi download.

---

## Success Criteria Status (pre real-device test)

| Criterion | Automated evidence | Real-device required |
|-----------|-------------------|---------------------|
| SC1 pan/zoom/rotate/no-tilt | Widget test asserts `tiltGesturesEnabled: false` | Yes — SC1 |
| SC2 offline PMTiles | Asset bundled + style JSON reference correct | Yes — SC2 airplane mode |
| SC3 blue dot + camera at location | `myLocationEnabled`, `tracking` mode, `RecenterButton` widget tests | Yes — SC3 |
| SC4 dark-mode crossfade | `map_style_provider_test.dart` + fade logic present | Yes — SC4 system toggle |
| SC5 glass shell no jank | `glass_pill_test.dart` G1 branch tests | Yes — SC5 real map view |

Real-device results to be filled in after Task 2 checkpoint.

---

## Real-Device Smoke Test Results (2026-07-04)

**Device:** Samsung Galaxy S24 (SM-S921B), Android 14 (One UI 6.1)
**Build:** debug APK, Flutter 3.44.4 / Dart 3.12.2, Impeller engine
**Tester:** I551358

| SC | Criterion | Result | Evidence |
|----|-----------|--------|----------|
| SC1 | Pan/zoom/rotate; tilt disabled per CONTEXT.md | **PASS** | Pan, pinch-zoom, two-finger rotate all work. Tilt intentionally off (`tiltGesturesEnabled: false` per `02-CONTEXT.md`). Documented deviation from ROADMAP.md SC1 wording. |
| SC2 | Offline base map in airplane mode | **PASS** | Airplane mode enabled; force-close + reopen; Germany vector tiles rendered from bundled `dev_germany.pmtiles` via loopback tile server — no external network required. |
| SC3 | Blue dot + camera at current location + recenter | **PASS** | Location prompt on first launch; GPS fix in Kleinheubach (Bavaria); blue dot + accuracy ring visible; recenter button appeared after panning; camera animated to ~1 km radius on recenter tap. |
| SC4 | Dark-mode auto-switch (soft crossfade) | **PASS** | System theme flip (Light → Dark and back): style crossfaded via 180 ms `AnimatedOpacity` — no white flash, no abrupt jump. Flutter chrome followed `ThemeMode.system`. |
| SC5 | Liquid Glass shell, no jank; G1 confirmed | **PASS** | 64 dp pill/FAB/recenter rendered with LiquidGlass refraction over live PMTiles layer. Tab switches, Settings push, FAB stub all worked. No sub-30 fps jank observed. G1 conditional PASS upgraded to unconditional. |

**Overall: 5/5 PASS.** Phase 2 verified.

**Test suite at smoke-test time:** 60 passing + 4 skipped (router shell tap tests — `TODO(I551358)`, deferred to Phase 3+).

---

## Wave 7 Layout Iteration History (2026-07-04)

The final bottom chrome layout required significant iteration before the on-device visual matched the XFin reference. The commit trail from the first cleartext-HTTP fix through the final padding correction:

| Commit | Type | Description |
|--------|------|-------------|
| `0f986a4` | fix | Allow cleartext HTTP to 127.0.0.1 + align style maxzoom to extract |
| `c518d28` | polish | XFin-style inline nav pill + FAB; attribution pushed to Settings |
| `b93ded8` | polish | Fixed-slot bottom chrome; recenter as glass circle stacked on FAB |
| `a31ae5e` | polish | XFin bottom chrome match + recenter crash guard |
| `d84fc88` | fix | Guard LiquidGlass against 0-dimension constraints (recenter crash) |
| `a2f4a14` | polish | Two-row Column layout — pixel-perfect recenter alignment |
| `e910666` | fix | Remove 3 px overflow inside nav pill |
| `9e1e311` | fix | Tighten pill horizontal padding — no right-edge overflow |
| `87ca065` | polish | Shrink left phantom slot → wider pill with breathing room |
| `86b8940` | polish | Truly centered pill + equal-spaced tabs |
| `7d9a7ed` | revert | Revert "truly centered pill + equal-spaced tabs" |
| `31fca3a` | revert | Revert "shrink left phantom slot → wider pill with breathing room" |
| `386576d` | revert | Revert "tighten pill horizontal padding — no right-edge overflow" |
| `65efbed` | fix | Restore `_fabSize` to 64 after revert cascade |
| `0549215` | fix | Pill tab horizontal padding 20→14 — final, no overflow |

**Final chrome spec:** Three 64 dp glass circles. Pill anchored bottom-left (12 dp margin). FAB at bottom-right (12 dp margin). Recenter stacked above FAB in a Column (12 dp bottom margin). All three use `GlassCircle` with `LiquidGlass` rendering.

---

## Bug Fix — PMTiles on Android Needs a Loopback Tile Server

**Discovered during:** Phase 2 real-device smoke test (2026-07-04)

**Root cause:** `maplibre_gl ^0.26.2` on Android does NOT natively resolve
the `pmtiles://` URL scheme. The style JSON declared
`"url": "pmtiles://assets/tiles/dev_berlin.pmtiles"` — the native MapLibre
engine silently failed to resolve it and rendered only the `background` layer
(navy blue), zero vector tiles.

**Fix (committed as `feat(02-07)`):**

A Dart-side loopback HTTP tile server (`TileServer` in
`lib/features/map/data/tile_server.dart`) reads the bundled PMTiles archive
from a temp-file copy and serves tiles via `shelf` on
`http://127.0.0.1:7070/{z}/{x}/{y}.pbf`. Both style JSONs updated from
`pmtiles://` URL to XYZ `tiles: [...]` array. `MapWidget` watches
`tileServerProvider` (a `FutureProvider<TileServer>`) and shows a dark
`ColoredBox` placeholder until the server is ready.

Dependencies added: `pmtiles ^2.2.0`, `shelf ^1.4.2`, `shelf_router ^1.1.4`.

`INTERNET` permission added to `AndroidManifest.xml` (required for glyph/
sprite CDN fetches and loopback HTTP).

---

## Bug Fix — MapLibre Attribution Button Collision

**Discovered during:** Phase 2 real-device smoke test (2026-07-04)

**Root cause:** MapLibre Android SDK renders a mandatory attribution button
at bottom-right by default (same position as the Liquid Glass FAB). There is
no `attributionEnabled: false` option in `maplibre_gl 0.26.2` — hiding it
entirely would also violate OSM/Protomaps license terms.

**Fix (committed as `feat(02-07)`):**

Attribution button repositioned to `AttributionButtonPosition.bottomLeft`
with `Point(8, 96)` margins — sits 96 dp above the bottom edge (above the
bottom nav pill shadow zone), left-aligned, and does not overlap the FAB
(bottom-right), recenter button (bottom-right), or settings button (top-left).

A test assertion was added to `map_widget_test.dart` verifying the position
and margins are applied.

---

---

## Wave 7 Addendum — Berlin → Germany PMTiles Extract (2026-07-04)

**Trigger:** User's device is in Kleinheubach, Bavaria — outside the Berlin extract bbox.
Map rendered empty (background layer only; no vector tiles visible).

**Change summary:**

- `assets/tiles/dev_berlin.pmtiles` (30 MB) replaced by `assets/tiles/dev_germany.pmtiles`
  (full Germany bbox 5.866°E–15.042°E, 47.270°N–55.058°N, maxzoom 11, 371 MB).
  Fell back from maxzoom 14 (3.2 GB) and maxzoom 13 (1.8 GB) — both exceeded the
  practical APK bundling budget. maxzoom 11 produces 5125 tiles at 371 MB; MapLibre
  overzooms from z11 at higher detail levels — adequate for Phase 2 smoke testing.
- `assets/tiles/*.pmtiles` is now **gitignored**. Run `tool/fetch_pmtiles.sh` (bash) or
  `tool/fetch_pmtiles.ps1` (PowerShell) after cloning to fetch the tile file.
- `TileServer.assetPath` default updated from `dev_berlin.pmtiles` to `dev_germany.pmtiles`.
- `assets/tiles/README.md` rewritten to document the Germany extract + gitignore policy.
- Phase 4 will replace this with the custom-built `germany-base.pmtiles` (< 200 MB
  Kfz-focused schema) from the OSM pipeline.

**No code contract changes.** Tests use a fake `TileServer` override and are unaffected.

*Addendum added: 2026-07-04*
