# Phase 2: Map + Glass Shell — Research

**Researched:** 2026-07-03
**Domain:** MapLibre GL Flutter + PMTiles + Liquid Glass shell + platform-view rendering + location display
**Confidence:** HIGH for map/location/gestures/PMTiles; MEDIUM for Liquid Glass over platform-view (G1); HIGH for Gate G2 outcome (feature-state confirmed broken on Android/iOS)

---

## Summary

Phase 2 adds a fully functional offline map screen with a Liquid Glass chrome. The primary technology is `maplibre_gl` ^0.26.2 with Protomaps-sourced PMTiles as the tile backend, driven by project-owned style JSON assets. The Liquid Glass shell uses `liquid_glass_renderer` 0.2.0-dev.4 + `liquid_navbar` 2.0.7.

Two gates from the prior research have been **confirmed** in this session:

- **G1 (BackdropFilter over platform view):** Android is confirmed broken as of May 2026 (Flutter issue #185497 OPEN, last updated 2026-05-08). iOS was historically fixed (issue #43902 CLOSED). Practical implication: `LiquidGlass`/`BackdropFilter` blur will not work over the MapLibre `UiKitView`/`AndroidView` on Android. Plan for the fallback from day one.
- **G2 (feature-state on Android/iOS):** Confirmed by source code — `setFeatureState`, `getFeatureState`, `removeFeatureState` all throw `UnimplementedError` on iOS/Android in `maplibre_gl` 0.26.2. This affects Phase 7 (coverage rendering), not Phase 2. Document clearly so Phase 7 plans the sharded-GeoJSON fallback from the start.

Map user-location (blue dot + heading + accuracy ring) is handled entirely by MapLibre's built-in engine via `myLocationEnabled: true` — no extra location package is needed. The `location` package in the examples is only for requesting permission before calling `myLocationEnabled`; `permission_handler` (already planned for Phase 3) is the right tool here.

Dark-mode style switching is done by calling `controller.setStyle(newStylePath)` when the system brightness changes. The `MediaQuery.platformBrightness` or `WidgetsBindingObserver.didChangePlatformBrightness` provides the trigger.

**Primary recommendation:** Start Phase 2 with a G1 spike (Plan 01) on real devices before committing to any glass layout. Simultaneously build the map+PMTiles integration (Plan 02). Defer glass shell layout work until G1 is resolved.

---

## Standard Stack

### Core (already in pubspec or locked)

| Library | Version | Purpose | Notes |
|---------|---------|---------|-------|
| `maplibre_gl` | ^0.26.2 | Map rendering, user location, gestures, style | Official MapLibre publisher; last release 13 days ago |
| `pmtiles` | ^2.2.0 | PMTiles Dart library (peer dep, not direct) | MapLibre handles pmtiles:// protocol internally; direct use only if reading tile bytes manually |
| `liquid_glass_renderer` | 0.2.0-dev.4 | Glass widget shader | Pin exact version — dev release, 7 months ago |
| `liquid_navbar` | 2.0.7 | Bottom nav pill | Requires `flutter_riverpod ^3.0.3`; compatible with our ^3.3.2 |
| `flutter_riverpod` | ^3.3.2 | State management | Plain `Provider`/`Notifier`, no codegen |
| `permission_handler` | ^12.0.3 | Location permission request during onboarding | Not yet in pubspec — add in Phase 2 |

### New Dependencies to Add in Phase 2

```yaml
dependencies:
  maplibre_gl: ^0.26.2
  liquid_glass_renderer: 0.2.0-dev.4   # exact pin
  liquid_navbar: ^2.0.7
  permission_handler: ^12.0.3
```

Note: `pmtiles` Dart package does NOT need to be in pubspec — MapLibre handles the `pmtiles://` protocol internally via its native engines. The pmtiles package is only needed if parsing tile bytes in Dart directly (not required for Phase 2).

### Supporting Tools (development only, not pubspec)

| Tool | Purpose |
|------|---------|
| Protomaps Planetiler (Java CLI) | Generate regional `.pmtiles` from OSM PBF |
| `pmtiles` CLI (Go) | Inspect/convert PMTiles files; extract bounding box |

---

## Architecture Patterns

### Recommended File Structure for Phase 2

```
lib/
├── core/
│   └── theme/
│       ├── app_theme.dart            # ThemeData light + dark (already started in P1)
│       └── liquid_glass_settings.dart # LiquidGlassSettings singleton
├── features/
│   └── map/
│       ├── data/
│       │   └── location_repository.dart  # Wraps permission_handler + read-once position
│       ├── domain/
│       │   └── camera_state.dart         # Freezed: lat/lng/zoom/bearing/isFollowing
│       └── presentation/
│           ├── map_screen.dart           # Replaces PlaceholderHomeScreen at '/'
│           ├── widgets/
│           │   ├── map_widget.dart       # MapLibreMap widget wrapper
│           │   ├── focus_area_pill.dart  # Top stub pill
│           │   ├── bottom_nav_pill.dart  # liquid_navbar BottomNavScaffold
│           │   ├── trip_fab.dart         # Stub FAB (bottom-right)
│           │   ├── settings_button.dart  # Top-left glass gear button
│           │   └── compass_button.dart   # Appears on rotation
│           └── providers/
│               ├── map_controller_provider.dart   # Notifier<MapLibreMapController?>
│               └── camera_state_provider.dart     # Notifier<CameraState>
assets/
├── map_style_light.json              # Google Maps-light style (Protomaps-based)
├── map_style_dark.json               # Google Maps-dark style (Protomaps-based)
└── tiles/
    └── dev_berlin.pmtiles            # ~5-15 MB dev tile for testing (downloaded separately)
```

### Pattern 1: MapLibre + PMTiles Asset Loading

The style JSON lives in Flutter assets and uses the `pmtiles://` protocol for the tile source URL. MapLibre handles this natively — no Dart PMTiles code needed.

```json
// assets/map_style_light.json
{
  "version": 8,
  "glyphs": "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf",
  "sources": {
    "protomaps": {
      "type": "vector",
      "attribution": "<a href='https://github.com/protomaps/basemaps'>Protomaps</a> © <a href='https://openstreetmap.org'>OpenStreetMap</a>",
      "url": "pmtiles://https://build.protomaps.com/YYYYMMDD.pmtiles"
    }
  },
  "layers": [ ... ]
}
```

For a locally bundled `.pmtiles` file, reference it as a Flutter asset path directly:

```json
"url": "pmtiles://assets/tiles/dev_berlin.pmtiles"
```

(Android resolves `assets/` via `asset://` scheme internally; iOS via the bundle resource path. The `pmtiles://` prefix signals the MapLibre engine to use its built-in PMTiles reader.)

Loading the style in Flutter:
```dart
// Source: maplibre_gl example app (maplibre_gl_example/lib/examples/docs/doc_pmtiles.dart)
MapLibreMap(
  styleString: 'assets/map_style_light.json',  // Flutter asset path
  initialCameraPosition: const CameraPosition(
    target: LatLng(52.52, 13.40),  // Berlin
    zoom: 15,
  ),
  tiltGesturesEnabled: false,       // Phase 2: flat 2D only
  rotateGesturesEnabled: true,
  scrollGesturesEnabled: true,
  zoomGesturesEnabled: true,
  myLocationEnabled: true,          // Phase 2 ONLY if location permission granted
  myLocationTrackingMode: MyLocationTrackingMode.tracking,
  myLocationRenderMode: MyLocationRenderMode.compass,  // blue dot + heading cone
  compassEnabled: true,             // shows on rotation, hides when north
  onMapCreated: _onMapCreated,
  onStyleLoadedCallback: _onStyleLoaded,
  onCameraTrackingDismissed: _onFollowModeExited,
)
```

### Pattern 2: Riverpod Map Controller (No Codegen)

```dart
// Source: Riverpod 3.x docs pattern; pub.dev/documentation/flutter_riverpod

// State object — immutable
@freezed
class CameraState with _$CameraState {
  const factory CameraState({
    required double latitude,
    required double longitude,
    required double zoom,
    @Default(0.0) double bearing,
    @Default(false) bool isFollowing,
  }) = _CameraState;
}

// Controller holder — nullable until map ready
class MapControllerNotifier extends Notifier<MapLibreMapController?> {
  @override
  MapLibreMapController? build() => null;

  void attach(MapLibreMapController controller) => state = controller;

  void detach() => state = null;
}

final mapControllerProvider =
    NotifierProvider<MapControllerNotifier, MapLibreMapController?>(
  MapControllerNotifier.new,
);

// Camera state
class CameraStateNotifier extends Notifier<CameraState> {
  @override
  CameraState build() => const CameraState(
    latitude: 0,
    longitude: 0,
    zoom: 15,
  );

  void updateFromMap(CameraPosition position) {
    state = CameraState(
      latitude: position.target.latitude,
      longitude: position.target.longitude,
      zoom: position.zoom,
      bearing: position.bearing,
      isFollowing: state.isFollowing,
    );
  }

  void setFollowing(bool following) =>
      state = state.copyWith(isFollowing: following);
}

final cameraStateProvider =
    NotifierProvider<CameraStateNotifier, CameraState>(
  CameraStateNotifier.new,
);
```

### Pattern 3: Dark Mode Style Switching

```dart
// In MapWidget — observe brightness, call setStyle on change
class MapWidget extends ConsumerStatefulWidget { ... }

class _MapWidgetState extends ConsumerState<MapWidget>
    with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    final controller = ref.read(mapControllerProvider);
    if (controller == null) return;
    final isDark = WidgetsBinding.instance.platformDispatcher.platformBrightness
        == Brightness.dark;
    // Soft fade: AnimatedOpacity wrapper on the whole map, then setStyle
    controller.setStyle(
      isDark ? 'assets/map_style_dark.json' : 'assets/map_style_light.json',
    );
  }
```

Note: `setStyle()` triggers a full style reload which includes re-rendering all tiles. A soft fade/crossfade can be achieved by wrapping MapLibreMap in an `AnimatedOpacity` that fades to 0, triggers `setStyle`, then fades back to 1 on `onStyleLoadedCallback`.

### Pattern 4: G1 Fallback — Glass over Map Without BackdropFilter

Since Android BackdropFilter over platform view is broken (issue #185497, OPEN as of 2026-05-08), the glass effect over the MAP AREA must not use `BackdropFilter`. Two viable approaches:

**Option A — FakeGlass / semi-transparent tinted overlay (RECOMMENDED for Phase 2):**

```dart
// FakeGlass from liquid_glass_renderer uses BackdropFilter internally,
// so it also fails over platform views on Android.
// Instead, use a Stack with a tinted, slightly blurred Flutter surface:

Widget _buildFallbackGlassPill(Widget child) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: BackdropFilter(
      // This blur only samples the Flutter layer ABOVE the platform view.
      // On Android, the map (platform view) shows opaque beneath.
      // On iOS, this may work if the platform view is composited into Flutter layer.
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.22),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
            width: 0.5,
          ),
          borderRadius: BorderRadius.circular(28),
        ),
        child: child,
      ),
    ),
  );
}
```

For Android, the blur sigma has zero effect on the map beneath, but the semi-transparent white tint + border still creates a visually acceptable "glass-like" pill. This IS the documented fallback.

**Option B — LiquidGlass on non-map areas only:**

Place the `LiquidGlassLayer` + `LiquidGlass` widgets ONLY on the portions of the screen that are purely Flutter content (i.e., no part of the glass overlaps the map area). In practice this means the glass pill floats above a solid-color area, not the map. Impractical for Phase 2's layout (all pills are over the map).

**G1 Spike Decision Tree:**
```
On iOS (real device):
  Does LiquidGlass with BackdropFilter show blur over the map? 
    YES → Use liquid_glass_renderer natively on iOS
    NO  → Use FallbackGlassPill on iOS too

On Android (real device):
  BackdropFilter is confirmed broken → Always use FallbackGlassPill

If LiquidGlass works on iOS but not Android:
  Use conditional: kIsIOS ? LiquidGlass(...) : FallbackGlassPill(...)
  Store result in LiquidGlassSettings.platformSupportsBlurOverMap
```

### Pattern 5: LiquidGlassSettings Singleton

Based on the `liquid_glass_renderer` API and the XFin reference pattern (inferred from requirements):

```dart
// lib/core/theme/liquid_glass_settings.dart
// Singleton controlling glass parameters across all glass components.
// Follows XFin's pattern: one shared settings object, no widget rebuilds for param changes.

class LiquidGlassSettings {
  LiquidGlassSettings._();

  static const LiquidGlassSettings instance = LiquidGlassSettings._();

  // G1 gate result — set once after spike validation
  bool platformSupportsBlurOverMap = false;  // default: fallback path

  // Glass visual parameters (tune per ui-ux-pro-max recommendations)
  double glassThickness = 20;
  double glassBlur = 10;
  double glassSaturation = 1.2;
  double glassBorderOpacity = 0.35;
  double glassBackgroundOpacity = 0.18;
  double pillBorderRadius = 28;

  // Light/dark variants
  Color lightGlassColor = const Color(0x30FFFFFF);  // white tint
  Color darkGlassColor = const Color(0x25000000);   // dark tint
}
```

In Riverpod: expose as `Provider<LiquidGlassSettings>` for testability.

### Pattern 6: location permission in onboarding

Phase 2 adds the location permission request to the existing `OnboardingScreen`. The permission should be requested before navigating to the map, and the map should degrade gracefully if denied.

```dart
// In OnboardingScreen, before the Continue button action:
Future<void> _requestLocationPermission() async {
  final status = await Permission.locationWhenInUse.request();
  // Store result; map adapts based on it
  // NOTE: iOS only asks once. On Android, user may deny permanently.
}
```

The `myLocationEnabled` flag on `MapLibreMap` can then be toggled based on permission status read via `Permission.locationWhenInUse.isGranted`.

### Anti-Patterns to Avoid

- **Never add a PMTiles source via `addSource()` in Dart.** The protocol handler only works when the source is declared in the style JSON itself — the native MapLibre engine sees the `pmtiles://` URL at style parse time.
- **Never use `BackdropFilter` over the MapLibreMap widget on Android.** Issue #185497 is OPEN; the filter samples only the Flutter compositor layer (nothing from the native map view).
- **Never call `setFeatureState` on Android/iOS.** It throws `UnimplementedError`. Use sharded GeoJSON or style JSON properties instead (Phase 7 concern, not Phase 2).
- **Never rebuild the `MapLibreMap` widget for theme changes.** Use `controller.setStyle()` instead; rebuilding the widget recreates the native map entirely (expensive).
- **Never use `MapLibreMap.useHybridComposition = true` on Android.** The official example comment says: "Hybrid composition is currently broken do not use." The example uses it only for Android SDK ≥ 29 to prevent a rendering regression, but with an explicit warning.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Location blue-dot display | Custom overlay with geolocator stream | `myLocationEnabled: true` on `MapLibreMap` | MapLibre's built-in location engine handles dot, accuracy ring, heading cone, follow mode natively; no separate package needed |
| PMTiles protocol handling | Dart http range-request reader | `pmtiles://` prefix in style JSON | MapLibre handles it via native engine on Android/iOS; zero Dart code |
| Style-loading from assets | Manual JSON reading + parsing | `styleString: 'assets/style.json'` | Supported natively; Android uses `asset://` under the hood |
| Compass button | Custom widget with heading tracking | `compassEnabled: true` on `MapLibreMap` | Built-in — shows when rotated, hides at north, tap snaps to north |
| Follow mode (tap-to-recenter) | Manual camera updates | `myLocationTrackingMode` + `updateMyLocationTrackingMode()` | MapLibre built-in — set `MyLocationTrackingMode.tracking` to follow; camera tracking dismissed callback fires when user pans away |
| Dark mode detection | Polling loop | `WidgetsBindingObserver.didChangePlatformBrightness` | Platform callback; no polling needed |
| Gesture locking (no tilt) | Blocking 2-finger gestures in GestureRecognizer | `tiltGesturesEnabled: false` on `MapLibreMap` | Constructor param; zero boilerplate |

---

## Common Pitfalls

### Pitfall 1: PMTiles bundled asset path syntax

**What goes wrong:** Bundled `.pmtiles` fails to load; map is blank or shows "source not found" error.

**Why it happens:** The URL inside the style JSON needs to correctly encode the asset path. Tested pattern from Android source code analysis:

- For remote files: `"url": "pmtiles://https://..."`
- For Flutter assets: `"url": "pmtiles://assets/tiles/dev_berlin.pmtiles"` (no leading slash)

Android maps the `assets/` prefix to `asset://` internally via `flutterAssets.getAssetFilePathByName`. iOS uses the bundle path. If the path is wrong, no error is thrown — the map just shows blank tiles.

**How to avoid:** Add `assets/tiles/` to pubspec.yaml flutter assets section. Use a CI-local test tile (e.g., download a 5-10 MB Monaco extract for quick CI) so the map renders without requiring network access.

**Warning signs:** Black or blank map tiles; `onStyleLoadedCallback` fires but no tiles appear.

### Pitfall 2: Hybrid Composition on Android

**What goes wrong:** App crashes or has severe rendering corruption on Android.

**Why it happens:** `MapLibreMap.useHybridComposition = true` is globally broken per the example app comment (2026-06-25 version of the code). The example toggles it for SDK ≥ 29, but with a "currently broken do not use" note.

**How to avoid:** Do NOT set `MapLibreMap.useHybridComposition`. Leave it at its default (`false`). This uses Virtual Display (default Android rendering mode) which is stable.

**Warning signs:** Transparent map, rendering artifacts, or immediate crash on Android.

### Pitfall 3: Glass blur jank in release mode (Impeller)

**What goes wrong:** Liquid Glass animations cause memory spikes and frame drops on real devices in profile/release mode.

**Why it happens:** Known Flutter bug — textures used in animated glass shapes are not disposed immediately, causing temporary heap spikes. Documented in `liquid_glass_renderer` README.

**How to avoid:**
- Minimize the number of animated glass shapes (Phase 2 has: bottom pill = 3 tabs + indicator, FAB, focus pill, settings button = ~6 shapes total — within the 16-shape limit)
- Do NOT animate glass shapes continuously (e.g., no pulsing glow on idle state)
- Keep `LiquidGlassLayer` coverage to specific overlay rects, not full-screen
- Profile on a real mid-range Android device (not emulator) before declaring Phase 2 done

**Warning signs:** DevTools memory graph showing sawtooth pattern during glass interactions; frame budget exceeded on Pixel 6 class devices.

### Pitfall 4: setStyle triggers onStyleLoadedCallback asynchronously

**What goes wrong:** Code runs against the old style after calling `setStyle()` — e.g., re-adding layers to a source that no longer exists.

**Why it happens:** `setStyle()` is fire-and-forget. The `onStyleLoadedCallback` fires on the new style. Any programmatic layer/source additions (like admin boundary overlays) must be re-added inside `onStyleLoadedCallback`.

**How to avoid:** Track "pending layer additions" in a list; flush them all inside `onStyleLoadedCallback`. Use a flag `_styleLoaded = false` in the map state before calling `setStyle`, `= true` in the callback.

### Pitfall 5: location permission and myLocationEnabled timing

**What goes wrong:** `myLocationEnabled: true` is set but no permission is granted → MapLibre silently fails to show the dot; or the dot flickers when permission is granted mid-session.

**Why it happens:** MapLibre's native location engine checks permission at the time `myLocationEnabled` becomes true. If permission was denied before the map widget is built, the map is created with location disabled.

**How to avoid:**
- Request `Permission.locationWhenInUse` during onboarding (before navigating to `/`)
- Build `MapLibreMap` with `myLocationEnabled: false` initially
- After permission check (async, in `initState`), rebuild via `setState` with `myLocationEnabled: true` if granted
- Watch `Permission.locationWhenInUse.status` via a `StreamProvider` to handle mid-session grants

### Pitfall 6: `location` package vs `permission_handler` conflict

**What goes wrong:** The `maplibre_gl` example uses the `location` package for permission. Adding both `location` and `permission_handler` to pubspec causes dependency conflicts or duplicate permission prompts.

**How to avoid:** Do NOT add the `location` package. The `maplibre_gl` plugin itself does NOT depend on `location` (verified in pubspec.yaml). The example's use of `location` is for permission UI only. Our project uses `permission_handler` which is sufficient.

### Pitfall 7: Style JSON glyphs from external server (offline concern)

**What goes wrong:** Labels disappear offline because the style references `https://demotiles.maplibre.org/font/...` for glyph rendering.

**Why it happens:** MapLibre style JSON requires a `glyphs` property for text rendering. The default Protomaps style points to an external URL.

**How to avoid:**
- Download a glyph font pack (e.g., Open Sans from `maplibre/maplibre-gl-js`) and bundle it as a Flutter asset
- OR use a Protomaps CDN glyphs URL that is pre-cached after first load
- For Phase 2 MVP: external glyphs are acceptable (Phase 2 is not a full offline test); document this as a known gap for Phase later
- For production: bundle glyphs at `assets/fonts/{fontstack}/{range}.pbf` and update style JSON

---

## Code Examples

### Complete MapLibreMap widget setup for Phase 2

```dart
// Source: maplibre_gl v0.26.2 source (maplibre_gl/lib/src/maplibre_map.dart)
// + GPS location example (maplibre_gl_example/lib/examples/basics/gps_location_page.dart)

MapLibreMap(
  // Style loaded from bundled asset — pmtiles:// handled by native engine
  styleString: _isDark ? 'assets/map_style_dark.json' : 'assets/map_style_light.json',

  // Camera: open at current location (Phase 2 override of MAP-07 persistence)
  initialCameraPosition: CameraPosition(
    target: _currentLocation ?? const LatLng(52.52, 13.40),  // fallback: Berlin
    zoom: 15,
  ),

  // Gestures: flat 2D (no tilt per CONTEXT.md)
  tiltGesturesEnabled: false,
  rotateGesturesEnabled: true,
  scrollGesturesEnabled: true,
  zoomGesturesEnabled: true,

  // Location display (requires myLocationEnabled: true AND permission granted)
  myLocationEnabled: _locationPermissionGranted,
  myLocationTrackingMode: _isFollowing
      ? MyLocationTrackingMode.tracking
      : MyLocationTrackingMode.none,
  myLocationRenderMode: MyLocationRenderMode.compass, // blue dot + heading cone

  // Compass: built-in, shows when rotated, tap = snap to north
  compassEnabled: true,
  compassViewPosition: CompassViewPosition.topRight,  // Claude's discretion

  // Location engine accuracy (Phase 2: no background, just display)
  locationEnginePlatforms: LocationEnginePlatforms.android(
    enableHighAccuracy: true,
    interval: 2000,     // 2s updates fine for display-only
    displacement: 5,    // 5m minimum movement
  ),

  // Camera position tracking (needed for focus-area pill and camera state)
  trackCameraPosition: true,

  // Callbacks
  onMapCreated: _onMapCreated,
  onStyleLoadedCallback: _onStyleLoaded,
  onUserLocationUpdated: _onUserLocationUpdated,
  onCameraTrackingDismissed: _onFollowModeDismissed,
  onCameraTrackingChanged: _onTrackingModeChanged,

  // Disable logo (custom attribution in UI instead)
  logoEnabled: false,
)
```

### PMTiles style JSON for Protomaps (light theme, minimal)

```json
{
  "version": 8,
  "glyphs": "https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf",
  "sprite": "https://protomaps.github.io/basemaps-assets/sprites/v4/light",
  "sources": {
    "protomaps": {
      "type": "vector",
      "attribution": "<a href='https://protomaps.com'>Protomaps</a> © <a href='https://openstreetmap.org'>OpenStreetMap</a>",
      "url": "pmtiles://assets/tiles/dev_berlin.pmtiles"
    }
  },
  "layers": [
    { "id": "background", "type": "background", "paint": { "background-color": "#f2f1ef" } },
    { "id": "earth", "type": "fill", "source": "protomaps", "source-layer": "earth",
      "paint": { "fill-color": "#e8e4df" } },
    { "id": "water", "type": "fill", "source": "protomaps", "source-layer": "water",
      "paint": { "fill-color": "#a8d5e5" } },
    { "id": "roads-highway", "type": "line", "source": "protomaps", "source-layer": "roads",
      "filter": ["in", "pmap:kind", "highway", "major_road"],
      "paint": { "line-color": "#fcd390", "line-width": ["interpolate", ["linear"], ["zoom"], 8, 1.5, 14, 6] } },
    { "id": "roads-minor", "type": "line", "source": "protomaps", "source-layer": "roads",
      "filter": ["in", "pmap:kind", "medium_road", "minor_road"],
      "paint": { "line-color": "#ffffff", "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.5, 15, 3] } },
    { "id": "buildings", "type": "fill", "source": "protomaps", "source-layer": "buildings",
      "paint": { "fill-color": "#dbd9d4", "fill-opacity": 0.7 } },
    { "id": "places-city", "type": "symbol", "source": "protomaps", "source-layer": "places",
      "filter": ["in", "pmap:kind", "city", "town"],
      "layout": { "text-field": ["get", "name"], "text-size": 13, "text-font": ["Noto Sans Regular"] },
      "paint": { "text-color": "#333", "text-halo-color": "#f2f1ef", "text-halo-width": 1.5 } }
  ]
}
```

**Protomaps source-layer names (Version 4 schema):**
`earth`, `water`, `landcover`, `landuse`, `buildings`, `roads`, `transit`, `places`, `pois`, `boundaries`

**Road filter for `roads` layer via `pmap:kind`:**
`highway`, `major_road`, `medium_road`, `minor_road`, `path`, `ferry`, `aerialway`

### Downloading a dev-area PMTiles for testing

Option A — use Protomaps CDN (requires network, rotating dates):
```
pmtiles://https://build.protomaps.com/20260625.pmtiles
```
Warning: dated builds expire after a few days. Not suitable for long-term development.

Option B — use stable Protomaps demo tile (recommended for CI):
```
pmtiles://https://demo-bucket.protomaps.com/v4.pmtiles
```
This is a stable demo planet build, suitable for development but has limited zoom detail in some regions.

Option C — extract a regional PMTiles for offline dev (RECOMMENDED for Phase 2 integration):
```bash
# Using Planetiler (Java) — generate Berlin-area PMTiles
java -jar planetiler.jar --download --area=berlin --output=assets/tiles/dev_berlin.pmtiles

# Or use osmium + tippecanoe pipeline:
osmium extract -b 13.088,52.338,13.761,52.677 germany-latest.osm.pbf -o berlin.osm.pbf
planetiler --input=berlin.osm.pbf --output=assets/tiles/dev_berlin.pmtiles
```
Berlin extract at zoom 0–14 is approximately 5–15 MB — comfortably bundleable in the app for development.

### BottomNavScaffold with liquid_navbar

```dart
// Source: liquid_navbar ^2.0.7 pub.dev README
BottomNavScaffold(
  pages: [mapPage, tripsPage, regionsPage],
  icons: [
    const Icon(Icons.map_outlined),
    const Icon(Icons.route),
    const Icon(Icons.flag_outlined),
  ],
  labels: ['Map', 'Trips', 'Regions'],
  navbarHeight: 70,
  bottomPadding: 8,
)
```

Note: `liquid_navbar` manages its own `Riverpod` state for the selected tab index. Ensure it is wrapped in a `ProviderScope` (already present in our `main.dart`). Layout changes require a full app restart (not hot reload).

### StatefulShellRoute replacement for '/'

Phase 2 replaces `PlaceholderHomeScreen` with a `StatefulShellRoute` in go_router:

```dart
// In app_router.dart:
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            MapScreen(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', ...)]),
          StatefulShellBranch(routes: [GoRoute(path: '/trips', ...)]),
          StatefulShellBranch(routes: [GoRoute(path: '/regions', ...)]),
        ],
      ),
    ],
  );
});
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| MapBox Flutter | MapLibre GL Flutter ^0.26.2 | Vendor-neutral, no API key, PMTiles first-class |
| MBTiles SQLite tiles | PMTiles single-file archive | Single file, HTTP range-request native, simpler bundling |
| `flutter_map` + `vector_map_tiles` | `maplibre_gl` (native) | Feature-state (web only for now), data-driven styling, GPU-native rendering |
| Manual GPS stream → custom marker | `myLocationEnabled: true` + `MyLocationRenderMode.compass` | Built-in blue dot + heading cone + accuracy ring, zero Dart code |
| `setState` style reload | `controller.setStyle()` | Preserves map state; does not recreate native view |
| `BackdropFilter` over platform view | FallbackGlassPill (semi-transparent tint) | Works on Android; actual blur only on iOS (G1 decision) |

### Gate G2 Confirmed: setFeatureState web-only

As of `maplibre_gl` 0.26.2 (2026-07-03 verification from source code):

- `setFeatureState()` → throws `UnimplementedError` on iOS/Android
- `getFeatureState()` → throws `UnimplementedError` on iOS/Android
- `removeFeatureState()` → throws `UnimplementedError` on iOS/Android

This is confirmed by `method_channel_maplibre_gl.dart` which has `// TODO: Implement feature state support for iOS and Android`.

**Phase 7 must use the sharded GeoJSON approach** for coverage rendering. See SUMMARY.md for the fallback design (partition country into ~5km × 5km GeoJSON sources; only re-upload changed tiles). This is a P7 concern — Phase 2 does not render coverage.

An open issue/PR for this feature: none found in open issues. A closed PR for it may exist; no active PRs on this as of 2026-07-03.

---

## Open Questions

1. **G1 Spike: Does `LiquidGlass` work on iOS over MapLibre?**
   - What we know: Flutter issue #43902 (iOS BackdropFilter + UIKitView) is CLOSED (2023)
   - What's unclear: Whether iOS with Impeller now correctly composites the glass shader over the platform view's texture
   - Recommendation: Must be validated on a real iOS device in Plan 01 spike. Cannot be assumed from issue closure alone.

2. **Bundled PMTiles path syntax on iOS**
   - What we know: Android uses `asset://` scheme and resolves `assets/tiles/dev.pmtiles` correctly
   - What's unclear: Exact iOS path for a bundled `.pmtiles` in the Flutter bundle
   - Recommendation: In Plan 02 integration spike, test `pmtiles://assets/tiles/dev.pmtiles` on both platforms. If iOS fails, try `pmtiles://` + `pathProvider.getApplicationSupportDirectory()` pattern.

3. **Glyphs bundling strategy for production offline**
   - What we know: Phase 2 can use external CDN for glyphs (not full offline)
   - What's unclear: How large is the full Protomaps glyph set for bundling?
   - Recommendation: Defer to Phase later (map works online in P2; full offline is post-P2).

4. **`location` package conflict with `permission_handler`**
   - What we know: `maplibre_gl` does NOT depend on `location`
   - What's unclear: Whether adding only `permission_handler` is sufficient, or if MapLibre's native location engine has a separate permission check
   - Recommendation: Use `permission_handler` only. MapLibre's native engine will read the system permission status directly without needing any Flutter permission package as an intermediary.

5. **Protomaps daily build URL stability**
   - What we know: Dated builds (build.protomaps.com/YYYYMMDD.pmtiles) expire after a few days
   - Recommendation for development: Use `demo-bucket.protomaps.com/v4.pmtiles` for network-tile development; use a locally generated `dev_berlin.pmtiles` for bundled offline testing.

---

## Sources

### Primary (HIGH confidence)

- `maplibre_gl` ^0.26.2 source via GitHub API (maplibre/flutter-maplibre-gl)
  - `maplibre_gl_platform_interface/lib/src/method_channel_maplibre_gl.dart` — confirmed `setFeatureState` = `UnimplementedError` on iOS/Android
  - `maplibre_gl/lib/src/maplibre_map.dart` — `tiltGesturesEnabled`, `myLocationEnabled`, `compassEnabled`, all constructor params
  - `maplibre_gl/lib/src/controller.dart` — `setStyle()`, `setFeatureState()`, `updateMyLocationTrackingMode()`
  - `maplibre_gl_platform_interface/lib/src/ui.dart` — `MyLocationTrackingMode`, `MyLocationRenderMode`, `CompassViewPosition` enums
  - `maplibre_gl/android/src/main/java/.../MapLibreMapController.java` — confirms `asset://` scheme for bundled styles
  - `website/docs/advanced/pmtiles.md` — bundled PMTiles path syntax, hosting options
  - `maplibre_gl_example/lib/main.dart` — "Hybrid composition is currently broken do not use" comment
  - `maplibre_gl_example/lib/examples/basics/gps_location_page.dart` — complete location tracking example

- `liquid_glass_renderer` 0.2.0-dev.4 pub.dev documentation
  - `FakeGlass` widget description; `LiquidGlassSettings` API; Impeller-only limitation

- `liquid_navbar` 2.0.7 pub.dev documentation
  - `BottomNavScaffold` API; `flutter_riverpod: ^3.0.3` dependency

- `permission_handler` ^12.0.3 pub.dev
  - `Permission.locationWhenInUse` API

- Flutter issue #185497 (GitHub flutter/flutter)
  - "[Android] BackdropFilter has no effect on PlatformView widgets" — OPEN, updated 2026-05-08
  - Confirms Android BackdropFilter over platform views is still broken in 2026

- Protomaps basemaps GitHub (protomaps/basemaps)
  - `README.md` — licensing (BSD-3 code, CC0 design, ODbL tiles, OSM attribution required)
  - `styles/src/flavors.ts` — Flavor interface (light/dark color property names)
  - Schema: source-layer names `earth`, `water`, `roads`, `buildings`, `places`, `pois`, `landcover`, `landuse`, `boundaries`

- `maplibre_gl` changelog (pub.dev)
  - v0.26.0: PMTiles background crash fix; feature-state (web only); high-accuracy iOS location engine
  - v0.23.0: raw style JSON on iOS/web
  - v0.22.0: PMTiles support introduced

### Secondary (MEDIUM confidence)

- Flutter issue #43902 (GitHub flutter/flutter)
  - "[iOS] UIKitView should support mutations: backdrop_filter" — CLOSED 2023-07-05
  - Suggests iOS BackdropFilter over UIKitView was fixed; confidence MEDIUM (may be Impeller-version-dependent)

- `geolocator` ^14.0.3 pub.dev — alternative location package; confirmed not needed for Phase 2 (MapLibre handles it natively)

- Protomaps docs (docs.protomaps.com) — themes (light/dark/white/black/grayscale), `pmtiles://` prefix requirement

### Tertiary (LOW confidence)

- XFin `LiquidGlassSettings` pattern — inferred from requirements; not directly observable. Pattern described in this document is a reasonable reconstruction.
- Protomaps tile sizes — Germany estimate (~2.5-4 GB full; Berlin ~5-15 MB at z0-14) from prior STACK.md research

---

## PLANNING HINTS

Suggested plan slicing (5–8 plans per roadmap estimate of 5–8 plans for Phase 2):

### Plan 02-01: G1 Rendering Spike
**Goal:** Determine whether `LiquidGlass`/`BackdropFilter` renders correctly over `MapLibreMap` on real iOS + Android. Make the gate decision and document the fallback.

**Tasks:**
1. Add `maplibre_gl`, `liquid_glass_renderer` to pubspec; `flutter pub get`
2. Create a minimal spike screen: `MapLibreMap` (remote demo style) + `LiquidGlass` pill overlaid
3. Run on real Android device (profile mode) → observe blur behavior → PASS or FAIL
4. Run on real iOS device (if available) → same test
5. Document result in `docs/G1_SPIKE.md`; set `LiquidGlassSettings.platformSupportsBlurOverMap`

**Acceptance:** G1 gate decision committed to repo. Fallback path identified and documented.

**Estimated time:** ~30–45 min dev + real-device testing

---

### Plan 02-02: MapLibre + PMTiles Integration
**Goal:** Map renders from a bundled PMTiles asset on both Android and iOS.

**Tasks:**
1. Download or generate `dev_berlin.pmtiles` (~5-15 MB, Berlin bbox)
2. Add `assets/tiles/dev_berlin.pmtiles` to pubspec assets
3. Create `assets/map_style_light.json` (Protomaps-based, minimal Google Maps-light feel) referencing `pmtiles://assets/tiles/dev_berlin.pmtiles`
4. Create `assets/map_style_dark.json` (deep navy, Protomaps-dark theme)
5. Create `MapWidget` wrapping `MapLibreMap` with correct params (tilt disabled, tracking modes, compass)
6. Verify map renders tiles offline (airplane mode)

**Acceptance:** Map renders tiles in both light/dark from bundled PMTiles, airplane mode = map still works.

---

### Plan 02-03: Location + Camera
**Goal:** Blue dot displays at current location; camera opens at current location; re-center button works; follow mode wired up (architecture supports Phase 3 heading-lock).

**Tasks:**
1. Add `permission_handler` to pubspec
2. Add location permission request to `OnboardingScreen` (before Continue)
3. Add permission check to `MapWidget.initState` → set `myLocationEnabled` based on result
4. Implement `CameraState` + `CameraStateNotifier` (Riverpod Notifier, no codegen)
5. Implement `MapControllerNotifier` for controller lifecycle
6. Wire `myLocationTrackingMode` → `tracking` on app start
7. Wire `onCameraTrackingDismissed` → exit follow mode in `CameraStateNotifier`
8. Add re-center button (tapping dot or dedicated button calls `updateMyLocationTrackingMode(tracking)`)
9. Handle location denied state (map shows without dot; no crash)

**Acceptance:** Blue dot visible at current location; panning away exits follow mode; re-center button returns follow.

---

### Plan 02-04: Dark Mode Style Switching
**Goal:** Map style switches automatically when system theme changes; transition is a soft fade, not abrupt.

**Tasks:**
1. Add `WidgetsBindingObserver` to `MapWidget` for `didChangePlatformBrightness`
2. Implement `AnimatedOpacity` wrapper for fade transition (opacity 0 on theme change → `controller.setStyle()` → opacity 1 in `onStyleLoadedCallback`)
3. Ensure `onStyleLoadedCallback` re-applies any programmatic layers added after style load (none in Phase 2, but architecture must support it)
4. Widget test: mock brightness change, assert `setStyle` called with correct asset path

**Acceptance:** Theme switch produces smooth crossfade with no full map rebuild.

---

### Plan 02-05: Glass Shell — Fallback Path (FrostedGlassCard)
**Goal:** Bottom nav pill, FAB stub, focus-area pill stub, settings button — all rendered in glass style using the G1-determined approach.

**Tasks:**
1. Implement `LiquidGlassSettings` singleton (`lib/core/theme/liquid_glass_settings.dart`)
2. Implement `FallbackGlassPill` widget (semi-transparent tinted `ClipRRect` with border — works on all platforms)
3. If G1 spike showed iOS supports blur: implement `LiquidGlass`-backed pill for iOS conditional
4. Implement `FocusAreaPill` (top-center stub, shows `—`, uses glass style)
5. Implement `SettingsButton` (top-left, gear icon, glass style, no-op tap for now)
6. Implement `TripFab` (bottom-right, circular, glass style, tap shows Snackbar "Coming in Phase 3")
7. Wire `liquid_navbar` `BottomNavScaffold` with Map/Trips/Regions tabs (Trips/Regions are stub `PlaceholderScreen`)

**Acceptance:** All chrome elements render on real device; no jank at 60fps in profile mode; passes visual smoke test on light + dark mode.

---

### Plan 02-06: Router + StatefulShellRoute
**Goal:** Replace `/` route (`PlaceholderHomeScreen`) with `StatefulShellRoute`; Map tab is live; Trips/Regions are stubs.

**Tasks:**
1. Refactor `app_router.dart` — add `StatefulShellRoute.indexedStack` with 3 branches
2. Create stub `TripsScreen` and `RegionsScreen` (`Scaffold` with centered placeholder text)
3. Wire `liquid_navbar`'s tab selection to `StatefulShellRoute.goBranch(index)`
4. Ensure splash/onboarding routes are unaffected
5. Update tests that reference `PlaceholderHomeScreen`

**Acceptance:** All 3 tabs navigable; back navigation works; splash/onboarding unaffected.

---

### Plan 02-07: G1 Gate Documentation + Phase Verification
**Goal:** Document G1 decision, run verification checklist, ensure all 5 Phase 2 success criteria pass.

**Tasks:**
1. Write `docs/G1_SPIKE.md` with: test methodology, device/OS versions, result, decision, fallback active
2. Verify success criteria SC1-SC5:
   - SC1: Pan/zoom/rotate smooth (no tilt)
   - SC2: Offline from bundled PMTiles (airplane mode)
   - SC3: Blue dot + camera at current location
   - SC4: Dark mode style switch automatic
   - SC5: Glass shell renders without release-mode jank (60fps sustained)
3. Record frame stats in DevTools timeline (screenshot in `docs/`)
4. Write golden tests for glass chrome widgets (light + dark)
5. Update `STATE.md` / `ROADMAP.md`

**Acceptance:** All 5 success criteria documented as PASS or the fallback (per G1) is confirmed active.

---

**Total: 7 plans** (within the 5–8 estimate; the extra plan is justified by the G1 spike being a mandatory gate before architecture commitment)

**Critical path:** 02-01 (G1 spike) MUST finish before 02-05 (glass shell). Plans 02-02 through 02-04 can run after 02-01 completes; they don't depend on G1 outcome. Plans 02-05 and 02-06 can run in parallel. 02-07 is final.

**Dependency graph:**
```
02-01 (G1 spike)
  └─► 02-05 (glass shell)
        └─► 02-06 (router)
              └─► 02-07 (verification)

02-02 (PMTiles) ─────────────► 02-07
02-03 (location) ────────────► 02-07
02-04 (dark mode) ───────────► 02-07
```
