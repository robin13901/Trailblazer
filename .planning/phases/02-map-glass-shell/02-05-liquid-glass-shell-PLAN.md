---
plan: "02-05"
title: "Liquid Glass shell — bottom pill nav, FAB stub, focus pill stub, settings button"
phase: "02-map-glass-shell"
type: execute
wave: 5
depends_on: ["02-01", "02-02", "02-03", "02-04"]
files_modified:
  - lib/features/map/presentation/widgets/glass_pill.dart
  - lib/features/map/presentation/widgets/glass_circle.dart
  - lib/features/map/presentation/widgets/focus_area_pill.dart
  - lib/features/map/presentation/widgets/trip_fab.dart
  - lib/features/map/presentation/widgets/settings_glass_button.dart
  - lib/features/map/presentation/widgets/bottom_nav_shell.dart
  - lib/features/map/presentation/map_screen.dart              # extend — add chrome overlays
  - lib/features/map/presentation/widgets/recenter_button.dart # optional re-skin as glass
  - test/features/map/glass_pill_test.dart
  - test/features/map/glass_shell_layout_test.dart
autonomous: true

must_haves:
  truths:
    - "Every chrome element (bottom nav pill, FAB stub, focus-area pill stub, top-left settings button) branches on `LiquidGlassSettings.instance.platformSupportsBlurOverMap` — using `LiquidGlass` when the G1 spike said the platform supports it, and a semi-transparent tinted `Container` (no BackdropFilter over the map) when it doesn't."
    - "Bottom pill has exactly 3 tabs: Map / Trips / Regions (Settings is NOT in the pill — it's a separate top-left glass button)."
    - "FAB stub (bottom-right) taps show a SnackBar 'Coming in Phase 3' — does NOT crash, does not start a trip."
    - "Focus-area pill (top-center) shows the placeholder text `—` and does nothing on tap — Phase 8 wires it."
    - "Settings button (top-left) is a small glass circle with a gear icon; taps are a no-op or open a placeholder route (Phase 10 wires it)."
    - "There is NO `AppBar` anywhere on the map screen (UI-06 mandate)."
    - "Widget tests exercise the light + dark rendering of the glass pill and the fallback path (no crash when `platformSupportsBlurOverMap = false`)."
    - "`flutter analyze` + `flutter test` green."
  artifacts:
    - path: lib/features/map/presentation/widgets/glass_pill.dart
      provides: "GlassPill widget — branches on LiquidGlassSettings.platformSupportsBlurOverMap to render either LiquidGlass or the fallback tinted pill."
      contains: "class GlassPill"
    - path: lib/features/map/presentation/widgets/glass_circle.dart
      provides: "GlassCircle — round glass container for FAB + settings button."
      contains: "class GlassCircle"
    - path: lib/features/map/presentation/widgets/focus_area_pill.dart
      provides: "Stub focus-area pill showing `—`."
      contains: "class FocusAreaPill"
    - path: lib/features/map/presentation/widgets/trip_fab.dart
      provides: "Stub FAB — bottom-right, tap shows SnackBar."
      contains: "class TripFab"
    - path: lib/features/map/presentation/widgets/settings_glass_button.dart
      provides: "Top-left glass button leading to Settings route."
      contains: "class SettingsGlassButton"
    - path: lib/features/map/presentation/widgets/bottom_nav_shell.dart
      provides: "3-tab glass bottom pill — hosts the StatefulNavigationShell in 02-06."
      contains: "class BottomNavShell"
  key_links:
    - from: lib/features/map/presentation/widgets/glass_pill.dart
      to: lib/core/theme/liquid_glass_settings.dart
      via: "reads LiquidGlassSettings.instance.platformSupportsBlurOverMap"
      pattern: "platformSupportsBlurOverMap"
    - from: lib/features/map/presentation/map_screen.dart
      to: (all chrome widgets above)
      via: "Stack overlays over MapWidget"
      pattern: "Stack"
    - from: lib/features/map/presentation/widgets/bottom_nav_shell.dart
      to: (Plan 02-06 StatefulNavigationShell)
      via: "accepts a `navigationShell` param + `onTap(int)`; 02-06 wires the shell in"
      pattern: "navigationShell"
---

<objective>
Build the Phase-2 Liquid Glass chrome that overlays the map: a top-left settings button, a top-center focus-area pill stub, a bottom-right FAB stub, and a bottom 3-tab nav pill. Every glass component branches at build time on the G1 spike result (`LiquidGlassSettings.platformSupportsBlurOverMap`) so no chrome relies on BackdropFilter working over the map on Android.

Purpose: Satisfies UI-01 (focus pill placeholder), UI-02 (bottom nav pill — 3 tabs per CONTEXT.md), UI-03 (glass FAB), UI-04 (glass overlays), UI-06 (no AppBar), UI-07 (light + dark parity). This is the pure widget layer — router wiring happens in 02-06.
Output: A set of reusable glass widgets + a laid-out `MapScreen` with all four chrome elements on top of the base map.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/02-map-glass-shell/02-CONTEXT.md
@.planning/phases/02-map-glass-shell/02-RESEARCH.md
@.planning/phases/02-map-glass-shell/02-01-g1-rendering-spike-PLAN.md
@lib/core/theme/liquid_glass_settings.dart
@lib/features/map/presentation/widgets/map_widget.dart
@lib/features/map/presentation/map_screen.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: Base glass primitives (GlassPill + GlassCircle) branching on G1 flag</name>
  <files>
    - lib/features/map/presentation/widgets/glass_pill.dart
    - lib/features/map/presentation/widgets/glass_circle.dart
    - test/features/map/glass_pill_test.dart
  </files>
  <action>
    1. `pubspec.yaml`: Do NOT add `liquid_navbar` — we're building our own 3-tab pill (CONTEXT.md is explicit: bottom pill with 3 tabs Map/Trips/Regions, Settings out; `liquid_navbar` is overkill and adds a nested Riverpod state we don't need). `liquid_glass_renderer` was already added in 02-01.

    2. Create `lib/features/map/presentation/widgets/glass_pill.dart`:
       ```dart
       import 'dart:ui' as ui;

       import 'package:auto_explore/core/theme/liquid_glass_settings.dart';
       import 'package:flutter/material.dart';
       import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lg;

       /// Rounded glass "pill" container. Branches on G1 flag:
       ///  - If the platform supports blur over the map view (per the
       ///    Plan 02-01 spike), render a real `lg.LiquidGlass`.
       ///  - Otherwise render a semi-transparent tinted container with
       ///    a hairline border — the documented G1 fallback.
       class GlassPill extends StatelessWidget {
         const GlassPill({
           super.key,
           required this.child,
           this.padding = const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
           this.borderRadius,
         });

         final Widget child;
         final EdgeInsetsGeometry padding;
         final double? borderRadius;

         @override
         Widget build(BuildContext context) {
           final settings = LiquidGlassSettings.instance;
           final radius = borderRadius ?? settings.pillBorderRadius;
           final isDark = Theme.of(context).brightness == Brightness.dark;
           final tint = isDark ? settings.darkGlassTint : settings.lightGlassTint;
           final border = isDark ? settings.darkGlassBorder : settings.lightGlassBorder;

           if (settings.platformSupportsBlurOverMap) {
             return lg.LiquidGlass(
               shape: lg.LiquidRoundedSuperellipse(borderRadius: Radius.circular(radius)),
               child: Padding(padding: padding, child: child),
             );
           }
           return _FallbackTintedPill(
             padding: padding,
             borderRadius: radius,
             tint: tint,
             borderColor: border,
             child: child,
           );
         }
       }

       class _FallbackTintedPill extends StatelessWidget {
         const _FallbackTintedPill({
           required this.child,
           required this.padding,
           required this.borderRadius,
           required this.tint,
           required this.borderColor,
         });

         final Widget child;
         final EdgeInsetsGeometry padding;
         final double borderRadius;
         final Color tint;
         final Color borderColor;

         @override
         Widget build(BuildContext context) {
           // Deliberately NOT using BackdropFilter here.
           // Reason: Flutter issue #185497 (OPEN) — BackdropFilter over
           // MapLibre platform view on Android produces no blur. Falling
           // back to a solid tint + border is the documented Phase-2
           // fallback (see docs/G1_SPIKE.md).
           return Container(
             padding: padding,
             decoration: BoxDecoration(
               color: tint,
               border: Border.all(color: borderColor, width: 0.5),
               borderRadius: BorderRadius.circular(borderRadius),
               boxShadow: const [
                 BoxShadow(
                   color: Color(0x25000000),
                   blurRadius: 12,
                   offset: Offset(0, 4),
                 ),
               ],
             ),
             child: child,
           );
         }
       }
       ```

    3. Create `lib/features/map/presentation/widgets/glass_circle.dart` — same pattern as `GlassPill`, but circular. Take a `size` and an optional `borderRadius: size / 2`. Same G1 branching.

    4. Test `test/features/map/glass_pill_test.dart`:
       - Pump `GlassPill(child: Text('X'))` in light theme with `LiquidGlassSettings.setPlatformSupportsBlurOverMap(value: false)` → assert `_FallbackTintedPill` is in the tree (import the private class via `library_private_types_in_public_api` if needed — or expose a public marker widget `GlassPillFallback`).
       - Repeat with `value: true` → assert `lg.LiquidGlass` is in the tree.
       - Pump under `MediaQuery(data: MediaQueryData(platformBrightness: Brightness.dark), ...)` and assert the container `color` uses the dark tint.
       - Cleanup: reset `setPlatformSupportsBlurOverMap(value: false)` in `tearDown`.

    Verify the actual `liquid_glass_renderer` 0.2.0-dev.4 API — if `LiquidRoundedSuperellipse` isn't the correct shape name, use whatever the package exports. If `LiquidGlassLayer` needs to wrap `LiquidGlass`, wrap it. Real API > sketch.
  </action>
  <verify>
    ```
    flutter analyze lib/features/map/presentation/widgets/
    flutter test test/features/map/glass_pill_test.dart
    ```
    Green.
  </verify>
  <done>
    - `GlassPill` + `GlassCircle` compile and branch on the G1 flag.
    - Fallback uses NO BackdropFilter.
    - Widget tests cover both branches + both brightnesses.
  </done>
</task>

<task type="auto">
  <name>Task 2: Chrome widgets — FocusAreaPill, SettingsGlassButton, TripFab, BottomNavShell</name>
  <files>
    - lib/features/map/presentation/widgets/focus_area_pill.dart
    - lib/features/map/presentation/widgets/settings_glass_button.dart
    - lib/features/map/presentation/widgets/trip_fab.dart
    - lib/features/map/presentation/widgets/bottom_nav_shell.dart
  </files>
  <action>
    1. `focus_area_pill.dart` — small `GlassPill` centered horizontally at the top; shows a placeholder `—`. No tap handler in Phase 2 (Phase 8 wires it). Semantics label: "Focus area (not yet available)".
       ```dart
       class FocusAreaPill extends StatelessWidget {
         const FocusAreaPill({super.key});
         @override
         Widget build(BuildContext context) {
           return const Semantics(
             label: 'Focus area (not yet available)',
             child: GlassPill(
               padding: EdgeInsets.symmetric(vertical: 10, horizontal: 18),
               child: Text('—', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
             ),
           );
         }
       }
       ```

    2. `settings_glass_button.dart` — `GlassCircle(size: 44)` with a gear icon (`Icons.settings_outlined`). Tap → `context.go('/settings')` (route added as a stub in Plan 02-06). If 02-06 isn't done yet during dev, tap is a no-op that logs at info; the go call is safe because `app_router.dart` will contain the route by the time this plan's tests run (waves ensure 02-05 runs before 02-06 in-plan tests, but 02-06 adds the route — coordinate via the shared route path being stable, and gate the tap: `if (GoRouter.of(context).routeInformationProvider.value.uri.path != '/settings')`). Simpler solution: for Phase 2, the settings button just shows a SnackBar "Settings coming in Phase 10" — matches the FAB stub pattern. Adopt this.

    3. `trip_fab.dart` — `GlassCircle(size: 60)` bottom-right positioned; tap → `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Trip recording is coming in Phase 3')))`. Icon: `Icons.fiber_manual_record` (matches "record" affordance). Wrap in `Semantics(label: 'Start trip — not yet available')`.

    4. `bottom_nav_shell.dart` — a **pure widget** taking:
       ```dart
       BottomNavShell({
         required int currentIndex,
         required ValueChanged<int> onTap,
       })
       ```
       Renders a `GlassPill` (wider — override `padding`) containing a `Row` of 3 tap targets (icons + labels stacked vertically). Selected tab shows an accent-colored indicator dot / underline; unselected tabs are muted.

       Tabs:
       - `0`: `Icons.map_outlined` / "Map"
       - `1`: `Icons.route` / "Trips"
       - `2`: `Icons.flag_outlined` / "Regions"

       No Settings tab (CONTEXT.md).

       Bottom-safe area padding: wrap the pill in `SafeArea(bottom: true)` with an `EdgeInsets.only(bottom: 12)` extra margin.

       Do NOT hardcode the state — accept `currentIndex` + `onTap`. Plan 02-06 wires it to `StatefulNavigationShell`.

    5. All widgets follow Phase 1 style: package imports, `withValues(alpha: ...)`, no `withOpacity`, no `late` unless necessary.
  </action>
  <verify>
    ```
    flutter analyze lib/features/map/presentation/widgets/
    ```
    Zero issues.
  </verify>
  <done>
    - Four widgets exist and compile.
    - No BackdropFilter usage outside `_FallbackTintedPill` guard (which we've NOT added — the fallback deliberately has no BackdropFilter over map).
    - Tap handlers are safe stubs.
  </done>
</task>

<task type="auto">
  <name>Task 3: MapScreen composes chrome + widget test for full shell layout</name>
  <files>
    - lib/features/map/presentation/map_screen.dart
    - test/features/map/glass_shell_layout_test.dart
  </files>
  <action>
    1. Rewrite `lib/features/map/presentation/map_screen.dart` to a Stack composition:
       ```dart
       import 'package:auto_explore/features/map/presentation/widgets/bottom_nav_shell.dart';
       import 'package:auto_explore/features/map/presentation/widgets/focus_area_pill.dart';
       import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
       import 'package:auto_explore/features/map/presentation/widgets/recenter_button.dart';
       import 'package:auto_explore/features/map/presentation/widgets/settings_glass_button.dart';
       import 'package:auto_explore/features/map/presentation/widgets/trip_fab.dart';
       import 'package:flutter/material.dart';
       import 'package:flutter_riverpod/flutter_riverpod.dart';

       /// Phase-2 Map screen — chrome overlays on top of the base MapWidget.
       ///
       /// This widget accepts an optional [bottomNav] override so that
       /// Plan 02-06 can inject the StatefulNavigationShell-driven pill.
       /// If null (as in Phase 2 pre-06), a self-managed [_LocalBottomNav]
       /// is used so the screen is testable standalone.
       class MapScreen extends ConsumerWidget {
         const MapScreen({super.key, this.bottomNav});

         /// Optional pre-wired bottom nav (from StatefulNavigationShell).
         final Widget? bottomNav;

         @override
         Widget build(BuildContext context, WidgetRef ref) {
           return Scaffold(
             // UI-06: no AppBar.
             body: Stack(
               children: [
                 const Positioned.fill(child: MapWidget()),

                 // Top-left settings button.
                 const Positioned(
                   top: 44, left: 16,
                   child: SafeArea(child: SettingsGlassButton()),
                 ),

                 // Top-center focus pill.
                 const Positioned(
                   top: 44, left: 0, right: 0,
                   child: SafeArea(child: Center(child: FocusAreaPill())),
                 ),

                 // Bottom-right recenter (from 02-03) + FAB stub.
                 const Positioned(
                   right: 16, bottom: 110,
                   child: RecenterButton(),
                 ),
                 const Positioned(
                   right: 16, bottom: 40,
                   child: TripFab(),
                 ),

                 // Bottom nav pill — injectable for 02-06.
                 Positioned(
                   left: 16, right: 16, bottom: 16,
                   child: bottomNav ?? const _LocalBottomNav(),
                 ),
               ],
             ),
           );
         }
       }

       /// Phase-2 self-managed 3-tab pill. In 02-06 this is replaced by a
       /// pill wired to StatefulNavigationShell.currentIndex + goBranch().
       class _LocalBottomNav extends StatefulWidget {
         const _LocalBottomNav();
         @override
         State<_LocalBottomNav> createState() => _LocalBottomNavState();
       }

       class _LocalBottomNavState extends State<_LocalBottomNav> {
         int _index = 0;
         @override
         Widget build(BuildContext context) => BottomNavShell(
               currentIndex: _index,
               onTap: (i) => setState(() { _index = i; }),
             );
       }
       ```

    2. Widget test `test/features/map/glass_shell_layout_test.dart` — pumps `MapScreen` and asserts:
       - Exactly one `FocusAreaPill` present.
       - Exactly one `SettingsGlassButton` present.
       - Exactly one `TripFab` present.
       - Exactly one `BottomNavShell` present.
       - `Scaffold.appBar` is null (UI-06).
       - Tap on `TripFab` shows a SnackBar containing "Phase 3".
       - Tap on `BottomNavShell`'s "Trips" tab → currentIndex updates (either via `_LocalBottomNav`'s state or via a pumped Consumer if you switched to a Notifier).

       Wrap the pump in `ProviderScope` (needed for downstream providers even if MapScreen itself doesn't consume them yet — MapWidget does). Override `mapControllerProvider` / `locationPermissionProvider` with values that avoid needing platform channels. If tests still hit platform channels, mock `MapLibreMap` via a test-only conditional wrapper — but prefer keeping the real widget tree and mocking channels.
  </action>
  <verify>
    ```
    flutter analyze
    flutter test test/features/map/
    flutter test    # full suite
    ```
    Green.
  </verify>
  <done>
    - `MapScreen` is a Stack with 5 chrome overlays over the map.
    - No `AppBar`.
    - Widget test covers presence + FAB SnackBar + tab switch.
    - Bottom nav is injectable via `bottomNav` param for Plan 02-06.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` → 0 issues
- `flutter test` → all pre-existing + new tests green
- Manual (checked in 02-07 real-device verification): install debug build, navigate to `MapScreen` (Plan 02-06 will add the route; before that, temporarily launch `MapScreen` directly via a debug entry point) — confirm on real Android device: no crash, no jank, no BackdropFilter used over map, chrome renders correctly in both light and dark themes.
</verification>

<success_criteria>
- UI-01 focus pill stub renders.
- UI-02 bottom nav pill renders with 3 tabs (Map / Trips / Regions), Settings NOT in the pill.
- UI-03 FAB stub renders bottom-right, tap → SnackBar.
- UI-04 overlay panels use the glass system (glass_pill / glass_circle).
- UI-05 G1 gate honored — chrome branches on `LiquidGlassSettings.platformSupportsBlurOverMap`, fallback path uses NO BackdropFilter over map.
- UI-06 no AppBar.
- UI-07 light + dark both render.
- Bottom nav decoupled from routing state (Plan 02-06 injects the shell).
</success_criteria>

<deviations>
(Executor logs. Examples: actual liquid_glass_renderer widget names, tweaks to glass palette, whether RecenterButton was re-skinned as glass or left as-is from 02-03.)
</deviations>

<output>
After completion, create `.planning/phases/02-map-glass-shell/02-05-SUMMARY.md`:
- Frontmatter: `subsystem: ui-shell`, `affects: [02-06, 02-07]`, `requires: [02-01, 02-02, 02-03, 02-04]`
- Notes: G1 branch behavior confirmed via widget test; documented that BottomNavShell accepts a `currentIndex + onTap` API (02-06 wires the shell in).
</output>
