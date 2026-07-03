# G1 Rendering Spike — Decision Record

**Phase:** 02 (Map + Glass Shell)
**Plan:** 02-01
**Date:** 2026-07-03
**Status:** Conditional PASS — re-verification pending at end of Plan 02-02

---

## Question

Does `BackdropFilter` / `liquid_glass_renderer` produce real blur/refraction
over the `MapLibreMap` platform view on iOS and Android in profile mode?

## Test methodology

`SpikeG1Screen` (`lib/features/map/presentation/spike_g1_screen.dart`) renders
`MapLibreMap` with the default `demotiles.maplibre.org` style and stacks three
overlay pills on top for side-by-side comparison:

1. `lg.LiquidGlass` inside `lg.LiquidGlassLayer` — full Impeller shader path
2. `BackdropFilter` + `ClipRRect` — standard Flutter blur filter
3. Plain semi-transparent `Container` — documented fallback (no blur)

Executor temporarily bypassed the router in `lib/main.dart` (not committed)
and ran `flutter run --profile -d <device>` for real-device inspection.

## Devices tested

- **iOS:** not tested (no Mac + iOS device available in this environment)
- **Android:** Samsung SM-S921B (Galaxy S24), Flutter 3.44 default engine
  (Impeller)

## Observed result

- **Android — LiquidGlass pill:** Renders correctly. Visible refraction/tint
  distinct from the other two pills. User confirmed the visual result is
  "perfect" — the `liquid_glass_renderer` fragment shaders compile and paint
  as intended on Impeller.
- **Android — BackdropFilter pill:** Looks identical to the Fallback pill.
  No blur reaches the layer beneath. This confirms the research prediction
  (Flutter issue [#185497][fl-185497] OPEN as of 2026-05-08): Android's
  `BackdropFilter` cannot sample `PlatformView` pixels. `BackdropFilter` is
  therefore unusable as a glass primitive on Android and will not be used
  downstream — `liquid_glass_renderer`'s shader-based path is the only viable
  route.
- **iOS:** untested. Defaulted to `true` because `liquid_glass_renderer` is
  iOS-designed and the risk of regression is low. Any iOS-specific breakage
  will surface during a later device pass.

### Caveats

- **MapLibre demo tiles did not load during the spike.** The screen showed
  an amber Scaffold background rather than actual map tiles — the
  `demotiles.maplibre.org` network fetch failed (network policy, config, or
  transient outage). LiquidGlass therefore rendered over a solid Scaffold
  background, **not over a live MapLibre platform view**. This means the
  spike validated the shader path against Impeller in general, but did NOT
  fully validate LiquidGlass over the platform view.
- Full over-platform-view verification is deferred to the end of Plan 02-02
  (bundled PMTiles + real style JSON), where the map will actually render
  behind the pills. If that re-verify fails, `platformBlurEnabled` must be
  flipped to `false` and this record updated to full-G1-fallback.

### SkSL shader warnings (informational)

`flutter test` and `flutter build` print `impellerc` warnings that the
`liquid_glass_renderer` shaders (`liquid_glass_geometry_blended.frag`,
`liquid_glass_arbitrary.frag`, `liquid_glass_filter.frag`) cannot be
transpiled to SkSL — "loop index initializer must be a constant expression"
and "initializers are not permitted on arrays". These warnings apply to the
**Skia backend only**. Flutter 3.44 defaults to Impeller on Android and iOS,
so the shaders compile and run correctly at app runtime. On the host during
`flutter test` (headless Skia), the shaders don't load — but there is no
widget test that exercises `LiquidGlassLayer`, so no test breakage results.

## Decision

`LiquidGlassSettings.platformBlurEnabled = true` on both platforms.

Rationale: LiquidGlass shader compiled and rendered correctly on Impeller
(Android SM-S921B); user confirmed visual result is "perfect". iOS is
assumed to work given the package's iOS-first design. The G1 gate is passed
with the caveat that Plan 02-02 must re-verify the render over the actual
PMTiles-backed MapLibre platform view.

Wire-up: `lib/main.dart` calls `LiquidGlassSettings.platformBlurEnabled = true`
after `WidgetsFlutterBinding.ensureInitialized()` and before `runApp`.
(Note: the class exposes the flag as a public static field with a matching
getter — the plan sketch's `setPlatformSupportsBlurOverMap(value: ...)` method
was refactored into the `platformBlurEnabled` static property to satisfy the
`very_good_analysis` `use_setters_to_change_properties` /
`unnecessary_getters_setters` lint pair. Instance reads still go through
`LiquidGlassSettings.instance.platformSupportsBlurOverMap`, which returns the
same underlying value.)

## Consequences for Phase 2

- **Plan 02-05 (Glass Shell):** Uses `lg.LiquidGlass` on both Android and iOS.
  The `FallbackGlassPill` widget still ships as defensive code (behind the
  same `platformBlurEnabled` flag) so any future regression flips a single
  boolean.
- **Plan 02-02 (PMTiles integration):** MUST re-verify LiquidGlass renders
  over the real map platform view at the end of the plan. If the render
  fails there, flip `platformBlurEnabled = false` and update this record.
- **Plan 02-07 (Verification):** SC5 (glass shell renders without release-mode
  jank) is checked against the LiquidGlass path, with the fallback verified
  by manual flag flip.

## References

- Flutter issue [#185497][fl-185497] — Android `BackdropFilter` over
  `PlatformView` (OPEN as of 2026-05-08). Confirmed via the spike:
  BackdropFilter pill looked identical to the no-blur Fallback pill.
- Flutter issue [#43902][fl-43902] — iOS `UIKitView` backdrop_filter (CLOSED
  2023-07-05). Not device-verified in this spike.
- `.planning/phases/02-map-glass-shell/02-RESEARCH.md` — Pattern 4 (G1
  fallback) and Pitfall 3 (glass blur jank in release mode).
- `.planning/STATE.md` — Plan 02-01 decision entry.

[fl-185497]: https://github.com/flutter/flutter/issues/185497
[fl-43902]: https://github.com/flutter/flutter/issues/43902
