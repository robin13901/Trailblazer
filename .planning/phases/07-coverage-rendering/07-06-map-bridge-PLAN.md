---
phase: 07-coverage-rendering
plan: 06
type: execute
wave: 4
depends_on: ["07-03", "07-04", "07-05"]
files_modified:
  - lib/features/coverage/presentation/coverage_overlay_bridge.dart
  - lib/features/map/presentation/map_screen.dart
  - lib/features/map/presentation/widgets/map_widget.dart
  - test/features/coverage/presentation/coverage_overlay_bridge_test.dart
autonomous: false

must_haves:
  truths:
    - "On the map screen, driven Kfz ways paint in the active preset color the moment the map style loads"
    - "The overlay is re-added after a brightness (light/dark) style swap — it does not disappear"
    - "Changing the preset in Settings recolors the live map on return, without a tile/style reload"
    - "When new trip data lands (coverage data provider refreshes), the overlay source updates"
    - "The overlay never crashes the map when geometry is missing/offline (renders whatever resolved)"
  artifacts:
    - path: "lib/features/coverage/presentation/coverage_overlay_bridge.dart"
      provides: "CoverageOverlayBridge ConsumerWidget wiring data+preset+style->applier"
      contains: "class CoverageOverlayBridge"
  key_links:
    - from: "map_widget.dart onStyleLoaded"
      to: "CoverageOverlayBridge reapply"
      via: "re-add source+layer on every style load (Pitfall 1)"
      pattern: "onStyleLoaded"
    - from: "coverage_overlay_bridge.dart"
      to: "coverageOverlayApplierProvider + coverageOverlayDataProvider + coveragePresetValueProvider + mapControllerProvider"
      via: "ref.listen -> applier.apply/updateColors"
      pattern: "coverageOverlayDataProvider|coveragePresetValueProvider"
---

<objective>
Wire the coverage overlay into the live map: a `CoverageOverlayBridge` that
watches the resolved coverage data (07-03), the active preset (07-05), the map
controller, and the style-load signal, and drives the applier (07-04) to add /
recolor / re-add the overlay. This is where the feature becomes visible on the
map screen. Includes the on-device human-verify checkpoint (deferred per project
memory) since first paint + brightness swap + live recolor need real-map eyes.

Purpose: Delivers the phase goal — "when I open the map, I immediately see the
roads I've already driven" in the chosen color, surviving dark-mode swaps and
recoloring live from Settings.
Output: bridge widget + map wiring + a bridge unit test (recording-fake applier)
+ a cataloged deferred on-device checkpoint.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-RESEARCH.md

# The three inputs + the applier this bridge orchestrates
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
  <name>Task 1: CoverageOverlayBridge — orchestrate data/preset/style -> applier</name>
  <files>lib/features/coverage/presentation/coverage_overlay_bridge.dart</files>
  <action>
Create `class CoverageOverlayBridge extends ConsumerStatefulWidget` (needs a
_styleReady flag + the last-applied cache — ConsumerWidget with only ref.listen
also works, but a stateful widget makes the style-load gating explicit).

State it must manage (RESEARCH §"Architecture Pattern" + Pitfalls 1/2/3):
  - A `bool _styleReady` gate. Expose a public `void onStyleLoaded()` the
    MapWidget calls; on style load set _styleReady=true and force a full re-apply
    (source wiped by setStyle -> must re-add, Pitfall 1). Also reset any
    _sourceAdded flag.
  - Watch/listen:
      * coverageOverlayDataProvider (AsyncValue<CoverageOverlayData>): on new
        data AND _styleReady -> applier.apply(controller, data, preset, brightness).
        (apply() itself remove-then-readds, so it doubles as the data-update path
        — RESEARCH says setGeoJsonSource is an optimization; apply/re-add is
        correct + simpler and matches trip_overlay idiom.)
      * coveragePresetValueProvider (CoverageColorPreset): on change AND
        _styleReady AND source already added -> applier.updateColors(controller,
        preset, brightness) (live recolor, no source reload — REN-06).
      * brightness: read from `MediaQuery.platformBrightnessOf(context)` /
        `View.of(context).platformDispatcher.platformBrightness`. On brightness
        change the MapWidget triggers setStyle -> onStyleLoaded fires -> full
        re-apply with the new brightness colors. So brightness is read at
        apply/updateColors time; no separate listener needed, but ensure the
        re-apply uses current brightness.
      * mapControllerProvider: guard null (map not created / disposed).
  - Use `ref.listen` in build() (ConsumerStatefulWidget) for data + preset;
    trigger the applier calls via `unawaited(...)`. All applier calls guarded by
    `controller != null && _styleReady`.
  - The widget renders `const SizedBox.shrink()` (headless), like
    TrackingCameraSync in map_screen.

Read the applier from `coverageOverlayApplierProvider`. Wrap applier calls so a
throw is logged (Logger) and swallowed — the map must never crash (memory 06-05).

Package imports only; withValues if needed; no @Riverpod.
  </action>
  <verify>flutter analyze clean.</verify>
  <done>CoverageOverlayBridge re-applies on style load, recolors on preset change, re-adds on data change, guards null controller + not-ready, and never throws out.</done>
</task>

<task type="auto">
  <name>Task 2: Mount the bridge in MapScreen + route onStyleLoaded through it</name>
  <files>lib/features/map/presentation/map_screen.dart, lib/features/map/presentation/widgets/map_widget.dart</files>
  <action>
The bridge must receive the onStyleLoaded signal from MapWidget. Cleanest wiring
that respects existing structure:
  - Add a headless CoverageOverlayBridge to the MapScreen Stack (like the
    TrackingCameraSync zero-size Positioned) so it's always in the tree and keeps
    listening across tab switches. Give it a GlobalKey OR route the style signal
    via a provider.
  - PREFERRED (decoupled): introduce a tiny signal provider instead of GlobalKey.
    Add `mapStyleLoadedTickProvider` (a `NotifierProvider<StyleTickNotifier,int>`
    that increments) in map_widget's provider area or a new small file. In
    MapWidget._onStyleLoaded (already exists, calls widget.onStyleLoaded), also
    bump the tick: the MapWidget can `ref.read(mapStyleLoadedTickProvider.notifier)
    .bump()`. The bridge watches the tick -> on change, does the full re-apply.
    This avoids GlobalKey plumbing and keeps MapWidget's onStyleLoaded callback
    contract intact.
    * MapWidget is a ConsumerStatefulWidget already (has ref) — bump is safe in
      _onStyleLoaded.
  - Mount `const CoverageOverlayBridge()` in the MapScreen Stack as a zero-size
    Positioned (mirror the TrackingCameraSync placement so it doesn't size the
    Stack or steal hit-tests).
  - Ensure the bridge is present regardless of tab (place it outside the
    `if (isMapTab)` block, alongside TrackingCameraSync) so coverage persists
    when returning to the map tab.

Update the MapWidget setStyle comment block (currently says "If Phase 7+ adds
coverage sources... they MUST be re-added inside _onStyleLoaded()") to point at
the tick provider + bridge as the implementation.

NOTE: touches map_widget.dart (has existing widget tests) — run `flutter test`
inline for map + coverage.
  </action>
  <verify>flutter analyze clean; existing map widget tests still green; bridge mounted in MapScreen.</verify>
  <done>MapWidget style-load bumps a tick provider the bridge watches; CoverageOverlayBridge is mounted headless in MapScreen and re-applies on every style load.</done>
</task>

<task type="auto">
  <name>Task 3: Bridge unit test with recording-fake applier</name>
  <files>test/features/coverage/presentation/coverage_overlay_bridge_test.dart</files>
  <action>
Override coverageOverlayApplierProvider with a recording fake capturing
apply/updateColors/remove calls (+ the preset/data passed). Override
coverageOverlayDataProvider with a fixed CoverageOverlayData, coveragePresetProvider
with amber, and mapControllerProvider with null (the fake applier tolerates a
null controller — mirror TripOverlayApplier fakes).
  - Pump CoverageOverlayBridge in a ProviderScope + MaterialApp.
  - Simulate a style-load tick (bump mapStyleLoadedTickProvider) -> assert
    applier.apply called once with the amber preset + the fixed data.
  - Change coveragePresetProvider to green -> assert applier.updateColors called
    with green (NOT a second full apply).
  - Change coverageOverlayDataProvider data -> assert apply called again.
Because the real applier needs a controller, assert on the fake's recorded
calls, not on MapLibre. If null-controller gating short-circuits before
recording, have the bridge pass the (null) controller to the fake so the call is
still recorded — design the fake to record regardless of controller (matches
how MapLibreTripOverlayApplier early-returns but the fake records).

Run `flutter test test/features/coverage/presentation/coverage_overlay_bridge_test.dart`.
  </action>
  <verify>flutter test green; flutter analyze clean.</verify>
  <done>Bridge test proves: style tick -> apply; preset change -> updateColors; data change -> apply; via a recording-fake applier.</done>
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
- Overlay re-add is driven by onStyleLoaded (grep the tick provider wiring).
</verification>

<success_criteria>
Driven Kfz ways paint on the live map in the active preset color, survive
brightness style swaps (re-added on onStyleLoaded), and recolor live from the
Settings picker without a tile reload — the phase goal made visible. On-device
visual confirmation is cataloged as a deferred manual checkpoint.
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-06-SUMMARY.md`
</output>
