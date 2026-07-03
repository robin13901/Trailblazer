---
phase: 02-map-glass-shell
plan: "01"
subsystem: rendering
tags: [g1-gate, liquid-glass, maplibre, spike, platform-view, impeller]

# Dependency graph
requires:
  - phase: 01-scaffolding
    provides: Package layout, Riverpod codegen-off pattern, very_good_analysis lint baseline
provides:
  - G1 rendering gate binary decision (`LiquidGlassSettings.platformBlurEnabled`)
  - Reusable glass settings singleton with shared visual parameters
  - Re-runnable spike screen (`SpikeG1Screen`) for future re-verification
  - Fallback path scaffolded as defensive code
affects: [02-02, 02-05, 02-07]

# Tech tracking
tech-stack:
  added:
    - "maplibre_gl ^0.26.2"
    - "liquid_glass_renderer 0.2.0-dev.4 (exact pin — dev release)"
  patterns:
    - "Package-level singleton for one-shot gate flags (static field + instance getter)"
    - "Import-alias renderer types as `lg.*` to avoid name collision with in-project settings class"
    - "Re-runnable spike screens kept in `lib/features/*/presentation/` as diagnostics, unwired from router"

key-files:
  created:
    - "lib/core/theme/liquid_glass_settings.dart"
    - "lib/features/map/presentation/spike_g1_screen.dart"
    - "docs/G1_SPIKE.md"
  modified:
    - "pubspec.yaml"
    - "pubspec.lock"
    - "lib/main.dart"
    - ".planning/STATE.md"

key-decisions:
  - "G1 gate: `platformBlurEnabled = true` on both platforms (conditional PASS; Android device-verified on SM S921B, iOS defaulted-true)"
  - "Re-verification pending in Plan 02-02 — demotiles didn't load during the spike, so LiquidGlass wasn't tested over a real MapLibre platform view"
  - "BackdropFilter is dead-on-arrival on Android (confirmed Flutter issue #185497) — glass shell will not use it going forward"
  - "LiquidGlassSettings API refactor: `setPlatformSupportsBlurOverMap(value:)` method dropped in favor of `platformBlurEnabled` public static field (very_good_analysis lint cycle forced this)"
  - "LiquidRoundedSuperellipse.borderRadius takes a double, not Radius — corrected from plan sketch after reading pub cache source"
  - "SpikeG1Screen kept in-tree as a re-runnable diagnostic (not deleted after spike)"

patterns-established:
  - "Conditional PASS: gate flipped to true with an explicit re-verify item on the immediately-following plan — captures 'we tested most of it' outcomes without blocking downstream work"
  - "Read pub-cache source before writing spike code when the plan sketch predates dependency install"
  - "SkSL warnings during flutter test are Impeller-only-package smoke, not a defect — flag in the record so future readers don't chase it"

# Metrics
duration: ~40min
completed: 2026-07-03
---

# Phase 2 Plan 01: G1 Rendering Spike Summary

**Gate G1 resolved as a conditional PASS: LiquidGlass renders correctly on Android/Impeller (SM S921B device-verified); the flag is set to `true` on both platforms with a Plan 02-02 re-verify pending because the demotiles URL didn't load during the spike.**

## Performance

- **Duration:** ~40 min (spike screen implementation + Ralph Loop lint chase + device checkpoint + docs)
- **Started:** 2026-07-03 (execution)
- **Completed:** 2026-07-03
- **Tasks:** 4 completed (Tasks 1, 2 executed by initial agent; Task 3 human checkpoint; Task 4 by continuation)

## Accomplishments

- **`LiquidGlassSettings` singleton** at `lib/core/theme/liquid_glass_settings.dart` provides the G1 gate flag (`platformBlurEnabled`) plus shared visual params (`glassThickness=20`, `glassBlurSigma=12`, `glassSaturation=1.2`, `pillBorderRadius=28`, light/dark tint colors). Downstream 02-05 widgets branch on `LiquidGlassSettings.instance.platformSupportsBlurOverMap`.
- **`SpikeG1Screen`** at `lib/features/map/presentation/spike_g1_screen.dart` — three overlay pills over a `MapLibreMap` for side-by-side visual comparison (LiquidGlass / BackdropFilter / no-blur Fallback). Kept as a re-runnable diagnostic.
- **Real-device validation on Android (SM S921B, Impeller):** LiquidGlass shader compiles and renders correctly with visible refraction; BackdropFilter looked identical to the no-blur Fallback (confirms Flutter issue #185497 in the wild).
- **`docs/G1_SPIKE.md`** — full decision record with device info, observed behavior, caveats (map didn't load), SkSL warning explanation, and per-plan consequences.
- **`main.dart` wired at startup:** `LiquidGlassSettings.platformBlurEnabled = true;` runs after `WidgetsFlutterBinding.ensureInitialized()` — G1 outcome is visible at the app entry point.
- **`STATE.md`** logs the decision, both API deviations, and the two Plan 02-02 handoff todos (re-verify + demotiles).

## Task Commits

1. **Task 1: Add deps + LiquidGlassSettings singleton** — `4738096` (feat)
2. **Task 2: Build SpikeG1Screen visual harness** — `42ba1e1` (feat)
3. **Task 3: G1 checkpoint — real-device inspection** — human checkpoint (no commit; temporary main.dart bypass reverted in Task 4)
4. **Task 4a: Record G1 decision (docs/G1_SPIKE.md + STATE.md + spike header)** — `55c066c` (docs)
5. **Task 4b: Wire G1 gate at startup (main.dart)** — `7cb54f0` (feat)

**Plan metadata commit:** _to be filled after final commit_

## Files Created / Modified

- **`pubspec.yaml`** — Added `maplibre_gl: ^0.26.2` and `liquid_glass_renderer: 0.2.0-dev.4` (exact pin) in alphabetical order (`sort_pub_dependencies`). No transitive conflicts; `flutter pub get` clean.
- **`pubspec.lock`** — Regenerated with 7 new packages (maplibre_gl, maplibre_gl_platform_interface, maplibre_gl_web, liquid_glass_renderer, equatable, flutter_shaders, motor).
- **`lib/core/theme/liquid_glass_settings.dart`** — New singleton. Public static `platformBlurEnabled` (set once at startup), instance getter `platformSupportsBlurOverMap` for downstream widget code, plus shared visual params.
- **`lib/features/map/presentation/spike_g1_screen.dart`** — New. Three-pill overlay screen. Header comment marks it as "re-runnable diagnostic — not wired into router." Uses `import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lg` to avoid class-name collision.
- **`lib/main.dart`** — Added `LiquidGlassSettings.platformBlurEnabled = true;` between binding init and `runApp`; imports the settings module. All other Phase 1 setup (logging, error handlers, ProviderScope) preserved.
- **`docs/G1_SPIKE.md`** — New. Full decision record.
- **`.planning/STATE.md`** — Position → Phase 2; three new decisions logged; two new Plan 02-02 handoff todos; G1 blocker flipped to RESOLVED (conditional).

## Decisions Made

- **G1 outcome: PASS (conditional).** `platformBlurEnabled = true` on both platforms. Android device-verified on SM S921B / Impeller with user confirming the shader render is "perfect". iOS not device-tested — defaulted to `true` because `liquid_glass_renderer` is iOS-designed and inversion risk is low.
- **Re-verification hook in 02-02.** Because the `demotiles.maplibre.org` URL didn't load during the spike (amber Scaffold visible instead of tiles), the LiquidGlass render was validated over a solid background, not over a real MapLibre platform view. Plan 02-02 (bundled PMTiles + local style JSON) must re-verify at completion.
- **BackdropFilter is dead-on-arrival on Android.** The spike confirmed BackdropFilter looked identical to the no-blur Fallback, matching the research prediction from Flutter issue #185497 (OPEN). It won't be used in the glass shell.
- **API deviation — settings class.** The plan sketch proposed `LiquidGlassSettings.setPlatformSupportsBlurOverMap(value: <bool>)`. That form triggered `very_good_analysis` `use_setters_to_change_properties`, and converting to a setter triggered `avoid_setters_without_getters`, and wrapping the private field with a static getter/setter pair triggered `unnecessary_getters_setters`. Resolution: expose a public static field `platformBlurEnabled` (documented as "set once at startup") plus an instance getter `platformSupportsBlurOverMap` that reads it. Wire-up call is now `LiquidGlassSettings.platformBlurEnabled = true;`. Downstream read path (`LiquidGlassSettings.instance.platformSupportsBlurOverMap`) unchanged.
- **API deviation — LiquidShape borderRadius.** `LiquidRoundedSuperellipse(borderRadius: 28)` takes a `double` in `liquid_glass_renderer` 0.2.0-dev.4, not `Radius.circular(28)` as the plan sketch used. Corrected in `spike_g1_screen.dart` after reading the pub-cache source; downstream 02-05 code must use the same signature.
- **SpikeG1Screen retained.** Not deleted after the spike — kept as a re-runnable diagnostic for future Flutter/`liquid_glass_renderer` upgrades and for the Plan 02-02 re-verify.

## Deviations from Plan

- **[Rule 3 — Blocking] very_good_analysis lint cycle on the settings class.** As above; forced a small API rename. Nothing structural changed; the downstream read surface is identical.
- **[Rule 3 — Blocking] `LiquidRoundedSuperellipse.borderRadius: Radius` in the plan sketch was wrong** — the real API takes a `double`. Fixed inline.
- **[Auth gate — n/a] No authentication required for the spike.** Everything ran locally.
- **Note on the SkSL warnings during `flutter test`.** `impellerc` complains that `liquid_glass_renderer`'s three fragment shaders can't be transpiled to SkSL. These are host-only warnings — Flutter 3.44 defaults to Impeller on Android/iOS, so runtime is unaffected. No test currently exercises `LiquidGlassLayer` (headless Skia would silently render fake glass), so no test breakage. Documented in `docs/G1_SPIKE.md`.

## Verification

- `flutter analyze` — clean (0 issues) after every task commit.
- `flutter test` — 14/14 passing after final main.dart change.
- `flutter pub get` — clean; only 7 new packages added.
- Real-device install (Android SM S921B) — user confirmed LiquidGlass shader visual result.
- `docs/G1_SPIKE.md` contains `platformSupportsBlurOverMap` and `Plan 02-01` per the plan's verification checklist.
- `.planning/STATE.md` contains `Plan 02-01`.
- `main.dart` no longer references `SpikeG1Screen` (temporary bypass reverted).

## Next Phase Readiness

**Ready to start Plan 02-02 (MapLibre + PMTiles Integration)** with these carry-forwards:

- **G1 re-verify at end of 02-02.** Once the real PMTiles map is rendering, boot the app and confirm LiquidGlass still renders correctly over the platform view. If it fails, flip `platformBlurEnabled = false` and update `docs/G1_SPIKE.md`.
- **demotiles URL didn't load.** Track this as a separate follow-up in case it's a project-side network config issue, not just a Protomaps CDN blip.
- **Fallback code path** in `LiquidGlassSettings` stays as defensive code — if G1 flips to `false` in 02-02, no code needs to be rewritten, just the flag.

No blockers introduced. G1 is off the critical path unless 02-02 re-verify fails.
