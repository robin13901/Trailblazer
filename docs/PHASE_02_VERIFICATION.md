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

*Document created: 2026-07-03 by Plan 02-07 executor.*
*Updated after Task 2: (pending real-device checkpoint)*
