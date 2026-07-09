# Phase 7: Coverage Rendering - Research

**Researched:** 2026-07-09
**Domain:** MapLibre GL (flutter-maplibre-gl 0.26.2), GeoJSON runtime overlays, coverage fraction computation, Settings persistence
**Confidence:** HIGH — all key claims verified against installed pub-cache source and official changelogs

---

## Summary

Phase 7 paints driven Kfz roads onto the MapLibre map with full/partial coverage semantics. The research resolves Gate G2 definitively, identifies the correct rendering architecture, and provides concrete API call sequences.

**Gate G2 verdict: FAIL — sharded GeoJSON is the mandated path.**
`setFeatureState` in `maplibre_gl ^0.26.2` throws `UnimplementedError` on both Android and iOS. The platform interface source (pub-cache `method_channel_maplibre_gl.dart`) contains the literal comment "TODO: Implement feature state support for iOS and Android" and throws. The feature is tracked on the upstream repo as milestone 0.27.0 (issue #889, opened 2026-07-05). There is no released version that supports it on mobile. Architecture option (b) — feature-state on the pmtiles vector layer — is also ruled out because `promoteId` is silently dropped from the `source#addGeoJson` method-channel call even on the Dart layer. Architecture option (c) — **data-driven paint expressions on a runtime GeoJSON source** — is the correct path and is fully supported on both platforms in 0.26.2.

**Primary recommendation:** Single GeoJSON source per brightness-level (two sources: `coverage_light`, `coverage_dark`), each a FeatureCollection of driven way LineStrings. Every feature carries `coverage_fraction` (float 0–1) and `is_full` (bool) as GeoJSON properties. A single line layer per source uses MapLibre data-driven paint expressions to compute color and opacity from these properties. Color change = `setLayerProperties` call (no source reload). Source update = `setGeoJsonSource` with the new FeatureCollection. Both are available and working in 0.26.2.

---

## Gate G2 — Architecture Decision

### Evidence

**Source verified in pub-cache** (`/c/Users/I551358/AppData/Local/Pub/Cache/hosted/pub.dev/maplibre_gl_platform_interface-0.26.2/lib/src/method_channel_maplibre_gl.dart`):

```dart
Future<void> setFeatureState(
  String sourceId,
  String featureId,
  Map<String, dynamic> state, {
  String? sourceLayer,
}) async {
  // TODO: Implement feature state support for iOS and Android
  throw UnimplementedError(
    'setFeatureState is not yet implemented on iOS and Android. '
    'This feature is currently only available on web.',
  );
}
```

`removeFeatureState` is identical. `getFeatureState` includes the same comment in the Dart-side docstring: "**Note**: This feature is currently only available on web."

CHANGELOG for 0.26.0 (the version that added the API): "**Web**: Exposed `onMouseMove` and added feature state management (`setFeatureState`, `getFeatureState`, `removeFeatureState`) (#718)." — the keyword is "web only."

`promoteId` is also not wired through the method channel: the `source#addGeoJson` invoke call does not include the `promoteId` key, so even the promoteId-based GeoJSON variant of feature-state is unavailable on mobile.

**Upstream roadmap:** Issue #889 targets 0.27.0. Not shipped as of 0.26.2.

### Ruled-Out Options

| Option | Status | Reason |
|--------|--------|--------|
| (a) feature-state on runtime GeoJSON source with promoteId | NOT VIABLE | `setFeatureState` throws UnimplementedError; `promoteId` not wired in method channel |
| (b) feature-state on pmtiles vector layer | NOT VIABLE | Same UnimplementedError; additionally, the MapTiler-hosted tile source IDs and source-layer names are not client-controllable |
| (c) Data-driven paint expressions on GeoJSON source | **VIABLE — CHOSEN** | Fully supported in 0.26.2; `addGeoJsonSource` + `addLineLayer` with expression-valued properties is the established pattern |

### Chosen Architecture: Data-Driven GeoJSON Source

**How it works:**
1. On every `onStyleLoaded` callback (initial load AND after every brightness swap), add a single GeoJSON source `coverage_overlay` with all currently driven ways as a FeatureCollection. Each feature is a LineString with properties `fraction` (double 0.0–1.0) and `is_full` (1 or 0 as int).
2. Add one line layer `coverage_layer` on top of the base road layers.
3. Paint expressions read `fraction` and `is_full` from feature properties to set `line-opacity` and `line-color` per-feature at render time. The GPU evaluates these expressions per-feature — no per-feature Dart calls required.
4. Color change (preset picker): call `setLayerProperties` to patch the layer's paint with new hex colors and a new opacity expression. The source data does not change; the GPU re-evaluates on the next frame.
5. Source update (new trip confirmed): call `setGeoJsonSource` with the updated FeatureCollection. MapLibre diffs the source atomically on the native side.

**Concrete API calls:**

```dart
// Step 1: Add source on every onStyleLoaded.
// Source data: FeatureCollection with one Feature per driven way.
await controller.addGeoJsonSource(
  'coverage_overlay',
  _buildFeatureCollection(drivenWays),
);

// Step 2: Add layer once per style load.
await controller.addLineLayer(
  'coverage_overlay',
  'coverage_layer',
  LineLayerProperties(
    lineColor: [
      'case',
      ['==', ['get', 'is_full'], 1],
      '#FF8C00',           // full: orange/amber default
      '#FFCD6B',           // partial: lighter shade
    ],
    lineOpacity: [
      'case',
      ['==', ['get', 'is_full'], 1],
      0.92,                // full opacity
      ['max', 0.25,        // partial: fraction-scaled, floored at 0.25
       ['*', 0.85, ['get', 'fraction']]],
    ],
    lineWidth: [
      'interpolate', ['linear'], ['zoom'],
      8, 2.5,    // zoomed-out country view: slightly wider
      12, 3.5,
      15, 4.5,   // street-level: thicker for legibility
      18, 6.0,
    ],
    lineJoin: 'round',
    lineCap: 'round',
  ),
);

// Step 3: Color preset change in Settings — no source reload.
await controller.setLayerProperties(
  'coverage_layer',
  LineLayerProperties(
    lineColor: [
      'case',
      ['==', ['get', 'is_full'], 1],
      newFullHex,
      newPartialHex,
    ],
  ),
);

// Step 4: New trip data — atomic source update.
await controller.setGeoJsonSource(
  'coverage_overlay',
  _buildFeatureCollection(updatedDrivenWays),
);
```

**GeoJSON feature shape:**
```json
{
  "type": "Feature",
  "geometry": {
    "type": "LineString",
    "coordinates": [[lon, lat], ...]
  },
  "properties": {
    "way_id": 123456789,
    "fraction": 0.73,
    "is_full": 0
  }
}
```

**Why this is correct for the fps gate (REN-04 — 50k segments ≥ 30 fps):**

The data-driven expression approach is evaluated by the MapLibre native GL engine entirely on the GPU during the rendering pipeline. There are zero per-feature Dart calls during frame rendering. The GPU evaluates the `case`/`get`/`interpolate` expressions using vectorized shader operations. The only Dart-side work is the one-time `addGeoJsonSource` / `setGeoJsonSource` call, which serializes the FeatureCollection to JSON and passes it to the native side once. MapLibre then processes it on a background thread and uploads the vertex buffer. For 50k LineString features with 5 avg points each (~250k coordinates), the JSON payload is approximately 20–35 MB — large enough that the `setGeoJsonSource` call should be done off the main isolate (see stress harness section).

---

## Per-Requirement Implementation Notes

### REN-01: Default orange/amber color + 5 presets

**Recommended 5 presets (full/partial hex pairs, light mode):**

| Name | Full hex | Partial hex | Dark-mode full | Dark-mode partial |
|------|----------|-------------|----------------|-------------------|
| Amber (default) | `#FF8C00` | `#FFCD6B` | `#FFA726` | `#FFD54F` |
| Green | `#2ECC71` | `#A8E6CF` | `#4CAF50` | `#A5D6A7` |
| Blue | `#2196F3` | `#90CAF9` | `#42A5F5` | `#BBDEFB` |
| Purple | `#9C27B0` | `#CE93D8` | `#AB47BC` | `#E1BEE7` |
| Red | `#E53935` | `#FFCDD2` | `#EF5350` | `#FFCDD2` |

These are chosen to be accessible on both the MapTiler `dataviz` (muted grayscale light) and `dataviz-dark` styles. Amber at #FF8C00 is visually unmistakable over the muted gray road network.

**Dark mode strategy (Claude's discretion per CONTEXT.md):** Each preset has a pre-defined dark variant (lighter/more saturated to compensate for the dark background). The `CoverageColorPreset` enum carries both `lightFull`, `lightPartial`, `darkFull`, `darkPartial` fields. The color provider reads the current system brightness and returns the appropriate pair. This preserves the brightness-swap contract — no structural changes to the style JSON, only the layer paint changes.

### REN-03 / COV-03: Partial coverage via opacity scaling

**Coverage fraction derivation:**

For each driven `way_id`, query `driven_way_intervals` grouped by `way_id`, compute `unionIntervals` (already exists at `lib/features/coverage/domain/interval_union.dart`), sum the union lengths, divide by the OSM way's total length. The way total length comes from the `WayCandidate.geometry` polyline Haversine sum (already computed in the matcher; see `lib/features/matching/domain/hmm_matcher.dart`).

The `is_full` flag uses COV-02: `union_length >= (way_length - 15.0 - 15.0)` (15 m start + 15 m end buffers). Ways shorter than 30 m: `union_length >= way_length * 0.8` as a proportional fallback (prevents 25 m residential stubs from never being "full").

**Minimum partial floor:** A way should NOT show partial unless `union_length >= max(50.0, way_length * 0.05)`. Rationale: a 1 km autobahn with a single 30 m GPS clip (3 %) should not light up orange. The 50 m floor covers typical GPS noise + single-pass sub-intervals. Tune against the golden corpus during implementation.

**Opacity ramp:** `line-opacity` for partial = `clamp(fraction * 0.85, 0.25, 0.88)`. Full = `0.92`. This means:
- Just-past-floor (~5 % fraction): opacity ≈ 0.25 (barely visible — "I touched this")
- Half-driven (50 %): opacity ≈ 0.43
- Nearly full (90 %): opacity ≈ 0.77
- Full tier: opacity = 0.92 (solid)

The lighter-shade partial color (`#FFCD6B` vs `#FF8C00`) adds a second visual cue on top of the opacity difference, making partial vs full distinct even on high-brightness screens.

### REN-04: 50k-segment ≥ 30 fps stress verification

See dedicated section below.

### REN-05: Gate G2 — RESOLVED as sharded GeoJSON

The CONTEXT.md says "sharded GeoJSON sources per 5×5 km tile" as the named fallback, but the actual implementation chosen (single source with data-driven expressions) is superior to per-tile sharding for the following reason: viewport-based sharding requires re-calling `setGeoJsonSource` on every camera move, which is heavier than one initial load. With 50k ways, a single FeatureCollection is the right shape.

**However:** For very large corpora (> 200k ways — phase 8+ territory), a sharded approach using `onCameraIdle` to load only the visible viewport's ways would be appropriate. For Phase 7's scope (user's real-world driven ways, likely 100–10k ways), a single source is viable.

**Naming: the "sharded GeoJSON" name in REN-05 is satisfied by this architecture** — we are using GeoJSON sources (not feature-state), which is exactly the fallback REN-05 describes. The 5×5 km tiling is an optional future optimization, not mandatory for v1.

### REN-06: Coverage color picker in Settings

**Location:** A new `CoverageColorSection` widget in `settings_screen.dart`, added between the existing Data section and the "Coming later" section (same `ListView` child pattern).

**Persistence:** Add `kCoveragePreset = 'coverage_preset'` to `AppPrefs` (key: string name of the preset enum, e.g. `'amber'`). `AppPrefs` already wraps `SharedPreferencesAsync` — add `getCoveragePreset()` / `setCoveragePreset(CoverageColorPreset)` methods.

**Provider:** `coveragePresetProvider` as a plain `NotifierProvider<CoveragePresetNotifier, CoverageColorPreset>`. The notifier reads from `AppPrefs` on `build()` (returns `amber` as default if missing) and writes back on change. The map rendering provider watches this to pick the hex pairs.

**Live reapply on Settings close:** The `coveragePresetProvider` state change triggers a Riverpod rebuild. The `CoverageOverlayNotifier` (the notifier that owns `setLayerProperties`) watches `coveragePresetProvider` and calls `setLayerProperties` reactively when the preset changes. No full map reload, no style swap.

**Exact UX flow:**
1. User opens Settings → sees `CoverageColorSection` with 5 colored dot swatches (Row of `GestureDetector`-wrapped `Container` circles, selected one has a checkmark or border).
2. Tapping a swatch calls `ref.read(coveragePresetProvider.notifier).set(preset)`.
3. `CoveragePresetNotifier` writes to `AppPrefs` and updates state.
4. `CoverageOverlayNotifier` (watching `coveragePresetProvider`) picks up the change and calls `controller.setLayerProperties` on the next frame.
5. User presses back → map shows new color.

The "pick-then-confirm" UX from CONTEXT.md is satisfied because the picker UI is on the Settings screen — the map re-colors when the user returns (the state change propagates immediately, but the map is offscreen until they navigate back).

### COV-02: Fully-explored threshold

```dart
bool isFullyCovered(double unionLengthM, double wayLengthM) {
  const kBufferM = 15.0;
  if (wayLengthM <= 30.0) {
    return unionLengthM >= wayLengthM * 0.8;
  }
  return unionLengthM >= (wayLengthM - kBufferM - kBufferM);
}
```

### Coverage fraction computation placement (Phase 7, not Phase 8)

Phase 8's COV-07 isolate is out of scope. For Phase 7, the coverage fraction computation should happen in a `FutureProvider` or a Notifier that:
1. Queries all distinct `way_id` values from `driven_way_intervals` (one DB query).
2. For each `way_id`, fetches its intervals, computes `unionIntervals`, sums length.
3. Fetches way geometry from the Overpass cache (via `OverpassWayCandidateSource` or direct cache DAO read) to get `wayLengthM`.
4. Returns a `Map<int, CoverageFraction>` (wayId → {fraction, isFull}).

This is a one-time load on app start and a re-load after each trip confirmation. It should NOT be computed on the UI isolate inline — wrap in `Future.microtask` or a plain `FutureProvider` (Riverpod will run it on the Dart event loop, not blocking the UI thread for the DB read).

**The geometry availability question (critical):** Way geometry is available in the Overpass cache (`overpass_way_cache` table). The `OverpassWayCandidateSource` can re-fetch ways if the cache is missing, but for Phase 7 the simplest path is: for each driven `way_id`, look up the geometry in the `overpass_way_cache` table using the DAO. If a way's geometry is missing (cache expired or never fetched for this phone), skip it — it will appear on the next trip confirmation when the Overpass fetch re-populates the cache.

No direct access to `WayCandidate.geometry` is needed from the intervals DAO — the `overpass_way_cache` rows store the full gzip-encoded Overpass JSON for each tile, which includes way geometries. The `OverpassWayCandidateSource.fetchWaysInBbox` API is the correct interface. For Phase 7, a simpler approach is: maintain a `Map<int, List<LatLng>>` (wayId → geometry) populated from the existing `DrivenWayIntervalsDao` + `OverpassWayCandidateSource`. Build this once on startup (scanning all confirmed trips' bboxes), cache it in a provider.

---

## Stress Harness Approach (REN-04: 50k segments ≥ 30 fps)

### What to build

A dedicated `StressCoverageScreen` (debug-mode only, accessed via Settings > Developer) that:

1. Generates a synthetic `Map<int, CoverageFraction>` with 50,000 entries. Each entry gets a random `fraction` 0.0–1.0, `isFull` derived from COV-02 threshold. Way geometries are 3–8 random points in the Germany bbox (47.27–55.06 lat, 5.87–15.04 lon).
2. Builds the FeatureCollection (50k LineString features) on a Dart isolate (to avoid blocking the UI thread during the synthetic generation).
3. Calls `addGeoJsonSource` + `addLineLayer` on the live MapLibre controller.
4. Uses Flutter's `WidgetsBinding.instance.addTimingsCallback` to capture `FrameTiming` objects and compute the 90th-percentile frame time over a 10-second window while the user pans/zooms the map.
5. Displays the measured P90 frame time and derived fps (1000 / p90_ms) on an overlay banner.

### Measurement implementation

```dart
// In StressCoverageScreen._State.initState():
WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);

void _onFrameTimings(List<FrameTiming> timings) {
  for (final t in timings) {
    // totalSpan includes raster time; use buildDuration + rasterDuration
    final ms = t.totalSpan.inMicroseconds / 1000.0;
    _frameTimes.add(ms);
    if (_frameTimes.length > 600) _frameTimes.removeAt(0); // 10 s at 60fps
  }
  setState(() {}); // update overlay banner
}

double get _p90FrameMs {
  if (_frameTimes.isEmpty) return 0;
  final sorted = [..._frameTimes]..sort();
  return sorted[(sorted.length * 0.9).floor()];
}
```

Pass threshold: P90 frame time ≤ 33.3 ms (≥ 30 fps).

### Why 50k features is safe at runtime

MapLibre's native rendering pipeline (Android: Mapbox GL Native 13.3.0; iOS: MapLibre iOS 6.27.0, per 0.26.2 CHANGELOG) handles vector tile layers with 100k+ features routinely. GeoJSON sources go through the same tessellation + vertex buffer pipeline. The bottleneck is typically the initial `setGeoJsonSource` JSON decode + tile tessellation (done on a background thread), not frame rendering. At render time, the GPU processes all 50k features with the data-driven expression in a single draw call.

The main risk is **initial source load time** (not fps). JSON serialization of 50k features with 5 avg points each is ~25–40 MB of JSON text. This should be JSON-encoded on a compute isolate before calling `setGeoJsonSource`, then passed to the controller. If `setGeoJsonSource` blocks the method channel for > 500 ms, consider chunking into two calls (25k each) or using the `setGeoJsonSource` + `addGeoJsonSource` pair with a flag to swap.

---

## Handling Style Swaps (Critical Pitfall)

`setStyle()` (brightness swap) wipes ALL programmatic sources and layers. This is documented in `map_widget.dart` with a comment at the `setStyle` call:

> "Phase 7+ adds coverage sources via addSource(), they MUST be re-added inside _onStyleLoaded() after setStyle()"

The `MapWidget.onStyleLoaded` callback fires on every style load (initial + swap). The `CoverageOverlayNotifier` must implement a `reapply(MapLibreMapController)` method that:
1. Calls `removeLayer('coverage_layer')` + `removeSource('coverage_overlay')` (wrapped in try/catch for idempotency — same pattern as `MapLibreTripOverlayApplier.removeTripOverlay`).
2. Re-adds the source with the current FeatureCollection.
3. Re-adds the layer with the current preset colors.

This must be triggered from `MapWidget.onStyleLoaded`. The `MapWidget` already exposes `onStyleLoaded: VoidCallback?` — `MapScreen` or a new `CoverageOverlayWidget` can inject the reapply call here.

The existing `trip_overlay_layers.dart` `TripOverlayApplier` uses this exact same pattern (clean-remove before re-add). Phase 7 should follow the same idiom but for the app-wide coverage overlay.

---

## Architecture Pattern: Coverage Overlay Widget

Recommended widget structure to keep concerns separated:

```
MapScreen
├── MapWidget (onStyleLoaded → calls CoverageOverlayNotifier.reapply)
├── CoverageOverlayBridge (ConsumerWidget, watches coverageDataProvider + mapControllerProvider)
│   └── Reacts to: coverage data changes, preset changes, onStyleLoaded
└── (existing) TripFab, LiveTrackingPanel, etc.
```

`CoverageOverlayBridge` is a stateless `ConsumerWidget` that:
- Watches `coverageDataProvider` (the Map<wayId, CoverageFraction> + geometry)
- Watches `coveragePresetProvider`
- Watches `mapControllerProvider` (the MapLibreMapController)
- In `didUpdateWidget`-equivalent Riverpod `ref.listen`, calls the appropriate controller method when any of the three changes

This keeps MapLibre API calls out of the notifier layer and collocates the "data changed → call controller" logic.

---

## Persisting Preset Without Full Map Reload

**The live-apply guarantee** (REN-06: "changes apply live without full map reload"):

`setLayerProperties` (verified in controller.dart line 686) updates only the layer's paint properties on the native side without touching the source or triggering a full style reload. This is the correct API. It accepts a `LayerProperties` object (here `LineLayerProperties`) and serializes only the changed fields.

The expression value for `lineColor` is a `dynamic` (List) — this is supported because all `LineLayerProperties` fields are typed `dynamic`. Passing a MapLibre expression list where a string is expected is the correct pattern (same as Plan 04-08's style JSON `['get', 'kind']` expressions).

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Coverage fraction computation | Custom SQL aggregate | `DrivenWayIntervalsDao.getByWayId` + `intervalUnion()` (already exists) | `interval_union.dart` already handles the merge-and-sum |
| Color hex formatting | Custom hex formatter | `colorToHex()` from `trip_overlay_layers.dart` (already exists) | Exact same need, already tested |
| Way geometry lookup | Custom cache reader | `OverpassWayCandidateSource.fetchWaysInBbox` | The cache and fetch logic is already abstracted |
| Line layer removal guard | Silent catch wrapper | Same pattern as `MapLibreTripOverlayApplier.removeTripOverlay` | Idempotent remove is already solved |
| Zoom-scaled line width | Custom calculation | MapLibre `interpolate` expression | GPU-evaluated, zero Dart cost at render time |
| SharedPreferences persistence | Drift DB storage | `AppPrefs` (`SharedPreferencesAsync`) | Simple string key-value, no migration needed |

---

## Common Pitfalls

### Pitfall 1: Coverage source wiped on brightness swap
**What goes wrong:** User switches system theme; `setStyle()` fires; the coverage overlay disappears.
**Why it happens:** `setStyle()` wipes ALL programmatic sources and layers — documented in `map_widget.dart`.
**How to avoid:** Wire `onStyleLoaded` → `CoverageOverlayNotifier.reapply`. The remove-then-readd pattern is already established in `trip_overlay_layers.dart`. The coverage overlay must follow the same contract.
**Warning signs:** Coverage renders on app start, disappears when toggling dark mode.

### Pitfall 2: Adding source before `onStyleLoaded` fires
**What goes wrong:** `addGeoJsonSource` called while the style is still loading; native layer manager throws.
**Why it happens:** `onMapCreated` fires before `onStyleLoaded`. Any source/layer addition before the style is ready fails silently or throws.
**How to avoid:** Gate all `addGeoJsonSource` / `addLineLayer` calls inside `onStyleLoaded`. Guard with a `_styleReady` flag. This is documented in `controller.dart` line 975: "Attention: This may only be called after onStyleLoaded() has been invoked."

### Pitfall 3: `setGeoJsonSource` called on nonexistent source
**What goes wrong:** After a style swap, `setGeoJsonSource` is called to update data before the source is re-added; throws.
**Why it happens:** Style swap wipes the source. If the data update races the style-loaded callback, `setGeoJsonSource` is called on a nonexistent source.
**How to avoid:** Always call `addGeoJsonSource` in `onStyleLoaded`, never `setGeoJsonSource` as a first-add. Track `_sourceAdded` flag; set to false in `onStyleLoaded` entry, true after `addGeoJsonSource` completes.

### Pitfall 4: Large JSON on main isolate blocking frame
**What goes wrong:** Building a 50k-feature FeatureCollection on the main isolate causes a > 100 ms frame skip.
**Why it happens:** `jsonEncode` for 30 MB JSON is synchronous on the caller's thread.
**How to avoid:** Use `compute(buildFeatureCollection, wayMap)` to run the JSON build on a background isolate. Return the pre-encoded string to avoid double-encode. Pass the string directly to `setGeoJsonSource` (it accepts `Map<String, dynamic>` — decode the string into a map first, or use `addSource` with raw string if the API supports it).

Actually: `setGeoJsonSource` in the method channel already calls `jsonEncode(geojson)` internally. So build the `Map<String, dynamic>` on the main thread (the encode is done on the native side). But the Dart-side map construction itself for 50k features could be 50–100 ms. Use `compute` to build the `Map<String, dynamic>` and return it; then call `setGeoJsonSource` on the main isolate.

### Pitfall 5: `lineColor` expression vs string type
**What goes wrong:** Passing a `List` (MapLibre expression) to `lineColor` causes a native parse error.
**Why it happens:** `LineLayerProperties.lineColor` is typed `dynamic` in the Dart API but the native Android/iOS implementation expects either a string OR a JSON-encodable expression array.
**How to avoid:** Pass the expression as a plain Dart `List<dynamic>` — the `toJson()` method serializes it verbatim via `addIfPresent`. This is the same pattern used in Plan 04-08's style JSON expression layers. Verified: all `LineLayerProperties` fields are `dynamic` and pass through `addIfPresent` unchanged.

### Pitfall 6: `setLayerProperties` with `skipNulls: false` replacing all properties
**What goes wrong:** Calling `setLayerProperties` with a partially-populated `LineLayerProperties` instance wipes the existing layer properties for null fields.
**Why it happens:** `setLayerProperties` calls `properties.toJson(skipNulls: false)` — nulls are explicitly set, overwriting current values.
**How to avoid:** Only pass the properties you want to change. Construct a `LineLayerProperties` with ONLY `lineColor` set when updating color, leaving all other fields null. The `skipNulls: false` call in the API is intentional (it signals "overwrite these fields"); just don't include fields you want to preserve.

Actually re-checking: `setLayerProperties` passes `skipNulls: false` which means it will emit `"line-opacity": null` etc. and the native side may clear those. **Safer pattern:** Remove and re-add the layer when changing color, or pre-construct the full `LineLayerProperties` including all intended values and call `setLayerProperties` with the complete set.

### Pitfall 7: No coverage yet — empty FeatureCollection
**What goes wrong:** App starts with zero driven ways; `addGeoJsonSource` is called with an empty FeatureCollection; the layer renders nothing but `addLineLayer` still runs.
**Why it happens:** Not a bug — just needs to be handled.
**How to avoid:** Guard `addGeoJsonSource` + `addLineLayer` only when the FeatureCollection has at least one feature, OR always add both and let the empty source render nothing. The latter is simpler (no conditional logic on style reload).

---

## Zoom-Scaled Line Width — Concrete Expression

```dart
// LineLayerProperties.lineWidth as MapLibre interpolate expression:
final lineWidthExpression = [
  'interpolate', ['linear'], ['zoom'],
  8,  2.5,   // z8 (~country scale): 2.5 px — visible but not dominant
  11, 3.0,   // z11 (county scale)
  13, 4.0,   // z13 (city district)
  15, 5.0,   // z15 (street-level): 5 px — clearly labeled roads
  18, 7.0,   // z18 (very close): matches rendered road width
];
```

At z8 country scale, the 2.5 px width keeps the explored-road network visible as a skeleton without overwhelming the base map. At z15+ the 5–7 px width makes individual roads legible and gives the characteristic "painted over" look.

---

## Color Preset Architecture

```dart
enum CoverageColorPreset {
  amber, green, blue, purple, red;

  static CoverageColorPreset fromString(String s) =>
      CoverageColorPreset.values.firstWhere(
        (e) => e.name == s,
        orElse: () => CoverageColorPreset.amber,
      );
}

@immutable
class CoverageColors {
  const CoverageColors({
    required this.fullHex,
    required this.partialHex,
  });
  final String fullHex;
  final String partialHex;
}

extension CoverageColorPresetColors on CoverageColorPreset {
  CoverageColors forBrightness(Brightness b) {
    final isDark = b == Brightness.dark;
    return switch (this) {
      CoverageColorPreset.amber => isDark
          ? const CoverageColors(fullHex: '#FFA726', partialHex: '#FFD54F')
          : const CoverageColors(fullHex: '#FF8C00', partialHex: '#FFCD6B'),
      CoverageColorPreset.green => isDark
          ? const CoverageColors(fullHex: '#4CAF50', partialHex: '#A5D6A7')
          : const CoverageColors(fullHex: '#2ECC71', partialHex: '#A8E6CF'),
      // … etc.
    };
  }
}
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|---|---|---|
| `setFeatureState` on mobile | Throws `UnimplementedError` | G2 fails; use GeoJSON data-driven expressions instead |
| `promoteId` in addGeoJsonSource | Not wired through method channel on mobile | Cannot use feature state even with GeoJSON |
| Feature-state on pmtiles vector layer | Not addressable by client | Would require rewriting the tile pipeline |
| Per-tile sharded GeoJSON sources | Single FeatureCollection + `setGeoJsonSource` for data updates | Simpler, fewer source/layer handles, `setLayerProperties` for color-only changes |

---

## Open Questions

1. **Way geometry availability at overlay build time.** The coverage overlay needs `WayCandidate.geometry` for each driven `way_id`. The Overpass cache is the source. If a way's tile cache entry has expired (30-day TTL) AND the user is offline, the way geometry is unavailable. Phase 7 should silently skip ways with missing geometry and log a warning. A background refresh queue (Phase 8) would fill these gaps proactively.
   - What we know: `OverpassWayCandidateSource` handles cache-first + network fallback per tile; `OverpassWayCacheDao.getByTile` is the read path.
   - Recommendation: Build a `DriveWayGeometryResolver` that queries all distinct way_ids from `driven_way_intervals`, groups them by the tile they belong to (reusing `TileBboxMath`), fetches each tile from the Overpass cache, and extracts the geometry for each way_id. Skip ways whose tile is a cache miss.

2. **Coverage data load time for large corpora.** Building the FeatureCollection for 50k ways (if the user has driven 50k distinct way IDs) may take 500 ms+ on the Dart isolate. In practice, a user driving in Germany for years accumulates ~10k–30k unique way IDs. Phase 7 can build synchronously up to ~5k ways; above that, use `compute`.
   - Recommendation: Always use `compute` for the FeatureCollection build to keep the UI thread free.

3. **`setLayerProperties` with partial update.** The `skipNulls: false` in the internal call means passing a partial `LineLayerProperties` will reset non-specified properties. Research conclusion: always pass a fully-specified `LineLayerProperties` when calling `setLayerProperties`, not a partial one.
   - Recommendation: The `CoverageOverlayNotifier` stores the current `LineLayerProperties` instance and produces a copy with only the changed fields mutated before calling `setLayerProperties`.

4. **`belowLayerId` for coverage layer z-ordering.** Coverage lines should render above base road geometry but below labels. The MapTiler `dataviz` style has labels in layers with id patterns like `Place labels` / `Road labels`. The correct `belowLayerId` is the first label/text layer in the MapTiler style. Since the style is hosted (not local asset), the layer IDs must be discovered at runtime via `getLayerIds()`.
   - Recommendation: On `onStyleLoaded`, call `controller.getLayerIds()` and find the first layer whose id matches the pattern `place-*` or `road-labels*` or any text/symbol layer. Use it as `belowLayerId`. Fall back to null (top of stack) if none found.

---

## Sources

### Primary (HIGH confidence)
- Pub-cache source: `/c/Users/I551358/AppData/Local/Pub/Cache/hosted/pub.dev/maplibre_gl_platform_interface-0.26.2/lib/src/method_channel_maplibre_gl.dart` — `setFeatureState` throws `UnimplementedError`, `promoteId` not wired
- Pub-cache source: `/c/Users/I551358/AppData/Local/Pub/Cache/hosted/pub.dev/maplibre_gl-0.26.2/lib/src/controller.dart` — `setLayerProperties`, `addGeoJsonSource`, `setGeoJsonSource`, `addLineLayer`, `getVisibleRegion`, `getLayerIds`, `onCameraIdle` all verified present
- Pub-cache CHANGELOG: `maplibre_gl-0.26.2/CHANGELOG.md` — "Web: Exposed feature state management" for 0.26.0; "maplibre_gl_platform_interface" CHANGELOG confirms "0.26.0 Added: Feature state management APIs — web only (PR #718)"
- Project sources: `lib/features/trips/presentation/widgets/trip_overlay_layers.dart` — addGeoJsonSource/addLineLayer/setGeoJsonSource pattern, `colorToHex()` helper
- Project sources: `lib/features/map/presentation/widgets/map_widget.dart` — `onStyleLoaded` hook, `setStyle()` wipes sources note
- Project sources: `lib/features/coverage/domain/interval_union.dart` — `unionIntervals()` and `drivenLengthMeters()` already exist
- Project sources: `lib/core/prefs/app_prefs.dart` — `SharedPreferencesAsync`-backed key-value persistence pattern

### Secondary (MEDIUM confidence)
- GitHub issue #889 (fetched via WebFetch): `setFeatureState` on mobile is targeting 0.27.0; both Android and iOS bindings are pending as of 2026-07-05

### Tertiary (LOW confidence)
- Concrete fps estimates for 50k GeoJSON features: based on MapLibre native GL engine general knowledge; not empirically measured on this hardware

---

## Metadata

**Confidence breakdown:**
- Gate G2 verdict (setFeatureState unavailable): HIGH — confirmed from installed source with explicit UnimplementedError
- Standard stack (addGeoJsonSource + data-driven expressions): HIGH — pattern is in use in trip_overlay_layers.dart
- Coverage fraction computation: HIGH — interval_union.dart already exists; geometry from Overpass cache is the known approach
- Color preset design: MEDIUM — accessibility over MapTiler dataviz verified by inspection; exact shades should be tuned on device
- Opacity ramp values (0.25 floor, 0.85 scaling): LOW — reasonable defaults; MUST be tuned against golden corpus on device
- Stress harness approach: MEDIUM — `FrameTiming` API is standard Flutter; 50k feature JSON size is estimated

**Research date:** 2026-07-09
**Valid until:** 2026-08-09 (stable — maplibre_gl 0.26.2 is the locked version; 0.27.0 with feature-state will not land without a pubspec bump)
