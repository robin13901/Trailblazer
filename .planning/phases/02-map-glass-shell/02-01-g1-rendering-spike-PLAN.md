---
plan: "02-01"
title: "G1 Rendering Spike — LiquidGlass over MapLibre on real devices"
phase: "02-map-glass-shell"
type: execute
wave: 1
depends_on: []
files_modified:
  - pubspec.yaml
  - lib/core/theme/liquid_glass_settings.dart
  - lib/features/map/presentation/spike_g1_screen.dart
  - docs/G1_SPIKE.md
  - .planning/STATE.md
autonomous: false   # requires human-verify checkpoint (real-device visual smoke test)

must_haves:
  truths:
    - "A binary decision `LiquidGlassSettings.platformSupportsBlurOverMap` is committed and reflects observed real-device behavior."
    - "`liquid_glass_renderer` 0.2.0-dev.4 is added to pubspec (exact pin) and `flutter pub get` succeeds."
    - "`docs/G1_SPIKE.md` records: device(s) tested, OS version, Impeller status, PASS/FAIL per platform, rationale for `platformSupportsBlurOverMap` value."
    - "Fallback rendering path (semi-transparent tint + border, no BackdropFilter over map) is scaffolded in `LiquidGlassSettings` so downstream plans can consume the flag."
    - "`flutter analyze` and `flutter test` remain green."
  artifacts:
    - path: lib/core/theme/liquid_glass_settings.dart
      provides: "Singleton with G1 gate flag + shared glass visual parameters."
      contains: "class LiquidGlassSettings"
    - path: lib/features/map/presentation/spike_g1_screen.dart
      provides: "Throwaway screen: MapLibreMap + LiquidGlass pill overlay for visual inspection."
      contains: "class SpikeG1Screen"
    - path: docs/G1_SPIKE.md
      provides: "Formal G1 gate decision record."
      contains: "# G1 Rendering Spike"
  key_links:
    - from: lib/core/theme/liquid_glass_settings.dart
      to: (downstream plans 02-05 glass shell + 02-07 verification)
      via: "static const `LiquidGlassSettings.instance.platformSupportsBlurOverMap`"
      pattern: "platformSupportsBlurOverMap"
    - from: docs/G1_SPIKE.md
      to: .planning/STATE.md
      via: "Decision logged in STATE.md Decisions section (Plan 02-01)"
      pattern: "Plan 02-01"
---

<objective>
Resolve **Gate G1** (from ROADMAP.md Phase Gates): does `BackdropFilter` / `liquid_glass_renderer` produce a real blur effect over the `MapLibreMap` platform view on iOS and Android in profile/release mode? Set the `LiquidGlassSettings.platformSupportsBlurOverMap` flag once, based on observed reality. All downstream Phase 2 glass work reads this flag; nothing else in Phase 2 or Phase 3+ should re-litigate this decision.

Purpose: Research (02-RESEARCH.md, cross-references Flutter issue #185497 OPEN as of 2026-05-08) says Android BackdropFilter over platform views is broken; iOS may work with Impeller but is unverified. We must not build the Liquid Glass shell (02-05) on wishful assumptions.
Output: A committed decision + fallback scaffolding + a spike screen that can be re-run any time we want to re-check.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/02-map-glass-shell/02-CONTEXT.md
@.planning/phases/02-map-glass-shell/02-RESEARCH.md
@.planning/research/PITFALLS.md
@pubspec.yaml
@lib/core/routing/app_router.dart
@lib/app.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add MapLibre + LiquidGlass deps; create LiquidGlassSettings singleton</name>
  <files>
    - pubspec.yaml
    - lib/core/theme/liquid_glass_settings.dart
  </files>
  <action>
    1. In `pubspec.yaml` `dependencies:` add (keep alphabetical per Phase 1 sort_pub_dependencies rule):
       ```yaml
       liquid_glass_renderer: 0.2.0-dev.4   # EXACT pin — dev release
       maplibre_gl: ^0.26.2
       ```
       Do NOT add `location` — MapLibre handles blue-dot natively; `permission_handler` (added in Plan 02-03) is sufficient. Do NOT add the `pmtiles` package — MapLibre's native engines handle the `pmtiles://` protocol.

    2. Run `flutter pub get`. If it fails, resolve version conflicts before proceeding (do NOT loosen the `liquid_glass_renderer` pin — it's a dev release and only 0.2.0-dev.4 is compatible with our Flutter 3.44 / Riverpod 3.3.2 stack per research).

    3. Create `lib/core/theme/liquid_glass_settings.dart`:
       ```dart
       import 'dart:ui';

       /// Shared visual + gate settings for all Liquid Glass chrome.
       ///
       /// The `platformSupportsBlurOverMap` flag is set by the Plan 02-01
       /// G1 rendering spike (see docs/G1_SPIKE.md). Downstream widgets
       /// (bottom nav pill, FAB, focus pill, settings button) branch on
       /// this flag: use `LiquidGlass` when true, use the fallback tinted
       /// container when false.
       class LiquidGlassSettings {
         const LiquidGlassSettings._();

         static const LiquidGlassSettings instance = LiquidGlassSettings._();

         /// G1 gate result. Default `false` = safe fallback path.
         /// Overridden after real-device validation (see docs/G1_SPIKE.md).
         bool get platformSupportsBlurOverMap => _platformSupportsBlurOverMap;

         // Mutable at test time only. In production this is set once at
         // app startup from a compile-time flag or a persisted G1 record.
         // Phase 2 keeps it as a plain mutable field on the singleton to
         // avoid over-engineering; Phase 3+ may lift it into a Provider.
         static bool _platformSupportsBlurOverMap = false;

         static void setPlatformSupportsBlurOverMap({required bool value}) {
           _platformSupportsBlurOverMap = value;
         }

         // Shared visual parameters (tuned per ui-ux-pro-max recommendations).
         double get glassThickness => 20;
         double get glassBlurSigma => 12;
         double get glassSaturation => 1.2;
         double get pillBorderRadius => 28;

         Color get lightGlassTint => const Color(0x38FFFFFF);
         Color get darkGlassTint => const Color(0x2A0A1728);
         Color get lightGlassBorder => const Color(0x59FFFFFF);
         Color get darkGlassBorder => const Color(0x40FFFFFF);
       }
       ```
    Rationale: singleton keeps the API surface tiny; a Provider would be over-engineered for a set-once flag. Method setter (not public field) prevents downstream code accidentally re-setting the flag on every rebuild.
  </action>
  <verify>
    ```
    flutter pub get
    flutter analyze
    ```
    Both must exit 0. `flutter analyze` must not warn about `liquid_glass_renderer` / `maplibre_gl` (they're not imported yet — that's fine).
  </verify>
  <done>
    - `pubspec.yaml` contains both new deps in alphabetical order.
    - `lib/core/theme/liquid_glass_settings.dart` exists and compiles.
    - `LiquidGlassSettings.instance.platformSupportsBlurOverMap` defaults to `false`.
  </done>
</task>

<task type="auto">
  <name>Task 2: Build the G1 spike screen (throwaway visual harness)</name>
  <files>
    - lib/features/map/presentation/spike_g1_screen.dart
  </files>
  <action>
    Create `lib/features/map/presentation/spike_g1_screen.dart` — a standalone screen that renders `MapLibreMap` (remote MapLibre demo style, no PMTiles yet) with THREE overlaid glass-candidate widgets side by side, so the human tester can compare on real hardware:

    Layout (top-to-bottom overlays, all centered horizontally over the map):
      1. `lg.LiquidGlass` pill (from `liquid_glass_renderer`) with label "LiquidGlass"
      2. `BackdropFilter(ImageFilter.blur(12, 12))` inside `ClipRRect` with a semi-transparent white tint, label "BackdropFilter"
      3. Semi-transparent tinted `Container` with white border, NO blur, label "Fallback (no blur)"

    IMPORTANT — name collision: our own `lib/core/theme/liquid_glass_settings.dart` exports `class LiquidGlassSettings`, and `package:liquid_glass_renderer` also exports its own `LiquidGlassSettings` type. Alias the renderer import with `as lg` and prefix every renderer type (`lg.LiquidGlass`, `lg.LiquidGlassLayer`, `lg.LiquidGlassSettings`, `lg.LiquidRoundedSuperellipse`, …) — matches the pattern 02-05 uses.

    Full sketch:
    ```dart
    import 'dart:ui' as ui;

    import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
    import 'package:flutter/material.dart';
    import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lg;
    import 'package:maplibre_gl/maplibre_gl.dart';

    /// One-off spike screen for Gate G1. NOT wired into the router.
    /// Manually navigate to it during the checkpoint (see Task 3).
    class SpikeG1Screen extends StatelessWidget {
      const SpikeG1Screen({super.key});

      @override
      Widget build(BuildContext context) {
        return Scaffold(
          body: Stack(
            children: [
              const MapLibreMap(
                // Remote demo style — no PMTiles work yet.
                styleString: 'https://demotiles.maplibre.org/style.json',
                initialCameraPosition: CameraPosition(
                  target: LatLng(52.52, 13.40), // Berlin
                  zoom: 12,
                ),
                tiltGesturesEnabled: false,
                compassEnabled: true,
              ),
              // Row of three candidate overlays, stacked vertically over map.
              const Positioned(
                top: 80, left: 20, right: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _LiquidGlassCandidate(),
                    SizedBox(height: 12),
                    _BackdropFilterCandidate(),
                    SizedBox(height: 12),
                    _FallbackCandidate(),
                  ],
                ),
              ),
              // Diagnostic footer.
              Positioned(
                bottom: 32, left: 20, right: 20,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.black87,
                  child: const Text(
                    'G1 spike — compare blur/frost quality across the three overlays.\n'
                    'On Android, BackdropFilter is expected to look identical to Fallback '
                    '(no blur). If it does, set platformSupportsBlurOverMap = false.',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }

    class _LiquidGlassCandidate extends StatelessWidget {
      const _LiquidGlassCandidate();
      @override
      Widget build(BuildContext context) {
        // Use liquid_glass_renderer's LiquidGlass widget with sensible defaults.
        // Reference: pub.dev/packages/liquid_glass_renderer 0.2.0-dev.4 README.
        // NOTE: All renderer types are prefixed `lg.` to avoid colliding with
        // our own `LiquidGlassSettings` class from
        // `package:auto_explore/core/theme/liquid_glass_settings.dart`.
        return lg.LiquidGlassLayer(
          settings: lg.LiquidGlassSettings(thickness: 20, blur: 12),
          child: const lg.LiquidGlass(
            shape: lg.LiquidRoundedSuperellipse(borderRadius: Radius.circular(28)),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Center(child: Text('LiquidGlass',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            ),
          ),
        );
      }
    }

    class _BackdropFilterCandidate extends StatelessWidget {
      const _BackdropFilterCandidate();
      @override
      Widget build(BuildContext context) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.28),
                border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 0.5),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Center(child: Text('BackdropFilter',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            ),
          ),
        );
      }
    }

    class _FallbackCandidate extends StatelessWidget {
      const _FallbackCandidate();
      @override
      Widget build(BuildContext context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 0.5),
            borderRadius: BorderRadius.circular(28),
          ),
          child: const Center(child: Text('Fallback (no blur)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        );
      }
    }
    ```

    Constraints:
    - Import the actual `LiquidGlass` / `LiquidGlassSettings` types from `liquid_glass_renderer` (via the `lg` alias) — check the package's exports before hard-coding class names; if the API surface differs from the sketch above, adapt (real API > the sketch). Use `flutter pub deps` + reading `.pub-cache/hosted/pub.dev/liquid_glass_renderer-0.2.0-dev.4/lib/` if unsure.
    - Do NOT wire this into `app_router.dart`. This is a throwaway screen. Instead, in Task 3, temporarily bypass the router for the checkpoint.
    - Do NOT use `MapLibreMap.useHybridComposition = true` — 02-RESEARCH.md Pitfall 2 confirms it's broken.
    - Do NOT enable `myLocationEnabled` here — we're not testing location yet (that's 02-03), and it would prompt permission on first launch and pollute the spike.
    - Use `withValues(alpha: ...)` per very_good_analysis (avoid deprecated `withOpacity`).
  </action>
  <verify>
    ```
    flutter analyze
    flutter build apk --debug   # or `flutter build ios --debug --no-codesign` on macOS
    ```
    Both must succeed. Widget test suite (`flutter test`) must remain green — the spike screen is not in the router, so no widget tests reference it yet.
  </verify>
  <done>
    - `lib/features/map/presentation/spike_g1_screen.dart` exists.
    - Debug build succeeds on the local target platform.
    - Ralph Loop passes: `flutter analyze` green, `flutter test` green.
  </done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 3: G1 checkpoint — real-device inspection + decision</name>
  <what-built>
    A `SpikeG1Screen` with three overlays over a MapLibre demo map: LiquidGlass, BackdropFilter, and a no-blur fallback. Comparison determines whether real blur is actually reaching the pixels above the platform view on each platform.
  </what-built>
  <how-to-verify>
    Executor: BEFORE this checkpoint, temporarily edit `lib/main.dart` (or `lib/app.dart`) to bypass the router and show `SpikeG1Screen` directly. Do NOT commit that change — revert it after the checkpoint.

    Suggested temporary main:
    ```dart
    // TEMPORARY — revert before commit
    void main() => runApp(const MaterialApp(home: SpikeG1Screen()));
    ```

    Then instruct the human tester (the user) as follows:

    1. Install the app on a real Android device in **profile mode**:
       `flutter run --profile -d <android-device-id>`
       Open the screen, pan/zoom the map behind the three overlays.
    2. Observe:
       - Does the **LiquidGlass** pill show a visibly different (blurred/refracted) view of the map behind it, distinct from the flat Fallback?
       - Does the **BackdropFilter** pill show real blur, or does it look identical to the Fallback?
    3. Repeat on a real iOS device if available (`flutter run --profile -d <ios-device-id>`).
    4. Take a screenshot of each platform's result.
    5. Report back with one of:
       - `iOS: blur works, Android: blur works` → `platformSupportsBlurOverMap = true` on both
       - `iOS: blur works, Android: no blur` → `platformSupportsBlurOverMap = true` on iOS only
       - `iOS: no blur, Android: no blur` → `platformSupportsBlurOverMap = false` (default fallback)
       - Any other combination

    Expected per research: Android will show no blur (LiquidGlass and BackdropFilter both look flat, identical to Fallback). iOS is uncertain — Impeller may composite the platform view into the Flutter layer tree, in which case blur will work.
  </how-to-verify>
  <resume-signal>
    Report back in the form:
    ```
    iOS: <blur|no-blur|not-tested>, device: <model + iOS version>
    Android: <blur|no-blur|not-tested>, device: <model + Android version>
    Screenshots: <paths or attached>
    ```
    Or type `approved (default fallback)` to accept the research-based default (`platformSupportsBlurOverMap = false` on both) without device testing — noting that this locks in the fallback path.
  </resume-signal>
</task>

<task type="auto">
  <name>Task 4: Record G1 decision + revert spike wiring + STATE.md log</name>
  <files>
    - docs/G1_SPIKE.md
    - lib/core/theme/liquid_glass_settings.dart
    - .planning/STATE.md
    - lib/main.dart   # revert any temporary bypass
  </files>
  <action>
    1. Write `docs/G1_SPIKE.md`:
       ```markdown
       # G1 Rendering Spike — Decision Record

       **Phase:** 02 (Map + Glass Shell)
       **Plan:** 02-01
       **Date:** {today}

       ## Question
       Does `BackdropFilter` / `liquid_glass_renderer` produce real blur over
       the `MapLibreMap` platform view on iOS and Android in profile mode?

       ## Test methodology
       `SpikeG1Screen` renders `MapLibreMap` (demo style) with three overlays:
       LiquidGlass pill, BackdropFilter+ClipRRect pill, and a no-blur tinted
       fallback pill. Real-device comparison.

       ## Devices tested
       - iOS: {device model + OS version, or "not tested"}
       - Android: {device model + OS version, or "not tested"}

       ## Result
       - iOS blur over map: **{yes|no|untested}**
       - Android blur over map: **{yes|no|untested}**

       ## Decision
       `LiquidGlassSettings.platformSupportsBlurOverMap = {true|false}`

       Rationale: {one-sentence rationale citing the observed result or the
       Flutter issue #185497 for Android.}

       ## Consequences for Phase 2
       - Plan 02-05 (Glass Shell): {"Uses LiquidGlass on <platforms>, FallbackGlassPill on <platforms>." — fill in based on decision}
       - Plan 02-07 (Verification): success criterion SC5 checks against the fallback path.

       ## References
       - Flutter issue #185497 (Android BackdropFilter over PlatformViews — OPEN as of 2026-05-08)
       - Flutter issue #43902 (iOS UIKitView backdrop_filter — CLOSED 2023)
       - 02-RESEARCH.md Pattern 4 + Pitfall 3
       ```

    2. Update `lib/core/theme/liquid_glass_settings.dart`:
       - If the human confirmed blur works on some platform, add a `platformSupportsBlurOverMapFor(TargetPlatform)` helper that returns the right value per-platform. If uniform (both true or both false), keep the single flag but call `LiquidGlassSettings.setPlatformSupportsBlurOverMap(value: <result>)` inside `App.build` (or `main()` after `WidgetsFlutterBinding.ensureInitialized()`).
       - Preferred pattern: `main.dart` calls `LiquidGlassSettings.setPlatformSupportsBlurOverMap(value: <computed>)` once at startup, using `defaultTargetPlatform` from `package:flutter/foundation.dart` to branch iOS vs Android based on the G1 result.

    3. Revert `lib/main.dart` back to the normal `runApp(ProviderScope(child: App()))` entry point. Verify the spike screen bypass is fully removed.

    4. Append to `.planning/STATE.md` under `### Decisions`:
       ```
       - **Plan 02-01 ({today}):** G1 gate resolved — `LiquidGlassSettings.platformSupportsBlurOverMap = {value}` (iOS: {result}, Android: {result}). Full record in `docs/G1_SPIKE.md`. Downstream glass shell (02-05) branches on this flag.
       ```

    5. Do NOT delete `spike_g1_screen.dart` yet — it stays as a re-runnable diagnostic. Add a `// SPIKE SCREEN — not wired into router; see docs/G1_SPIKE.md` header comment.
  </action>
  <verify>
    ```
    flutter analyze
    flutter test
    grep -q 'platformSupportsBlurOverMap' docs/G1_SPIKE.md
    grep -q 'Plan 02-01' .planning/STATE.md
    ```
    All must pass; `main.dart` must not reference `SpikeG1Screen`.
  </verify>
  <done>
    - `docs/G1_SPIKE.md` records the decision.
    - `LiquidGlassSettings._platformSupportsBlurOverMap` is set at startup to match the decision.
    - `lib/main.dart` restored to `ProviderScope(child: App())`.
    - `.planning/STATE.md` updated.
    - Ralph Loop green: `flutter analyze` + `flutter test` pass.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` → 0 issues
- `flutter test` → all pre-existing tests still green
- `flutter build apk --debug` succeeds (or iOS equivalent)
- `docs/G1_SPIKE.md` exists and contains a decision line for `platformSupportsBlurOverMap`
- `SpikeG1Screen` compiles and remains present as a re-runnable diagnostic (unwired)
- `LiquidGlassSettings.instance.platformSupportsBlurOverMap` is set at startup consistent with the recorded decision
</verification>

<success_criteria>
- G1 gate decision is a concrete boolean (per platform) committed to source (`docs/G1_SPIKE.md` + `LiquidGlassSettings`).
- Downstream plans 02-05 / 02-07 can read `LiquidGlassSettings.instance.platformSupportsBlurOverMap` without further decision-making.
- No production code path silently regresses (spike bypass in `main.dart` removed).
</success_criteria>

<deviations>
(Executor fills in during Ralph Loop iterations. Examples: real `liquid_glass_renderer` API surface differs from the sketch; iOS device unavailable so decision was made research-based; etc.)
</deviations>

<output>
After completion, create `.planning/phases/02-map-glass-shell/02-01-SUMMARY.md` following the summary template with:
- G1 decision (per platform + rationale)
- `docs/G1_SPIKE.md` path
- Any deviations from the plan sketch (e.g. LiquidGlass API adjustments)
- Frontmatter: `subsystem: rendering`, `affects: [02-05, 02-07]`, `tech-stack.added: [maplibre_gl 0.26.2, liquid_glass_renderer 0.2.0-dev.4]`
</output>
</output>
