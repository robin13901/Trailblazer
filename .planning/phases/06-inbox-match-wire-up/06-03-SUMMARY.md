---
phase: 06-inbox-match-wire-up
plan: 03
subsystem: ui
tags: [thumbnail, maplibre-snapshot, custom-painter, riverpod-notifier, disk-cache]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: MapTiler-hosted style URL (mapStyleUrlProvider) + maplibre_gl 0.26.2 controller surface
  - phase: 03-tracking-mvp
    provides: trip bbox + polyline (TripSummary + TripPoints)
provides:
  - ThumbnailCache Notifier with tripId -> PNG path index, disk-backed at <AppDocs>/thumbs/<tripId>.png
  - ThumbnailRenderer with MapLibre takeSnapshot primary path + CustomPainter fallback
  - TripThumbnail ConsumerWidget for TripCard (06-05)
  - Delete API on the cache — invoked by 06-05 when discardTrip fires
affects: [06-05, 06-06]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Factory-seam provider (thumbnailDirectoryFactoryProvider) — tests inject Directory.systemTemp.createTempSync(...) without a path_provider platform-channel setup"
    - "MapLibre snapshot with CustomPainter fallback pattern — try/catch on Object around c.takeSnapshot, fall through to a pure-Flutter PictureRecorder path for platforms where the snapshot API misbehaves (Q1 pitfall #2)"
    - "Atomic PNG write via .tmp + rename in the cache Notifier — resilient to a process crash mid-write"

key-files:
  created:
    - lib/features/trips/data/thumbnail_cache.dart
    - lib/features/trips/data/thumbnail_providers.dart
    - lib/features/trips/data/thumbnail_renderer.dart
    - lib/features/trips/presentation/widgets/trip_thumbnail.dart
    - test/features/trips/thumbnail_cache_test.dart
    - test/features/trips/thumbnail_renderer_fallback_test.dart
  modified: []

key-decisions:
  - "Fallback-only render path from Task 3's widget — the MapLibre snapshot path is code-complete but not integration-tested; wired by 06-05's TripsScreen overlay"
  - "Factory-seam over path_provider platform-channel mocking — cleaner test setup and matches the OnboardingFlagRepository pattern (STATE Plan 01-03)"
  - "ThumbnailRenderer holds mapStyleUrl fixed at construction — never brightness-reactive (Q1 pitfall #1: MapLibre setStyle wipes programmatic layers)"

patterns-established:
  - "Placeholder widget owns the async render — _RenderingPlaceholder is a ConsumerStatefulWidget with initState kick-off + mounted guard; parent TripThumbnail is a stateless ConsumerWidget that swaps in Image.file on cache hit"
  - "Lazy _initDir scan on Notifier build — state starts empty, populates asynchronously as files on disk are discovered; ensureLoaded() awaitable for tests that need to observe pre-existing files"

# Metrics
duration: ~10min
completed: 2026-07-09
---

# Phase 6 Plan 03: Trip Thumbnail Renderer Summary

**Disk-backed thumbnail cache + MapLibre-snapshot renderer (with CustomPainter fallback) + TripThumbnail ConsumerWidget for TripCard.**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-09T11:20:29Z
- **Completed:** 2026-07-09T11:30:42Z
- **Tasks:** 3
- **Files created:** 6
- **Files modified:** 0

## Accomplishments

- Cache Notifier with 5 test cases (store, delete, delete-missing, clear, reload-from-disk) — file writes are atomic (.tmp + rename), delete is idempotent, and a fresh process rebuilds its index from `<thumbs-dir>/*.png` on the lazy `_initDir` scan.
- Renderer with two paths: `render()` calls `MapLibreMapController.takeSnapshot({width, height})` when a controller is injected (06-05 wires the offstage-overlay one); on any error falls back to a pure-Flutter `renderFallback()` that paints the polyline over a neutral-gray 320x120 background via `PictureRecorder`.
- 5 fallback tests: PNG magic bytes, empty polyline (background-only decode), all-points-outside-bbox (clipping), byte-determinism (same input → identical output — future-proofs golden tests), decoded raster size = 320x120.
- TripThumbnail widget consumes `thumbnailCacheProvider.select((s) => s.paths[tripId])` — on cache hit renders `Image.file` synchronously; on miss delegates to `_RenderingPlaceholder` which kicks off `renderer.renderFallback` in a post-frame callback and calls `cache.store(tripId, bytes)`; the parent then rebuilds.
- No `withOpacity` anywhere in this plan — placeholder tint uses `Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)`.

## Task Commits

1. **Task 1: ThumbnailCache Notifier + provider + tests** — `36f8f39` (feat)
2. **Task 2: ThumbnailRenderer + fallback tests** — `ae2cc5c` (feat)
3. **Task 3: TripThumbnail widget** — `2c6bef0` (feat)

**Plan metadata commit follows this summary.**

## Files Created/Modified

- `lib/features/trips/data/thumbnail_cache.dart` — Notifier owning the disk-backed `<AppDocs>/thumbs/<tripId>.png` store with `store`, `pathFor`, `delete`, `clear`, `ensureLoaded` API.
- `lib/features/trips/data/thumbnail_providers.dart` — `thumbnailDirectoryFactoryProvider` (test seam) + `thumbnailCacheProvider` (Notifier singleton).
- `lib/features/trips/data/thumbnail_renderer.dart` — `ThumbnailRenderer` with `render` (snapshot-primary) + `renderFallback` (CustomPainter) + `thumbnailRendererProvider`.
- `lib/features/trips/presentation/widgets/trip_thumbnail.dart` — `TripThumbnail` ConsumerWidget + private `_RenderingPlaceholder` ConsumerStatefulWidget.
- `test/features/trips/thumbnail_cache_test.dart` — 5 test cases via factory seam + temp dir.
- `test/features/trips/thumbnail_renderer_fallback_test.dart` — 5 fallback-path test cases including image decode + byte-determinism.

## Decisions Made

- **Factory-seam over `path_provider` platform-channel mocking.** Tests override `thumbnailDirectoryFactoryProvider` with a `Directory.systemTemp.createTempSync(...)` closure. Matches the `OnboardingFlagRepository` pattern (STATE Plan 01-03) and avoids `setMockMethodCallHandler` boilerplate.
- **`ThumbnailRenderer.render` uses `takeSnapshot({width, height})` — no `SnapshotOptions`.** The plan text sketched a richer `SnapshotOptions` payload, but `maplibre_gl 0.26.2`'s Dart controller only exposes `Future<Uint8List> takeSnapshot({int? width, int? height})` (verified in pub cache at `controller.dart:2009`). Bbox framing + polyline overlay live on the `MapLibreMap` widget that 06-05 wires into a hidden overlay — this renderer just asks the platform for a raster.
- **Mounted-guarded async render in `_RenderingPlaceholder`.** `WidgetsBinding.instance.addPostFrameCallback` kicks off after the first paint so the placeholder is visible immediately; `if (!mounted) return` before touching `cache.store` prevents a use-after-dispose on rapid scrolling.
- **`Uint8List.fromList(bytes)` wrap before `cache.store`.** `ByteData.buffer.asUint8List()` returns a view over the underlying `ByteBuffer` — copying via `Uint8List.fromList` isolates the cached bytes from the recorder's short-lived buffer.
- **No `_bboxCenter` helper, no `SnapshotOptions` import.** Removed after finding the 0.26.2 API surface — kept the renderer file lean.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `SnapshotOptions` doesn't exist in `maplibre_gl 0.26.2`.**
- **Found during:** Task 2 (ThumbnailRenderer implementation).
- **Issue:** Plan sketched `takeSnapshot(SnapshotOptions(width, height, centerCoordinate, styleUri, withLogo))`. Grepping pub cache showed the actual API is `Future<Uint8List> takeSnapshot({int? width, int? height})` — bbox framing + style + polyline overlay live on the `MapLibreMap` widget the controller is attached to, not on the snapshot call.
- **Fix:** Simplified to `c.takeSnapshot(width: ..., height: ...)`. Added a comment explaining that the offstage `MapLibreMap` (06-05) owns camera + style + polyline layer; the renderer just asks for a raster.
- **Files modified:** `lib/features/trips/data/thumbnail_renderer.dart`.
- **Verification:** `flutter analyze --no-pub` clean.
- **Committed in:** `ae2cc5c` (Task 2 commit).

**2. [Rule 1 - Bug] `_bboxCenter` helper became dead code after Fix #1.**
- **Found during:** Task 2 (analyze pass).
- **Issue:** `SnapshotOptions` removal left `_bboxCenter` as unused private method — `very_good_analysis` fires `unused_element`.
- **Fix:** Deleted the helper.
- **Files modified:** `lib/features/trips/data/thumbnail_renderer.dart`.
- **Verification:** `flutter analyze --no-pub` clean.
- **Committed in:** `ae2cc5c` (Task 2 commit).

**3. [Rule 1 - Bug] Unused `flutter/services.dart` import in fallback test.**
- **Found during:** Task 2 (analyze pass).
- **Issue:** Left over from an earlier draft that reached for `MethodChannel` mocking (which the pure-Flutter fallback path doesn't need).
- **Fix:** Removed the import.
- **Files modified:** `test/features/trips/thumbnail_renderer_fallback_test.dart`.
- **Verification:** `flutter analyze --no-pub` clean.
- **Committed in:** `ae2cc5c` (Task 2 commit).

**4. [Rule 1 - Bug] `prefer_int_literals` on `LatLng(48.0, 8.0)` fixture.**
- **Found during:** Task 2 (analyze pass).
- **Issue:** `very_good_analysis` prefers int literals for `double` params where the value is whole.
- **Fix:** Changed to `LatLng(48, 8)`.
- **Files modified:** `test/features/trips/thumbnail_renderer_fallback_test.dart`.
- **Verification:** `flutter analyze --no-pub` clean.
- **Committed in:** `ae2cc5c` (Task 2 commit).

**5. [Rule 1 - Bug] Unused `thumbnail_cache.dart` import in TripThumbnail widget.**
- **Found during:** Task 3 (analyze pass).
- **Issue:** `TripThumbnail` reaches into the cache via `thumbnailCacheProvider` (owned by `thumbnail_providers.dart`) — the state class `ThumbnailCacheState` is re-exported transitively.
- **Fix:** Removed the direct import.
- **Files modified:** `lib/features/trips/presentation/widgets/trip_thumbnail.dart`.
- **Verification:** `flutter analyze --no-pub` clean.
- **Committed in:** `2c6bef0` (Task 3 commit).

---

**Total deviations:** 5 auto-fixed (1 blocking API-shape correction, 4 style/lint fixes surfaced during Ralph tight-loop iteration).
**Impact on plan:** Zero scope creep. The blocking `SnapshotOptions` correction is the load-bearing one — the renderer now uses the actual 0.26.2 API. 06-05's overlay wiring will need to attach a `MapLibreMap` widget with the polyline layer already applied before invoking `renderer.render()` so `takeSnapshot` captures the correct frame.

## Issues Encountered

- None — the plan's Q1 pitfall #2 (unproven snapshot API) is exactly why the fallback path exists, so the snapshot-API-shape mismatch (Deviation #1) was caught cleanly by the fallback being the tested path.

## User Setup Required

None.

## Next Phase Readiness

- **06-05 (Inbox + History UI)** consumes:
  - `TripThumbnail(tripId, polyline, bbox)` widget.
  - `thumbnailCacheProvider.notifier.delete(tripId)` called from the Discard-modal-confirm handler.
  - `thumbnailRendererProvider` — 06-05's `TripsScreen` should build a hidden `Offstage(MapLibreMap(...))` inside a global `Overlay` entry and pass the resulting controller into a new `ThumbnailRenderer(controller: ..., mapStyleUrl: ref.watch(mapStyleUrlProvider))` — override `thumbnailRendererProvider` with that instance so `render()` uses the snapshot path.
  - `thumbnailCacheProvider.notifier.clear()` — 06-01's OSM-extract-updated stub can call this for cache-invalidation symmetry.
- **Known gap:** MapLibre snapshot path exists in code but has no integration test. Verified visually at the phase close-out drive when 06-05 lands the overlay.
- **No `withOpacity` anywhere** — invariant preserved.

---
*Phase: 06-inbox-match-wire-up*
*Completed: 2026-07-09*
