---
plan: "02-04"
title: "Dark-mode style switching with fade crossfade"
phase: "02-map-glass-shell"
type: execute
wave: 4
depends_on: ["02-02", "02-03"]
files_modified:
  - lib/core/theme/app_theme.dart
  - lib/app.dart
  - lib/features/map/presentation/widgets/map_widget.dart      # extend brightness observer + fade
  - lib/features/map/presentation/widgets/map_style_fade.dart
  - lib/features/map/presentation/providers/map_style_provider.dart
  - test/features/map/map_style_provider_test.dart
autonomous: true

must_haves:
  truths:
    - "System theme change (light ↔ dark) triggers `controller.setStyle()` with the correct asset — no widget rebuild of `MapLibreMap` itself."
    - "The transition is a soft crossfade (opacity 0 → setStyle → opacity 1) — no visible white flash / no abrupt palette jump."
    - "`MaterialApp.router` uses `theme` + `darkTheme` + `themeMode: ThemeMode.system` so Flutter chrome (splash, onboarding) also follows system theme."
    - "`onStyleLoadedCallback` is used as the fade-back-in trigger — not a fixed timer."
    - "A widget test asserts `mapStyleProvider` selects the dark asset when platform brightness is dark and vice versa."
    - "`flutter analyze` and `flutter test` green."
  artifacts:
    - path: lib/core/theme/app_theme.dart
      provides: "Light + dark ThemeData for the Flutter chrome (matching map palettes)."
      contains: "class AppTheme"
    - path: lib/features/map/presentation/providers/map_style_provider.dart
      provides: "Derived provider — resolves current asset path from platform brightness."
      contains: "mapStyleAssetProvider"
    - path: lib/features/map/presentation/widgets/map_style_fade.dart
      provides: "Small helper widget wrapping MapLibreMap in AnimatedOpacity for crossfade."
      contains: "class MapStyleFade"
  key_links:
    - from: lib/features/map/presentation/widgets/map_widget.dart
      to: lib/features/map/presentation/providers/map_style_provider.dart
      via: "ref.watch(mapStyleAssetProvider) → passes to MapLibreMap.styleString"
      pattern: "mapStyleAssetProvider"
    - from: lib/features/map/presentation/widgets/map_widget.dart
      to: dart:ui.PlatformDispatcher.platformBrightness
      via: "WidgetsBindingObserver.didChangePlatformBrightness"
      pattern: "didChangePlatformBrightness"
    - from: lib/features/map/presentation/widgets/map_widget.dart
      to: (setStyle call)
      via: "controller.setStyle(newAsset) inside brightness observer"
      pattern: "controller.setStyle"
---

<objective>
When the system theme flips, the map style switches from `assets/map_style_light.json` to `assets/map_style_dark.json` (and vice versa) via `controller.setStyle()` — with a soft opacity crossfade rather than an abrupt render swap. The Flutter chrome (Material themes) also follows system brightness so splash + onboarding are consistent.

Purpose: Satisfies MAP-05 (auto dark mode) and UI-07 (light + dark themes share the same visual language). Non-abrupt transition per CONTEXT.md.
Output: A `WidgetsBindingObserver`-driven style swap, a `map_style_provider` that Riverpod widgets can watch, and Material `ThemeMode.system` on the app root.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/02-map-glass-shell/02-CONTEXT.md
@.planning/phases/02-map-glass-shell/02-RESEARCH.md
@lib/features/map/presentation/widgets/map_widget.dart
@lib/app.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: AppTheme + MaterialApp themeMode: system</name>
  <files>
    - lib/core/theme/app_theme.dart
    - lib/app.dart
  </files>
  <action>
    1. Create `lib/core/theme/app_theme.dart` with a light + dark `ThemeData` matching the map palettes:

       ```dart
       import 'package:flutter/material.dart';

       /// Flutter chrome themes. Colors mirror the map palettes so the
       /// splash + onboarding + glass overlays feel consistent when the
       /// system flips theme.
       class AppTheme {
         AppTheme._();

         // Light — warm off-white, matches assets/map_style_light.json bg.
         static ThemeData get light => ThemeData(
               brightness: Brightness.light,
               colorScheme: ColorScheme.fromSeed(
                 seedColor: const Color(0xFF3B7DD8), // trailblazer accent blue
                 brightness: Brightness.light,
               ).copyWith(
                 surface: const Color(0xFFF2F1EF),
               ),
               scaffoldBackgroundColor: const Color(0xFFF2F1EF),
               useMaterial3: true,
             );

         // Dark — deep navy, matches assets/map_style_dark.json bg.
         static ThemeData get dark => ThemeData(
               brightness: Brightness.dark,
               colorScheme: ColorScheme.fromSeed(
                 seedColor: const Color(0xFF3B7DD8),
                 brightness: Brightness.dark,
               ).copyWith(
                 surface: const Color(0xFF0A1728),
               ),
               scaffoldBackgroundColor: const Color(0xFF0A1728),
               useMaterial3: true,
             );
       }
       ```

    2. Update `lib/app.dart`:
       ```dart
       import 'package:auto_explore/core/routing/app_router.dart';
       import 'package:auto_explore/core/theme/app_theme.dart';
       import 'package:flutter/material.dart';
       import 'package:flutter_riverpod/flutter_riverpod.dart';

       class App extends ConsumerWidget {
         const App({super.key});

         @override
         Widget build(BuildContext context, WidgetRef ref) {
           final router = ref.watch(appRouterProvider);
           return MaterialApp.router(
             title: 'Trailblazer',
             theme: AppTheme.light,
             darkTheme: AppTheme.dark,
             themeMode: ThemeMode.system,
             routerConfig: router,
           );
         }
       }
       ```

    3. Verify existing widget tests still pass. `test/widget_test.dart` asserts the onboarding text renders — that's brightness-agnostic, should be fine.
  </action>
  <verify>
    ```
    flutter analyze
    flutter test
    ```
    Both green.
  </verify>
  <done>
    - `AppTheme.light` / `AppTheme.dark` exist.
    - `MaterialApp.router` uses `theme: AppTheme.light, darkTheme: AppTheme.dark, themeMode: ThemeMode.system`.
    - All existing tests still pass.
  </done>
</task>

<task type="auto">
  <name>Task 2: mapStyleAssetProvider (derived from platform brightness)</name>
  <files>
    - lib/features/map/presentation/providers/map_style_provider.dart
    - test/features/map/map_style_provider_test.dart
  </files>
  <action>
    1. Create `lib/features/map/presentation/providers/map_style_provider.dart`:

       The provider itself does NOT observe brightness — `MapWidget` will observe brightness via `WidgetsBindingObserver.didChangePlatformBrightness` and push updates. But we still want a single source of truth for the asset path so tests + external code can read the current style. Model as a plain `Notifier<String>` initialized from `PlatformDispatcher.instance.platformBrightness`:

       ```dart
       import 'dart:ui';

       import 'package:flutter/widgets.dart';
       import 'package:flutter_riverpod/flutter_riverpod.dart';

       const _lightAsset = 'assets/map_style_light.json';
       const _darkAsset = 'assets/map_style_dark.json';

       String assetForBrightness(Brightness b) =>
           b == Brightness.dark ? _darkAsset : _lightAsset;

       class MapStyleAssetNotifier extends Notifier<String> {
         @override
         String build() => assetForBrightness(
               PlatformDispatcher.instance.platformBrightness,
             );

         /// Called from MapWidget's WidgetsBindingObserver.
         void updateFromBrightness(Brightness b) {
           state = assetForBrightness(b);
         }
       }

       final mapStyleAssetProvider =
           NotifierProvider<MapStyleAssetNotifier, String>(
         MapStyleAssetNotifier.new,
       );
       ```

    2. Test `test/features/map/map_style_provider_test.dart`:
       - Assert `assetForBrightness(Brightness.light) == 'assets/map_style_light.json'`.
       - Assert `assetForBrightness(Brightness.dark) == 'assets/map_style_dark.json'`.
       - Container test: build a `ProviderContainer`, read `mapStyleAssetProvider`, then call `updateFromBrightness(Brightness.dark)` on the notifier and assert new state.
  </action>
  <verify>
    ```
    flutter test test/features/map/map_style_provider_test.dart
    flutter analyze lib/features/map/presentation/providers/
    ```
    Green.
  </verify>
  <done>
    - Provider file exists with `assetForBrightness` helper + notifier.
    - Test passes for both brightness values and manual update.
  </done>
</task>

<task type="auto">
  <name>Task 3: MapWidget observes brightness + fades style swap</name>
  <files>
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/presentation/widgets/map_style_fade.dart
  </files>
  <action>
    1. Create `lib/features/map/presentation/widgets/map_style_fade.dart` — a stateless helper wrapping its child in `AnimatedOpacity` driven by an external `bool visible`:
       ```dart
       import 'package:flutter/material.dart';

       /// Wraps its child in an AnimatedOpacity. Used by MapWidget to fade
       /// the map out before setStyle() and back in on onStyleLoadedCallback.
       class MapStyleFade extends StatelessWidget {
         const MapStyleFade({
           super.key,
           required this.visible,
           required this.child,
         });

         final bool visible;
         final Widget child;

         @override
         Widget build(BuildContext context) => AnimatedOpacity(
               opacity: visible ? 1.0 : 0.0,
               duration: const Duration(milliseconds: 180),
               curve: Curves.easeInOut,
               child: child,
             );
       }
       ```

    2. Extend `MapWidget` (already a ConsumerStatefulWidget from 02-03) to:
       - `with WidgetsBindingObserver` on the state class.
       - `initState` → `WidgetsBinding.instance.addObserver(this);`
       - `dispose` → remove observer + detach controller (already there from 02-03).
       - Override `didChangePlatformBrightness()`:
         ```dart
         @override
         void didChangePlatformBrightness() {
           super.didChangePlatformBrightness();
           final newBrightness =
               WidgetsBinding.instance.platformDispatcher.platformBrightness;
           _swapStyleWithFade(newBrightness);
         }
         ```
       - Add `_styleVisible` state (`bool`) initialized `true`; and `_pendingBrightness` (nullable).
       - Implementation of `_swapStyleWithFade`:
         ```dart
         Future<void> _swapStyleWithFade(Brightness b) async {
           final controller = ref.read(mapControllerProvider);
           if (controller == null) return; // no map yet; provider update alone is enough
           if (!mounted) return;
           setState(() { _styleVisible = false; });      // start fade-out
           await Future<void>.delayed(const Duration(milliseconds: 180));
           if (!mounted) return;
           ref.read(mapStyleAssetProvider.notifier).updateFromBrightness(b);
           final newAsset = ref.read(mapStyleAssetProvider);
           await controller.setStyle(newAsset);
           // onStyleLoadedCallback will call _onStyleLoaded which fades back in.
         }
         ```
       - `onStyleLoadedCallback` in `MapLibreMap(...)` calls `_onStyleLoaded()`:
         ```dart
         void _onStyleLoaded() {
           if (!mounted) return;
           setState(() { _styleVisible = true; });
           widget.onStyleLoaded?.call();
         }
         ```
       - Wrap the returned `MapLibreMap` in `MapStyleFade(visible: _styleVisible, child: MapLibreMap(...))`.
       - Pass `styleString: ref.watch(mapStyleAssetProvider)` — reading from the provider means widget test assertions from Task 2's provider stay valid.

    3. Anti-patterns to avoid (Pitfall 4 from research): after `setStyle()`, any programmatically-added layers/sources would need to be re-added inside `onStyleLoadedCallback`. Phase 2 has NO programmatic layers (all styling is inside the JSON), so this concern is dormant but comment it in code for Phase 7's future benefit:
       ```dart
       // NOTE: Phase 2 has no programmatic layers. If Phase 7+ adds
       // coverage sources via addSource(), they MUST be re-added inside
       // _onStyleLoaded() after setStyle() — the native map wipes all
       // programmatic sources on style reload.
       ```

    4. If the `MapWidget` widget test from 02-02 asserts `styleString == 'assets/map_style_light.json'`, update it to run under `PlatformDispatcher.instance.platformBrightness == Brightness.light` (usually the test default) and expect the light asset. Alternately, override the `mapStyleAssetProvider` in the test's ProviderScope to fix the value regardless of test-env brightness.
  </action>
  <verify>
    ```
    flutter analyze
    flutter test    # full suite; existing map_widget_test may need slight tweak
    ```
    Green.
  </verify>
  <done>
    - `MapWidget` observes brightness and fades style swaps.
    - `MapStyleFade` compiles.
    - Comment about programmatic-layer re-addition is present.
    - All tests pass.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` → 0 issues
- `flutter test` → all pre-existing + new tests green
- Manual (checked in 02-07 real-device verification): change system theme in device Settings while the map is open → observe crossfade + palette change, no abrupt reload / no visible white flash between styles.
</verification>

<success_criteria>
- MAP-05 (dark mode auto-switch) achievable end-to-end.
- UI-07 (shared visual language across themes) — Flutter chrome + map both flip on system theme change.
- Crossfade is smooth (180ms ease in/out).
- Pitfall 4 documented for Phase 7's benefit.
</success_criteria>

<deviations>
(Executor logs. Examples: adjustment to fade duration, whether `setStyle` returns a Future that resolves before or after `onStyleLoadedCallback`, ProviderScope overrides needed for tests.)
</deviations>

<output>
After completion, create `.planning/phases/02-map-glass-shell/02-04-SUMMARY.md`:
- Frontmatter: `subsystem: theming`, `affects: [02-05, 02-07]`, `requires: [02-02]`
- Notes: chosen fade duration, any peculiarities of setStyle timing on real hardware (defer real-device verification detail to 02-07).
</output>
