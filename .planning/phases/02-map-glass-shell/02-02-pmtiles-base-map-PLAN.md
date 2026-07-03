---
plan: "02-02"
title: "MapLibre + PMTiles integration — bundled offline base map"
phase: "02-map-glass-shell"
type: execute
wave: 2
depends_on: ["02-01"]   # only for pubspec (maplibre_gl already added in 02-01); no logical dependency on G1 outcome
files_modified:
  - pubspec.yaml
  - assets/tiles/README.md
  - assets/tiles/dev_berlin.pmtiles     # binary — added via tool, not editor
  - assets/map_style_light.json
  - assets/map_style_dark.json
  - lib/features/map/presentation/map_screen.dart
  - lib/features/map/presentation/widgets/map_widget.dart
  - test/features/map/map_widget_test.dart
autonomous: true

must_haves:
  truths:
    - "A `MapWidget` renders a MapLibre map with tiles sourced from a bundled `assets/tiles/dev_berlin.pmtiles`."
    - "Turning airplane mode on does not break the base map — tiles continue rendering (offline)."
    - "Two style JSON assets exist: `assets/map_style_light.json` (Google Maps-inspired warm palette) and `assets/map_style_dark.json` (deep navy, softly-colored roads)."
    - "Gesture set is enforced per CONTEXT.md: pan + zoom + rotate enabled, tilt DISABLED."
    - "`flutter test` and `flutter analyze` are green."
  artifacts:
    - path: assets/tiles/dev_berlin.pmtiles
      provides: "Berlin-bbox PMTiles archive (~5–15 MB) for bundled offline dev/testing."
      contains: "PMTiles v3 magic bytes"
    - path: assets/map_style_light.json
      provides: "Light map style referencing `pmtiles://assets/tiles/dev_berlin.pmtiles`."
      contains: "\"pmtiles://assets/tiles/dev_berlin.pmtiles\""
    - path: assets/map_style_dark.json
      provides: "Dark map style (same source, dark palette)."
      contains: "\"pmtiles://assets/tiles/dev_berlin.pmtiles\""
    - path: lib/features/map/presentation/widgets/map_widget.dart
      provides: "Reusable MapLibreMap wrapper with Phase-2-correct gesture set + style loader."
      contains: "class MapWidget"
    - path: lib/features/map/presentation/map_screen.dart
      provides: "Phase-2 map screen host (chrome added in 02-05, router-wired in 02-06)."
      contains: "class MapScreen"
  key_links:
    - from: assets/map_style_light.json
      to: assets/tiles/dev_berlin.pmtiles
      via: "PMTiles source URL"
      pattern: "pmtiles://assets/tiles/dev_berlin.pmtiles"
    - from: lib/features/map/presentation/widgets/map_widget.dart
      to: assets/map_style_light.json
      via: "MapLibreMap styleString parameter"
      pattern: "assets/map_style_light.json"
    - from: pubspec.yaml (flutter.assets)
      to: assets/tiles/dev_berlin.pmtiles
      via: "asset registration"
      pattern: "assets/tiles/"
---

<objective>
Wire MapLibre GL to a bundled PMTiles archive so the base map renders fully offline from a Flutter asset. Satisfies MAP-01, MAP-02, MAP-03 (gestures — no tilt), MAP-06 (project-owned style JSON). No location, no dark-mode switching, no glass chrome — those are 02-03 / 02-04 / 02-05.

Purpose: This is the map's spine. Once tiles render from a bundled `.pmtiles` in airplane mode, everything downstream is layered on top.
Output: A working `MapWidget` + two style JSON assets + a bundled Berlin dev tile that renders offline.
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
</context>

<tasks>

<task type="auto">
  <name>Task 1: Acquire dev_berlin.pmtiles + register assets</name>
  <files>
    - assets/tiles/dev_berlin.pmtiles   # binary
    - assets/tiles/README.md
    - pubspec.yaml
    - .gitattributes                    # optional; only if repo needs LFS-style marker
  </files>
  <action>
    1. Create `assets/tiles/` directory. Acquire a **Berlin-bbox PMTiles** file of ~5–15 MB. Two acceptable acquisition methods, in preference order:

       **Method A (preferred — reproducible):** Download the stable Protomaps demo tile if it covers Berlin at usable zoom, OR download a pre-built Berlin extract via `pmtiles extract`:
       ```
       pmtiles extract https://build.protomaps.com/YYYYMMDD.pmtiles \
         assets/tiles/dev_berlin.pmtiles \
         --bbox=13.088,52.338,13.761,52.677 \
         --maxzoom=14
       ```
       (Replace `YYYYMMDD` with the latest stable Protomaps build date; if unavailable, use the demo bucket per 02-RESEARCH.md.)

       **Method B (fallback):** Download `https://demo-bucket.protomaps.com/v4.pmtiles` directly (planet-scale demo, still small enough because it's low-zoom). Only use if Method A fails.

       If neither method works from your environment, STOP and add a deviation note — do NOT commit a bogus / empty `.pmtiles`. The Ralph Loop will fail the `verify` step (see below) and the executor should escalate to the user.

    2. Verify the acquired file:
       ```
       # First 7 bytes should be "PMTiles" magic (0x50 0x4D 0x54 0x69 0x6C 0x65 0x73)
       head -c 7 assets/tiles/dev_berlin.pmtiles | xxd
       ```
       Must print `504d 5469 6c65 73` (PMTiles).

    3. Create `assets/tiles/README.md` documenting:
       - What this file is
       - How it was generated (command line used, source PBF date)
       - Approximate size + zoom range
       - How to regenerate (link to Protomaps + `pmtiles` CLI)
       - Note: this file is committed to git (small enough) — do NOT gitignore.

    4. Update `pubspec.yaml` `flutter.assets:` (preserve existing `assets/icons/`):
       ```yaml
       flutter:
         uses-material-design: true
         generate: true
         assets:
           - assets/icons/
           - assets/tiles/
           - assets/map_style_light.json
           - assets/map_style_dark.json
       ```
       Do NOT list individual files under `assets/tiles/` — use the directory form so future tile files (Phase 8+) are picked up automatically.
  </action>
  <verify>
    ```
    test -f assets/tiles/dev_berlin.pmtiles
    head -c 7 assets/tiles/dev_berlin.pmtiles | xxd | grep -q '504d 5469 6c65 73'
    grep -q 'assets/tiles/' pubspec.yaml
    flutter pub get
    ```
    All must succeed.
  </verify>
  <done>
    - `assets/tiles/dev_berlin.pmtiles` present, valid magic bytes.
    - `assets/tiles/README.md` documents provenance.
    - `pubspec.yaml` lists `assets/tiles/` and both style JSONs.
  </done>
</task>

<task type="auto">
  <name>Task 2: Author light + dark map style JSON assets</name>
  <files>
    - assets/map_style_light.json
    - assets/map_style_dark.json
  </files>
  <action>
    Create both style JSONs at the paths above. Base them on the Protomaps Version 4 schema (source-layers: `earth`, `water`, `landcover`, `landuse`, `buildings`, `roads`, `transit`, `places`, `pois`, `boundaries`).

    **assets/map_style_light.json — Google Maps-inspired warm palette:**
    - `background`: `#f2f1ef` (warm off-white)
    - `earth`: `#e8e4df`
    - `water`: `#a8d5e5` (soft blue)
    - `landcover` (parks/forests): `#d5e6c9`
    - `roads` highway: `#fcd390` (warm yellow), `major_road`: `#ffd280`, `minor_road`: `#ffffff` with `#e0dcd6` casing
    - `buildings`: `#dbd9d4` @ 0.7 opacity
    - `places` (city/town labels): `#333` text with `#f2f1ef` halo, `text-halo-width: 1.5`
    - `boundaries`: `#c8c4bd` dashed
    - Include a `glyphs`: `https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf` (external — acceptable for Phase 2 per Pitfall 7)
    - `sprite`: `https://protomaps.github.io/basemaps-assets/sprites/v4/light`
    - Source: single vector source keyed `protomaps` with `"url": "pmtiles://assets/tiles/dev_berlin.pmtiles"`
    - Zoom-interpolated road widths (see 02-RESEARCH.md § Code Examples for road width interpolation pattern)

    **assets/map_style_dark.json — Deep navy Google-Maps-dark feel:**
    - `background`: `#0a1728` (deep navy)
    - `earth`: `#122340`
    - `water`: `#061024` (very dark)
    - `landcover`: `#1a2f4a`
    - `roads` highway: `#f0b040` (warm amber), `major_road`: `#d99230`, `minor_road`: `#3a4d6b` with `#2a3a55` casing
    - `buildings`: `#1a2a44` @ 0.7 opacity
    - `places` labels: `#cfd8e0` text with `#0a1728` halo
    - `boundaries`: `#3a4d6b` dashed
    - Same `glyphs` URL; `sprite`: `https://protomaps.github.io/basemaps-assets/sprites/v4/dark`
    - Same source URL

    Both files MUST:
    - Be valid JSON (parse-tested in Task 4 test)
    - Start with `"version": 8`
    - Contain the exact string `"pmtiles://assets/tiles/dev_berlin.pmtiles"` in the `sources` block (needed for automated verification)
    - Include an OSM attribution string in `sources.protomaps.attribution`: `"<a href='https://protomaps.com'>Protomaps</a> © <a href='https://openstreetmap.org'>OpenStreetMap</a>"`

    You may use `ui-ux-pro-max` skill to refine exact hex values if you have time — the palettes above are the Phase-2 baseline; polish is welcome but not required. Do NOT invent new source-layer names — stick to Protomaps v4 schema.

    Anti-pattern reminder: do NOT add the source in Dart via `controller.addSource(...)`. The `pmtiles://` protocol handler only works when declared in the style JSON itself (Pitfall 1).
  </action>
  <verify>
    ```
    python -c "import json; json.load(open('assets/map_style_light.json'))"
    python -c "import json; json.load(open('assets/map_style_dark.json'))"
    grep -q '"pmtiles://assets/tiles/dev_berlin.pmtiles"' assets/map_style_light.json
    grep -q '"pmtiles://assets/tiles/dev_berlin.pmtiles"' assets/map_style_dark.json
    grep -q '"version": 8' assets/map_style_light.json
    grep -q '"version": 8' assets/map_style_dark.json
    ```
    All must pass. If python is unavailable, use Dart: `dart run -e "import 'dart:convert'; import 'dart:io'; jsonDecode(File('assets/map_style_light.json').readAsStringSync());"`.
  </verify>
  <done>
    - Both JSONs parse cleanly.
    - Both reference the correct PMTiles URL and Protomaps v4 source-layers.
    - Attribution string present.
  </done>
</task>

<task type="auto">
  <name>Task 3: Build MapWidget + MapScreen with correct gesture + rendering config</name>
  <files>
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/presentation/map_screen.dart
  </files>
  <action>
    1. Create `lib/features/map/presentation/widgets/map_widget.dart`:
       ```dart
       import 'package:flutter/foundation.dart';
       import 'package:flutter/material.dart';
       import 'package:maplibre_gl/maplibre_gl.dart';

       /// Phase-2 map widget. Wraps `MapLibreMap` with the gesture set
       /// mandated by 02-CONTEXT.md:
       ///   - pan / zoom / rotate: enabled
       ///   - tilt: DISABLED (flat 2D only)
       ///
       /// Location, follow-mode, dark-mode switching are added in later
       /// Phase 2 plans (02-03, 02-04). This widget deliberately renders
       /// only the base map + built-in compass button.
       class MapWidget extends StatefulWidget {
         const MapWidget({
           super.key,
           this.initialTarget = const LatLng(52.52, 13.40), // Berlin default
           this.initialZoom = 15,
           this.styleAsset = 'assets/map_style_light.json',
           this.onMapCreated,
           this.onStyleLoaded,
         });

         final LatLng initialTarget;
         final double initialZoom;
         final String styleAsset;
         final void Function(MapLibreMapController)? onMapCreated;
         final VoidCallback? onStyleLoaded;

         @override
         State<MapWidget> createState() => _MapWidgetState();
       }

       class _MapWidgetState extends State<MapWidget> {
         MapLibreMapController? _controller;

         @override
         Widget build(BuildContext context) {
           return MapLibreMap(
             styleString: widget.styleAsset,
             initialCameraPosition: CameraPosition(
               target: widget.initialTarget,
               zoom: widget.initialZoom,
             ),
             tiltGesturesEnabled: false,       // 02-CONTEXT.md: flat 2D only
             rotateGesturesEnabled: true,
             scrollGesturesEnabled: true,
             zoomGesturesEnabled: true,
             compassEnabled: true,             // MapLibre built-in
             compassViewPosition: CompassViewPosition.topRight,
             logoEnabled: false,
             attributionButtonPosition: AttributionButtonPosition.bottomRight,
             trackCameraPosition: true,
             // NOTE: myLocationEnabled is intentionally false here.
             // Plan 02-03 wires it up behind a permission check.
             // NOTE: useHybridComposition NOT set (default false) —
             // Pitfall 2: hybrid composition is broken on Android.
             onMapCreated: (c) {
               _controller = c;
               widget.onMapCreated?.call(c);
             },
             onStyleLoadedCallback: () {
               widget.onStyleLoaded?.call();
             },
           );
         }

         @override
         void dispose() {
           // MapLibreMapController is closed by the plugin when the widget
           // is disposed; nothing to do here in Phase 2.
           super.dispose();
         }
       }
       ```

    2. Create `lib/features/map/presentation/map_screen.dart`:
       ```dart
       import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
       import 'package:flutter/material.dart';

       /// Phase-2 map screen. In this plan it hosts only the base MapWidget.
       /// Later plans layer glass chrome (02-05) and wire into the router
       /// via a StatefulShellRoute (02-06).
       class MapScreen extends StatelessWidget {
         const MapScreen({super.key});

         @override
         Widget build(BuildContext context) {
           return const Scaffold(
             // No AppBar — UI-06 mandate.
             body: MapWidget(),
           );
         }
       }
       ```

    3. Do NOT wire `MapScreen` into `app_router.dart` yet — that's Plan 02-06. Leave `PlaceholderHomeScreen` at `/` for now. This isolates each plan.

    Ralph Loop constraints:
    - Import `MapLibreMap` from `package:maplibre_gl/maplibre_gl.dart` — if the exported member name differs in 0.26.2 (e.g. `MaplibreMap` casing), adjust to match reality.
    - Use `package:auto_explore/...` imports (Phase 1 rule).
    - If `CompassViewPosition` or `AttributionButtonPosition` enum values in 0.26.2 differ from the sketch, use whatever the package actually exports. Check `.pub-cache/hosted/pub.dev/maplibre_gl-0.26.2/lib/src/` if uncertain.
  </action>
  <verify>
    ```
    flutter analyze lib/features/map/
    ```
    Zero issues.
  </verify>
  <done>
    - Both files exist and compile.
    - `MapWidget` correctly sets `tiltGesturesEnabled: false`, `rotateGesturesEnabled: true`, `compassEnabled: true`, `useHybridComposition` NOT set (default false).
    - `MapScreen` uses `MapWidget` and has no AppBar.
  </done>
</task>

<task type="auto">
  <name>Task 4: Widget test — MapWidget builds and style asset is loaded</name>
  <files>
    - test/features/map/map_widget_test.dart
  </files>
  <action>
    Create `test/features/map/map_widget_test.dart`.

    MapLibre's platform view cannot render in a widget test (there's no platform channel). We test:
    1. The widget builds without throwing.
    2. The `styleString` param equals `assets/map_style_light.json` (default).
    3. Gesture flags are set correctly (tilt off, rotate on).

    Use `find.byType(MapLibreMap)` + a helper to grab the widget instance:
    ```dart
    import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_test/flutter_test.dart';
    import 'package:maplibre_gl/maplibre_gl.dart';

    void main() {
      testWidgets('MapWidget builds with Phase-2 gesture config', (tester) async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MapWidget())));

        final maplibre = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
        expect(maplibre.tiltGesturesEnabled, isFalse,
            reason: 'CONTEXT.md mandates flat 2D — no tilt');
        expect(maplibre.rotateGesturesEnabled, isTrue);
        expect(maplibre.zoomGesturesEnabled, isTrue);
        expect(maplibre.scrollGesturesEnabled, isTrue);
        expect(maplibre.compassEnabled, isTrue);
        expect(maplibre.styleString, 'assets/map_style_light.json');
      });

      testWidgets('MapWidget accepts custom style asset', (tester) async {
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: MapWidget(styleAsset: 'assets/map_style_dark.json')),
        ));
        final maplibre = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
        expect(maplibre.styleString, 'assets/map_style_dark.json');
      });
    }
    ```

    Note: MapLibre's platform channel is not initialized in unit tests. The widget tree contains the `MapLibreMap` widget (as a Dart object), but no native map view runs. That is exactly what we want to assert against — the configuration, not the rendering. If the widget throws during `pumpWidget` due to a missing platform channel, wrap with `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(...)` for the channel `plugins.flutter.io/maplibre_gl_<viewId>` returning null, OR find and follow the pattern the `maplibre_gl` package itself uses in its own tests.

    If the platform channel error can't be worked around cleanly, the fallback is to test the WRAPPER's params by exposing a `debug_config` getter on `MapWidget` returning a record of its config values, and asserting on that record instead. Choose whichever the Ralph Loop reaches green fastest.
  </action>
  <verify>
    ```
    flutter test test/features/map/map_widget_test.dart
    flutter test    # full suite must remain green
    ```
    Both green.
  </verify>
  <done>
    - `map_widget_test.dart` runs and passes.
    - Test asserts `tiltGesturesEnabled == false`, `rotateGesturesEnabled == true`, correct style asset paths.
    - Full test suite remains green.
  </done>
</task>

</tasks>

<verification>
- `flutter pub get` succeeds
- `flutter analyze` → 0 issues
- `flutter test` → all pre-existing + new tests green
- `assets/tiles/dev_berlin.pmtiles` exists with valid PMTiles magic bytes
- Both style JSONs parse and contain the correct PMTiles source URL
- Manual check (deferred to 02-07): install debug build on device, open MapScreen manually (e.g. via a temporary route), verify tiles render with airplane mode ON
</verification>

<success_criteria>
- MAP-02 (offline base map) achievable: bundled `.pmtiles` present, style references it correctly, `MapWidget` loads the style.
- MAP-03 (gestures — no tilt) enforced in code AND tested.
- MAP-06 (project-owned style JSON) satisfied.
- No AppBar on the map screen (UI-06 groundwork).
- Nothing in this plan reads `LiquidGlassSettings.platformSupportsBlurOverMap` — this plan is architecturally independent of 02-01.
</success_criteria>

<deviations>
(Executor logs deviations. Examples: `.pmtiles` acquisition method used, MapLibre 0.26.2 API name mismatches, widget-test approach chosen.)
</deviations>

<output>
After completion, create `.planning/phases/02-map-glass-shell/02-02-SUMMARY.md`:
- Frontmatter: `subsystem: map-rendering`, `affects: [02-03, 02-04, 02-05, 02-07]`, `tech-stack.added: [dev_berlin.pmtiles bundled asset]`
- Notes: exact source of the bundled `.pmtiles`, byte size, zoom range, any API adjustments to `MapWidget`.
</output>
