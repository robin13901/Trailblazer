---
phase: 07-coverage-rendering
plan: 06
type: execute
wave: 4
depends_on: ["07-03", "07-04", "07-05"]
files_modified:
  - lib/features/coverage/presentation/coverage_overlay_bridge.dart
  - lib/features/map/presentation/providers/map_style_loaded_provider.dart
  - lib/features/map/presentation/map_screen.dart
  - lib/features/map/presentation/widgets/map_widget.dart
  - test/features/coverage/presentation/coverage_overlay_bridge_test.dart
autonomous: false

must_haves:
  truths:
    - "On the map screen, driven Kfz ways paint in the active preset color the moment the map style loads"
    - "The overlay is re-added after a brightness (light/dark) style swap — it does not disappear"
    - "Changing the preset in Settings recolors the live map on return, without a tile/style reload"
    - "When new trip data lands (coverage data provider re-emits), the overlay source updates"
    - "The overlay never crashes the map when geometry is missing/offline (renders whatever resolved)"
  artifacts:
    - path: "lib/features/coverage/presentation/coverage_overlay_bridge.dart"
      provides: "CoverageOverlayBridge ConsumerStatefulWidget wiring data+preset+styleTick->applier"
      contains: "class CoverageOverlayBridge"
    - path: "lib/features/map/presentation/providers/map_style_loaded_provider.dart"
      provides: "mapStyleLoadedTickProvider (increment-on-style-load signal)"
      contains: "mapStyleLoadedTickProvider"
  key_links:
    - from: "map_widget.dart _onStyleLoaded"
      to: "mapStyleLoadedTickProvider.bump()"
      via: "signal a style (re)load so the bridge re-adds source+layer (Pitfall 1)"
      pattern: "mapStyleLoadedTickProvider"
    - from: "coverage_overlay_bridge.dart"
      to: "coverageOverlayApplierProvider + coverageOverlayDataProvider + coveragePresetValueProvider + mapStyleLoadedTickProvider + mapControllerProvider"
      via: "ref.watch/listen -> applier.apply/updateColors"
      pattern: "coverageOverlayDataProvider|mapStyleLoadedTickProvider"
---

<objective>
Wire the coverage overlay into the live map: a `CoverageOverlayBridge` that
watches the resolved coverage data (07-03), the active preset (07-05), the map
controller, and a style-load tick signal, and drives the applier (07-04) to add
/ recolor / re-add the overlay. This is where the feature becomes visible on the
map screen. Includes the on-device human-verify checkpoint (deferred per project
memory) since first paint + brightness swap + live recolor need real-map eyes.

Purpose: Delivers the phase goal — "when I open the map, I immediately see the
roads I've already driven" in the chosen color, surviving dark-mode swaps and
recoloring live from Settings.
Output: tick provider + bridge widget + map wiring + a bridge unit test
(recording-fake applier) + a cataloged deferred on-device checkpoint.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-RESEARCH.md

# The inputs + the applier this bridge orchestrates
@lib/features/coverage/data/coverage_overlay_providers.dart
@lib/features/coverage/presentation/coverage_overlay_layers.dart
@lib/features/coverage/presentation/coverage_preset_provider.dart

# The map host: onStyleLoaded hook + setStyle-wipes-sources contract + controller
@lib/features/map/presentation/widgets/map_widget.dart
@lib/features/map/presentation/map_screen.dart
@lib/features/map/presentation/providers/map_controller_provider.dart

# The idiom this generalizes (onStyleLoaded re-apply)
@lib/features/trips/presentation/widgets/trip_overlay_layers.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: mapStyleLoadedTickProvider + CoverageOverlayBridge (tick-driven)</name>
  <files>lib/features/map/presentation/providers/map_style_loaded_provider.dart, lib/features/coverage/presentation/coverage_overlay_bridge.dart</files>
  <action>
FIRST create the style-load signal provider (this is the single mechanism the
bridge uses to know the style (re)loaded — there is NO public callback method on
the bridge; the tick is the interface):

`map_style_loaded_provider.dart` — plain NotifierProvider (NO @Riverpod):
  class StyleTickNotifier extends Notifier<int> {
    @override int build() => 0;
    void bump() => state = state + 1;
  }
  final mapStyleLoadedTickProvider =
      NotifierProvider<StyleTickNotifier, int>(StyleTickNotifier.new);
Doc-comment: incremented by MapWidget on every onStyleLoaded (initial load AND
after each setStyle brightness swap). Watchers treat any change as "style
(re)loaded — programmatic sources were wiped, re-add them" (Pitfall 1).

THEN create `class CoverageOverlayBridge extends ConsumerStatefulWidget`. It is
DRIVEN BY the watched tick — do not expose a public onStyleLoaded() method.

State + wiring (RESEARCH §"Architecture Pattern" + Pitfalls 1/2/3):
  - Keep a private `bool _sourceAdded` flag (reset to false on each style tick,
    set true after a successful apply) so preset-change can decide apply vs
    updateColors. No public style callback — style readiness is derived purely
    from the tick having fired at least once (track `int _lastTick = -1` or a
    `bool _styleReady`).
  - In build() (ConsumerStatefulWidget):
      * `final tick = ref.watch(mapStyleLoadedTickProvider);` — when this changes
        (new style load), the widget rebuilds; detect the change vs `_lastTick`,
        set _styleReady=true, _sourceAdded=false, and schedule a FULL re-apply
        (source was wiped — must re-add, Pitfall 1). Use a post-frame callback or
        an immediate unawaited call.
      * `ref.listen(coverageOverlayDataProvider, ...)`: on new data AND _styleReady
        -> full applier.apply(controller, data, preset, brightness); set
        _sourceAdded=true. (apply() remove-then-readds, so it doubles as the
        data-update path — RESEARCH says setGeoJsonSource is an optimization;
        apply/re-add is correct + simpler and matches the trip_overlay idiom.
        This satisfies truth "coverage data re-emits -> overlay updates"; 07-03
        makes coverageOverlayDataProvider a reactive StreamProvider so a trip
        confirmation triggers this listen.)
      * `ref.listen(coveragePresetValueProvider, ...)`: on change AND _styleReady
        AND _sourceAdded -> applier.updateColors(controller, preset, brightness)
        (live recolor, no source reload — REN-06). If _sourceAdded is false
        (no source yet), fall back to a full apply.
      * brightness: read from `View.of(context).platformDispatcher.platformBrightness`
        (or MediaQuery.platformBrightnessOf(context)). A brightness change makes
        MapWidget call setStyle -> onStyleLoaded -> tick bump -> full re-apply
        with the new brightness colors. So brightness is read at apply/updateColors
        time; no separate brightness listener needed.
      * mapControllerProvider: read via ref.read at call time; guard null (map not
        created / disposed).
  - All applier calls guarded by `controller != null && _styleReady`, dispatched
    via `unawaited(...)`.
  - Renders `const SizedBox.shrink()` (headless), like TrackingCameraSync.

Read the applier from `coverageOverlayApplierProvider`. Wrap applier calls so a
throw is logged (Logger) and swallowed — the map must never crash (memory 06-05).

Package imports only; withValues if needed; no @Riverpod.
  </action>
  <verify>flutter analyze clean.</verify>
  <done>mapStyleLoadedTickProvider exists; CoverageOverlayBridge watches the tick (no public callback), does a full re-apply on each tick, recolors on preset change, re-applies on data re-emit, guards null controller + not-ready, and never throws out.</done>
</task>

<task type="auto">
  <name>Task 2: Bump the tick in MapWidget + mount the bridge in MapScreen</name>
  <files>lib/features/map/presentation/widgets/map_widget.dart, lib/features/map/presentation/map_screen.dart</files>
  <action>
This task is pure WIRING — the tick provider + bridge interface were defined in
Task 1. No interface changes here.

MapWidget (`map_widget.dart`):
  - In `_onStyleLoaded()` (already exists — fades back in + calls
    widget.onStyleLoaded), ALSO bump the tick:
    `ref.read(mapStyleLoadedTickProvider.notifier).bump();`
    MapWidget is a ConsumerStatefulWidget (has ref) — safe. Keep the existing
    `widget.onStyleLoaded?.call()` contract intact (do not remove it).
  - Update the existing setStyle comment block (currently "If Phase 7+ adds
    coverage sources... they MUST be re-added inside _onStyleLoaded()") to state
    that _onStyleLoaded now bumps mapStyleLoadedTickProvider, which
    CoverageOverlayBridge watches to re-add the coverage source+layer.

MapScreen (`map_screen.dart`):
  - Mount `const CoverageOverlayBridge()` in the Stack as a zero-size Positioned
    (mirror the TrackingCameraSync placement: `Positioned(top:0,left:0,width:0,
    height:0, child: CoverageOverlayBridge())`) so it does not size the Stack or
    steal hit-tests.
  - Place it OUTSIDE the `if (isMapTab)` block (alongside TrackingCameraSync) so
    the overlay persists when returning to the map tab and keeps listening across
    tab switches.

NOTE: touches map_widget.dart (has existing widget tests) — run `flutter test`
inline for map + coverage.
  </action>
  <verify>flutter analyze clean; existing map widget tests still green; bridge mounted in MapScreen; _onStyleLoaded bumps the tick.</verify>
  <done>MapWidget._onStyleLoaded bumps mapStyleLoadedTickProvider on every style load; CoverageOverlayBridge is mounted headless in MapScreen (tab-independent).</done>
</task>

<task type="auto">
  <name>Task 3: Bridge unit test with recording-fake applier</name>
  <files>test/features/coverage/presentation/coverage_overlay_bridge_test.dart</files>
  <action>
Override coverageOverlayApplierProvider with a recording fake capturing
apply/updateColors/remove calls (+ the preset/data passed). Override
coverageOverlayDataProvider with a fixed CoverageOverlayData (use a
StreamProvider override or override with a controllable value),
coveragePresetProvider (+ coveragePresetValueProvider) with amber, and
mapControllerProvider with null. Design the recording fake to record calls
REGARDLESS of controller nullness (mirrors how MapLibreTripOverlayApplier
early-returns on null but a test fake still records — so the null controller
does not swallow the assertion).
  - Pump CoverageOverlayBridge in a ProviderScope + MaterialApp.
  - Simulate a style-load tick: `container.read(mapStyleLoadedTickProvider
    .notifier).bump()` then pump -> assert applier.apply called with the amber
    preset + the fixed data (this is the "style (re)loaded -> re-add" path).
  - Change coveragePresetProvider to green -> pump -> assert applier.updateColors
    called with green (NOT a second full apply), given a source was already added.
  - Change coverageOverlayDataProvider data (emit new value) -> pump -> assert
    apply called again (the reactive data-update path 07-03 enables).
Assert on the fake's recorded calls, not on MapLibre.

Run `flutter test test/features/coverage/presentation/coverage_overlay_bridge_test.dart`.
  </action>
  <verify>flutter test green; flutter analyze clean.</verify>
  <done>Bridge test proves: style tick -> apply; preset change -> updateColors; data re-emit -> apply; via a recording-fake applier driven by the tick provider.</done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <what-built>
Full coverage overlay wired to the live map: driven Kfz ways paint in the active
preset color, re-paint after dark-mode swap, and recolor live when a new preset
is chosen in Settings. (Code-complete + all unit tests green.)
  </what-built>
  <how-to-verify>
DEFERRED per project memory ("defer-in-car-verification" + Phase 6
MANUAL-TESTS-DEFERRED precedent): this requires a real device with driven data
+ MapTiler key. Batch into the next user drive/session. When verifying:
  1. Launch debug with `--dart-define-from-file=env/dev.json` (MAPTILER_KEY —
     else the map is blank).
  2. Open the map on a device that has confirmed/matched trips -> explored Kfz
     roads appear in orange (full) / lighter-orange (partial) immediately.
  3. Toggle system dark mode -> map style swaps AND the coverage overlay stays
     (does not vanish) and uses the dark preset variant.
  4. Settings -> Coverage color -> pick Green -> back to map -> explored roads
     recolor to green WITHOUT a full map/tile reload flash.
  5. Confirm partial ways are visibly lighter/more transparent than full ways.
Record the outcome in a `07-MANUAL-TESTS-DEFERRED.md` (Phase 6 precedent) at
phase close rather than blocking here.
  </how-to-verify>
  <resume-signal>Type "approved" (or catalog as deferred) — describe any visual issues (color pop, partial legibility, swap flicker).</resume-signal>
</task>

</tasks>

<verification>
- `flutter analyze` clean.
- `flutter test test/features/coverage/ test/features/map/` green.
- No setFeatureState/promoteId anywhere (Gate G2).
- Overlay re-add is driven by mapStyleLoadedTickProvider (grep the tick wiring in
  MapWidget._onStyleLoaded + the bridge watch).
</verification>

<success_criteria>
Driven Kfz ways paint on the live map in the active preset color, survive
brightness style swaps (re-added on the style-load tick), and recolor live from
the Settings picker without a tile reload — the phase goal made visible. A
confirmed trip re-emits coverage data and updates the overlay in-session.
On-device visual confirmation is cataloged as a deferred manual checkpoint.
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-06-SUMMARY.md`
</output>
