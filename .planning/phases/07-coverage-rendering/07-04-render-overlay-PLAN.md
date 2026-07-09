---
phase: 07-coverage-rendering
plan: 04
type: execute
wave: 3
depends_on: ["07-01", "07-03"]
files_modified:
  - lib/features/coverage/presentation/coverage_overlay_layers.dart
  - lib/features/coverage/presentation/coverage_feature_collection.dart
  - test/features/coverage/presentation/coverage_feature_collection_test.dart
  - test/features/coverage/presentation/coverage_overlay_layers_test.dart
autonomous: true

must_haves:
  truths:
    - "A list of CoverageWays serializes to a GeoJSON FeatureCollection where each feature carries is_full (int) + fraction (double) props"
    - "The coverage line layer uses data-driven paint expressions: case on is_full for color, fraction-scaled opacity with a floor, zoom-interpolated width"
    - "Full ways render in the preset full hex; partial ways render in the lighter partial hex at fraction-scaled opacity"
    - "The layer is inserted below the first label/symbol layer discovered via getLayerIds (RESEARCH open-Q4)"
    - "Applying is idempotent: remove-then-readd survives repeated calls (style-swap safe)"
    - "Preset color change updates the layer via a full-property setLayerProperties (RESEARCH open-Q3), no source reload"
  artifacts:
    - path: "lib/features/coverage/presentation/coverage_feature_collection.dart"
      provides: "buildCoverageFeatureCollection(List<CoverageWay>) -> Map<String,dynamic>"
      contains: "buildCoverageFeatureCollection"
    - path: "lib/features/coverage/presentation/coverage_overlay_layers.dart"
      provides: "CoverageOverlayApplier: add/update/remove source+layer with data-driven expressions"
      contains: "class MapLibreCoverageOverlayApplier"
  key_links:
    - from: "coverage_overlay_layers.dart"
      to: "MapLibreMapController.addGeoJsonSource / addLineLayer / setLayerProperties / getLayerIds"
      via: "runtime GeoJSON overlay (Gate G2 resolution)"
      pattern: "addGeoJsonSource|setLayerProperties|getLayerIds"
    - from: "coverage_overlay_layers.dart"
      to: "coverage_color_preset.dart forBrightness"
      via: "preset -> full/partial hex for the case expression"
      pattern: "forBrightness"
    - from: "coverage_feature_collection.dart"
      to: "CoverageWay.datum"
      via: "is_full + fraction GeoJSON props"
      pattern: "is_full|fraction"
---

<objective>
Build the MapLibre render layer that paints driven Kfz ways using the Gate-G2
resolution: a single runtime GeoJSON source + data-driven paint expressions
(feature-state is unavailable on mobile). This mirrors the existing
`trip_overlay_layers.dart` idiom (addGeoJsonSource + addLineLayer +
idempotent remove) but generalizes it app-wide with per-feature `is_full` /
`fraction` props driving color + opacity GPU-side.

Purpose: This is the visible feature — orange full / lighter-orange partial
ways, zoom-scaled width, flat recolor (no glow/casing, protecting the fps gate).
It also owns the two remaining RESEARCH open questions: belowLayerId discovery
(Q4) and the full-property setLayerProperties recolor (Q3).
Output: FeatureCollection builder + applier + tests. No live-map wiring yet
(that's 07-05).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-RESEARCH.md

# The EXACT pattern to generalize (colorToHex, addGeoJsonSource, idempotent
# remove, onStyleLoaded re-add contract). Reuse colorToHex from here.
@lib/features/trips/presentation/widgets/trip_overlay_layers.dart

# Domain + data consumed by this layer (from 07-01 / 07-03)
@lib/features/coverage/domain/coverage_color_preset.dart
@lib/features/coverage/domain/coverage_datum.dart
@lib/features/coverage/data/coverage_overlay_data.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: GeoJSON FeatureCollection builder with is_full/fraction props</name>
  <files>lib/features/coverage/presentation/coverage_feature_collection.dart, test/features/coverage/presentation/coverage_feature_collection_test.dart</files>
  <action>
Create `buildCoverageFeatureCollection(List<CoverageWay> ways) ->
Map<String, dynamic>`:
  {
    'type': 'FeatureCollection',
    'features': [ for way: {
      'type': 'Feature',
      'geometry': {'type':'LineString', 'coordinates':
        [ for p in way.geometry [p.longitude, p.latitude] ]},
      'properties': {
        'way_id': way.wayId,
        'fraction': way.datum.fraction,     // double 0..1
        'is_full': way.datum.isFull ? 1 : 0 // int for the case expression
      },
    }],
  }
Skip ways with < 2 geometry points (degenerate LineString). Empty input ->
FeatureCollection with empty features list (RESEARCH Pitfall 7 — empty source
is valid; always add source, let it render nothing).

Consider adding an optional `compute`-friendly top-level function signature
(pure, no Flutter deps beyond LatLng) so 07-06 stress harness can run it on an
isolate. Keep it a plain top-level function.

Test: 2 ways (one full, one partial) -> assert feature count, coordinate order
is [lon,lat], is_full is 1/0 int, fraction is the datum value; a 1-point way is
dropped; empty list -> empty features.
  </action>
  <verify>flutter test test/features/coverage/presentation/coverage_feature_collection_test.dart green.</verify>
  <done>buildCoverageFeatureCollection produces valid GeoJSON with is_full(int)+fraction(double)+way_id props; degenerate + empty handled.</done>
</task>

<task type="auto">
  <name>Task 2: CoverageOverlayApplier — source+layer with data-driven expressions, belowLayerId, recolor</name>
  <files>lib/features/coverage/presentation/coverage_overlay_layers.dart</files>
  <action>
Define an abstract `CoverageOverlayApplier` (mirrors TripOverlayApplier so it's
test-fakeable with a null controller) with:
  Future<void> apply(MapLibreMapController? c, {required CoverageOverlayData data,
    required CoverageColorPreset preset, required Brightness brightness});
  Future<void> updateColors(MapLibreMapController? c, {required CoverageColorPreset
    preset, required Brightness brightness});
  Future<void> remove(MapLibreMapController? c);

Constants: sourceId = 'coverage_overlay', layerId = 'coverage_layer'.

Production `class MapLibreCoverageOverlayApplier implements CoverageOverlayApplier`:

  remove(): try/catch removeLayer(layerId) then removeSource(sourceId),
    swallowing not-found (idempotent — same idiom as
    MapLibreTripOverlayApplier.removeTripOverlay).

  apply(): null-controller early-return. Then:
    1. await remove(c)   // clean slate — safe across style swaps (Pitfall 1/3)
    2. final fc = buildCoverageFeatureCollection(data.ways);
       await c.addGeoJsonSource(sourceId, fc);   // always add, even if empty (Pitfall 7)
    3. final belowId = await _firstSymbolLayerId(c); // open-Q4
    4. await c.addLineLayer(sourceId, layerId, _paint(preset, brightness),
         belowLayerId: belowId);

  _paint(preset, brightness) -> LineLayerProperties, building the data-driven
  expressions (RESEARCH §"Chosen Architecture" + §"Zoom-Scaled Line Width").
  colors = preset.forBrightness(brightness):
    lineColor: ['case', ['==', ['get','is_full'], 1], colors.fullHex, colors.partialHex]
    lineOpacity: ['case', ['==', ['get','is_full'], 1], 0.92,
                  ['max', 0.25, ['*', 0.85, ['get','fraction']]]]
    lineWidth: ['interpolate', ['linear'], ['zoom'],
                8,2.5, 11,3.0, 13,4.0, 15,5.0, 18,7.0]
    lineJoin: 'round', lineCap: 'round'
  Expressions are plain Dart `List<dynamic>` passed to the `dynamic`-typed
  properties (RESEARCH Pitfall 5). Extract the opacity floor / full-opacity
  values as named consts referencing 07-01's floor rationale; document they are
  golden-corpus-tunable.

  updateColors(): RESEARCH open-Q3 + Pitfall 6 — setLayerProperties with
  skipNulls:false will null out omitted fields. Therefore pass a FULLY-SPECIFIED
  LineLayerProperties (the same _paint(preset,brightness) object, which includes
  color + opacity + width + join + cap) to
  `c.setLayerProperties(layerId, _paint(preset, brightness))`. This changes color
  live WITHOUT touching the source (no reload). Document why the full property
  set is passed (Q3). Guard null controller.

  _firstSymbolLayerId(c) -> Future<String?> (open-Q4): call
  `final ids = await c.getLayerIds();` (returns List<dynamic> of layer id
  strings). Find the first id whose lowercased string contains 'label',
  'place', 'poi', or matches a symbol/text pattern (MapTiler dataviz label
  layers are named like 'Place labels', 'Road labels'). Return it; else null
  (top of stack). Wrap in try/catch -> null on any error (never block the
  overlay). Document the heuristic + that hosted style layer ids are discovered
  at runtime, not hardcoded.

Reuse `colorToHex` import from trip_overlay_layers.dart if converting Color;
here we already have hex strings from forBrightness, so colorToHex may be
unneeded — do not add an unused import.

Provider: add `coverageOverlayApplierProvider = Provider<CoverageOverlayApplier>
((ref) => const MapLibreCoverageOverlayApplier());` (tests override with a
recording fake) — mirror tripOverlayApplierProvider. Put it in this file.

Package imports only. `withValues(alpha:)` if any Color alpha is needed (it
should not be — opacity is expression-driven).
  </action>
  <verify>flutter analyze clean; expression lists compile against the dynamic-typed LineLayerProperties fields.</verify>
  <done>MapLibreCoverageOverlayApplier adds source+layer with case/interpolate expressions, discovers belowLayerId via getLayerIds, recolors via full-property setLayerProperties, and remove() is idempotent.</done>
</task>

<task type="auto">
  <name>Task 3: Recording-fake applier test (null controller)</name>
  <files>test/features/coverage/presentation/coverage_overlay_layers_test.dart</files>
  <action>
Widget tests cannot build a real MapLibreMapController. Follow the
trip_overlay_layers test approach: build the applier's public surface against a
recording fake that captures the arguments. Since MapLibreCoverageOverlayApplier
calls a real controller, structure the assertions around the FEATURE COLLECTION
+ PAINT builder instead:
  - Assert buildCoverageFeatureCollection wiring for full/partial produces the
    expected props (may overlap Task 1 — keep focused).
  - Extract `_paint`/expression building into a testable top-level pure function
    `coverageLinePaintExpressions(CoverageColorPreset, Brightness) ->
    ({List lineColor, List lineOpacity, List lineWidth})` (or a small class) so
    the expressions can be asserted without a controller. Assert:
      * amber light -> lineColor case picks '#FF8C00' (full) / '#FFCD6B' (partial).
      * amber dark -> '#FFA726' / '#FFD54F'.
      * lineOpacity contains the 0.92 full branch + the ['max',0.25,...] partial.
      * lineWidth is an interpolate-on-zoom expression with the documented stops.
  - Assert the applier's provider default is MapLibreCoverageOverlayApplier.
Refactor Task 2 to expose that pure expression builder and have _paint call it,
so this test has a real seam.

Run `flutter test test/features/coverage/presentation/` inline.
  </action>
  <verify>flutter test test/features/coverage/presentation/ green; flutter analyze clean.</verify>
  <done>Paint-expression builder is unit-tested for full/partial color per brightness + opacity floor + zoom width; provider default asserted.</done>
</task>

</tasks>

<verification>
- `flutter analyze` clean.
- `flutter test test/features/coverage/` green (domain + data + presentation).
- No feature-state / setFeatureState / promoteId usage anywhere (Gate G2).
</verification>

<success_criteria>
The coverage render layer serializes CoverageWays to a GeoJSON FeatureCollection
and paints them via GPU-evaluated data-driven expressions: full ways in the
preset full hex at 0.92 opacity, partial ways in the lighter partial hex at
fraction-scaled opacity (floored 0.25), zoom-interpolated width, inserted below
the first label layer, idempotent across style swaps, live-recolorable via a
full-property setLayerProperties. RESEARCH open-questions Q3 + Q4 are closed here.
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-04-SUMMARY.md`
</output>
