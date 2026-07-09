---
plan: 06-03
phase: 6
wave: 1
depends_on: []
type: execute
autonomous: true
files_owned:
  - lib/features/trips/data/thumbnail_cache.dart
  - lib/features/trips/data/thumbnail_renderer.dart
  - lib/features/trips/data/thumbnail_providers.dart
  - lib/features/trips/presentation/widgets/trip_thumbnail.dart
  - test/features/trips/thumbnail_cache_test.dart
  - test/features/trips/thumbnail_renderer_fallback_test.dart
files_modified:
  - lib/features/trips/data/thumbnail_cache.dart
  - lib/features/trips/data/thumbnail_renderer.dart
  - lib/features/trips/data/thumbnail_providers.dart
  - lib/features/trips/presentation/widgets/trip_thumbnail.dart
  - test/features/trips/thumbnail_cache_test.dart
  - test/features/trips/thumbnail_renderer_fallback_test.dart
must_haves:
  truths:
    - "TripCard shows a 320x120 static map thumbnail with the trip polyline once rendered (INB-02)"
    - "Thumbnails are cached on disk under <AppDocs>/thumbs/<tripId>.png and served instantly on repeat views (Q1 approach C)"
    - "takeSnapshot failures fall back gracefully to a CustomPainter polyline-on-gray (Pitfall #2)"
    - "Deleting a trip removes its cached thumbnail file"
  artifacts:
    - path: "lib/features/trips/data/thumbnail_renderer.dart"
      provides: "ThumbnailRenderer.render(tripId, polyline, bbox) → Future<String pathToPng>"
    - path: "lib/features/trips/data/thumbnail_cache.dart"
      provides: "ThumbnailCache Notifier with in-memory + disk cache, delete method"
    - path: "lib/features/trips/presentation/widgets/trip_thumbnail.dart"
      provides: "TripThumbnail Consumer widget for TripCard"
  key_links:
    - from: "ThumbnailRenderer"
      to: "MapLibreMapController.takeSnapshot"
      via: "hidden Offstage MapLibreMap in an Overlay; try/catch → CustomPainter fallback"
      pattern: "takeSnapshot"
    - from: "ThumbnailCache.delete"
      to: "TripsInboxRepository.discardTrip"
      via: "wired in 06-05 UI plan — this plan just exposes the delete API"
      pattern: "delete\\(tripId"
verification:
  analyzer: "flutter analyze passes"
  tests:
    - test/features/trips/thumbnail_cache_test.dart
    - test/features/trips/thumbnail_renderer_fallback_test.dart
---

<objective>
Thumbnail renderer + disk cache for TripCard previews. Uses `MapLibreMapController.takeSnapshot` (v0.26.2 API) with a `CustomPainter` fallback for devices where the snapshot API misbehaves. Owns no UI beyond the `TripThumbnail` widget — the TripCard itself lives in 06-05.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/06-inbox-match-wire-up/06-CONTEXT.md
@.planning/phases/06-inbox-match-wire-up/06-RESEARCH.md
@CLAUDE.md

# Existing infrastructure to reuse
@lib/features/map/presentation/widgets/map_widget.dart
@lib/features/map/data/tile_provider_config.dart

# MapLibre API (from pub cache — HIGH confidence per RESEARCH Q1)
# C:\Users\I551358\AppData\Local\Pub\Cache\hosted\pub.dev\maplibre_gl-0.26.2\lib\src\controller.dart:2009
</context>

<invariants>
- Riverpod codegen OFF — plain `Provider<T>` / `Notifier`.
- Package imports only.
- `withValues(alpha:)` never `withOpacity()`.
- No new packages — use existing `maplibre_gl`, `path_provider`, `flutter` painting APIs.
- No drive checkpoint.
- **DO NOT touch files owned by 06-01, 06-02, 06-04** — thumbnail files live under `lib/features/trips/data/` and `lib/features/trips/presentation/widgets/` and are exclusively this plan's.
- Pitfall Q1: MapLibre `setStyle()` wipes programmatic layers — do NOT listen to brightness on the thumbnail map; force a fixed style URL at build time.
- Pitfall #2: `takeSnapshot` is v0.26.2-new and unproven on Trailblazer's target devices — MUST have `CustomPainter` fallback from day one.
</invariants>

<tasks>

<task id="1" type="auto">
  <title>Task 1: ThumbnailCache — Notifier with in-memory index + disk store + delete API</title>
  <files>
    lib/features/trips/data/thumbnail_cache.dart
    lib/features/trips/data/thumbnail_providers.dart
    test/features/trips/thumbnail_cache_test.dart
  </files>
  <action>
Notifier that tracks tripId → local file path, backed by `<AppDocs>/thumbs/<tripId>.png`.

```dart
class ThumbnailCacheState {
  const ThumbnailCacheState(this.paths);
  final Map<int, String> paths; // tripId → absolute file path
}

class ThumbnailCache extends Notifier<ThumbnailCacheState> {
  @override
  ThumbnailCacheState build() {
    _initDir(); // lazy — populates state from disk scan
    return const ThumbnailCacheState({});
  }

  /// Returns the on-disk path if cached, else null.
  String? pathFor(int tripId);

  /// Store an already-rendered PNG for tripId, returning the final path.
  Future<String> store(int tripId, Uint8List pngBytes);

  /// Hard-delete the cached thumbnail file for tripId. Idempotent.
  Future<void> delete(int tripId);

  /// Delete all cached thumbnails (called from OSM-extract-updated stub, symmetry).
  Future<void> clear();

  Future<Directory> _thumbsDir(); // <AppDocs>/thumbs/
  Future<void> _initDir();        // creates dir if missing, populates state from files present
}
```

Providers (`thumbnail_providers.dart`):
```dart
final thumbnailCacheProvider = NotifierProvider<ThumbnailCache, ThumbnailCacheState>(
  ThumbnailCache.new,
);
```

Tests (`test/features/trips/thumbnail_cache_test.dart`) — use `path_provider` platform-channel mocking (`setMockMethodCallHandler`) OR inject a temp dir via a factory seam. Prefer the factory seam for testability:
- store PNG for tripId 1 → pathFor(1) returns non-null; file exists on disk.
- delete tripId 1 → pathFor(1) returns null; file gone.
- delete missing id → no throw (idempotent).
- clear → all files gone, state empty.
- Reinstantiating cache with existing files → _initDir populates state (repeat-view instant).
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/thumbnail_cache_test.dart` green.
  </verify>
  <done>
ThumbnailCache Notifier + provider ship with 5 test cases.
  </done>
</task>

<task id="2" type="auto">
  <title>Task 2: ThumbnailRenderer — offscreen MapLibre + takeSnapshot with CustomPainter fallback</title>
  <files>
    lib/features/trips/data/thumbnail_renderer.dart
    test/features/trips/thumbnail_renderer_fallback_test.dart
  </files>
  <action>
The renderer must produce a 320×120 PNG for a given polyline + bbox. Approach C from RESEARCH Q1: hidden `Offstage(MapLibreMap(...))` inside a global `Overlay` entry that lives on `TripsScreen` (added by 06-05). This plan ships the renderer + fallback; the UI plan wires the overlay entry.

Public API:
```dart
class ThumbnailRenderer {
  ThumbnailRenderer({
    required String mapStyleUrl,           // fixed at construction — do NOT reactive-swap
    Size size = const Size(320, 120),
    EdgeInsets bboxPadding = const EdgeInsets.all(40),
  });

  /// Render a thumbnail for a polyline within a bbox. On takeSnapshot failure,
  /// falls back to a CustomPainter-rendered PNG (polyline on neutral-gray background).
  /// Returns raw PNG bytes.
  Future<Uint8List> render({
    required List<LatLng> polyline,
    required LatLngBounds bbox,
  });

  /// CustomPainter fallback — public for testability.
  Future<Uint8List> renderFallback({
    required List<LatLng> polyline,
    required LatLngBounds bbox,
  });
}
```

Implementation notes:
- Use `PictureRecorder` + `Canvas` + `Picture.toImage(w, h)` + `Image.toByteData(format: png)` for the fallback path. Map lat/lon → canvas pixels via a simple linear projection scoped to the bbox (Mercator-ish; the thumbnail is tiny — approximation acceptable).
- Force `styleString` from `TileProviderConfig` at construction; **do NOT** listen to `mapStyleUrlProvider` (would blank layers on brightness change — Pitfall Q1).
- Real-map path (used by 06-05's overlay wiring): the renderer accepts a `MapLibreMapController` reference. If none provided, uses fallback directly. This keeps THIS plan testable without an actual MapLibre integration test (which is platform-dependent).
- Suggested split: `RenderPipeline` interface with `MapLibreSnapshotPipeline` (production) and `FallbackOnlyPipeline` (tests). Pick whichever cleanest under `very_good_analysis`.

Tests (`test/features/trips/thumbnail_renderer_fallback_test.dart`) — pure Dart, no platform channels:
- renderFallback with 4-point polyline returns non-empty Uint8List whose first bytes are PNG magic (`0x89 0x50 0x4E 0x47`).
- renderFallback with empty polyline returns a valid PNG of the neutral background (does not crash).
- renderFallback with polyline entirely outside bbox → clamps or skips segments, still returns a valid PNG.
- Two calls with same input produce byte-identical output (determinism — helps golden tests).
- Output PNG decodes to 320×120 via `instantiateImageCodec`.

Do NOT write a full-integration test for the MapLibre snapshot path — 06-05 verifies it visually at the phase close-out drive. This plan proves the fallback works and the API compiles.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/thumbnail_renderer_fallback_test.dart` green.
  </verify>
  <done>
ThumbnailRenderer with public `render` + `renderFallback`; fallback produces valid PNGs; 5 test cases pass; MapLibre snapshot path exists but not integration-tested.
  </done>
</task>

<task id="3" type="auto">
  <title>Task 3: TripThumbnail widget (consumer)</title>
  <files>
    lib/features/trips/presentation/widgets/trip_thumbnail.dart
  </files>
  <action>
Widget consumed by TripCard (which lives in 06-05). Signature:

```dart
class TripThumbnail extends ConsumerWidget {
  const TripThumbnail({
    required this.tripId,
    required this.polyline,
    required this.bbox,
    this.width = 320,
    this.height = 120,
    super.key,
  });
  final int tripId;
  final List<LatLng> polyline;
  final LatLngBounds bbox;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cached = ref.watch(thumbnailCacheProvider.select((s) => s.paths[tripId]));
    if (cached != null) {
      return Image.file(File(cached), width: width, height: height, fit: BoxFit.cover);
    }
    return _RenderingPlaceholder(width: width, height: height, tripId: tripId, polyline: polyline, bbox: bbox);
  }
}
```

`_RenderingPlaceholder` shows a shimmer/gray box while rendering. In `initState`, kicks off render via `ref.read(thumbnailRendererProvider).renderFallback(...)` (fallback for now — real snapshot path plumbed by 06-05 overlay wiring) and calls `ref.read(thumbnailCacheProvider.notifier).store(tripId, bytes)` on completion.

Style: `ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5))`. Never `withOpacity`.

No new widget-golden tests in this plan — 06-05 handles TripCard golden tests. Analyzer-only verification here.
  </action>
  <verify>
`flutter analyze` clean (no widget test — 06-05 covers it).
  </verify>
  <done>
`TripThumbnail` widget exists, compiles clean, reads from `thumbnailCacheProvider`, renders fallback on cache miss.
  </done>
</task>

</tasks>

<verification>
Fast-loop (per commit): `flutter analyze`.
Loop-run tests: `flutter test test/features/trips/thumbnail_cache_test.dart test/features/trips/thumbnail_renderer_fallback_test.dart`.
Pre-push covers full suite.
</verification>

<success_criteria>
- ThumbnailCache + Renderer + Widget files compile clean.
- Fallback path produces valid PNGs — proven by tests.
- MapLibre snapshot path exists in the code (no integration test — verified visually at phase close-out drive).
- Cache delete API present + tested — 06-02 has already exposed `discardTrip` which 06-05 will wire to invoke this.
- No `withOpacity` anywhere in this plan.
- Fixed styleString at construction — no brightness reactivity on thumbnail map (Pitfall Q1).
</success_criteria>

<output>
Create `.planning/phases/06-inbox-match-wire-up/06-03-SUMMARY.md`.
Capture: renderer API, cache API, decision to defer full snapshot integration test to phase close-out drive, TripThumbnail widget contract.
</output>
