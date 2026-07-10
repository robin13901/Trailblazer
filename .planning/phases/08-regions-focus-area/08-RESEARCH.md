# Phase 8: Regions + Focus-Area - Research

**Researched:** 2026-07-10
**Domain:** Flutter/Dart — admin polygon lookup, coverage computation, MapLibre camera, Riverpod providers, Liquid Glass UI
**Confidence:** HIGH (all findings grounded in actual source files)

---

## Research-Flag Verdicts (Read First)

### Flag 1: Total Driving-Time-Per-Region — FEASIBLE BUT IMPRECISE / SKIP

**Verdict: SKIP — not worth the cost for Phase 8.**

**Evidence:**

The `trips` table (`lib/core/db/tables/trips_table.dart:9`) stores `durationSeconds INT nullable` per trip. The `driven_way_intervals` table (`lib/core/db/tables/driven_intervals_table.dart:7-9`) stores `tripId INT nullable` (FK ON DELETE SET NULL) but has NO column for the region the interval falls in.

To attribute drive time to a region you would need to:
1. For each confirmed/matched trip, call `regionAt(startLat, startLon, level)` to determine which region(s) it intersects.
2. Assign the trip's `durationSeconds` proportionally to each region based on interval overlap, OR assign the full trip duration to every region it touches.

**Problems:**
- `tripId` on `driven_way_intervals` goes `NULL` when a trip is deleted (FK SET NULL policy, `lib/core/db/tables/driven_intervals_table.dart:7-9`). Time attribution breaks for orphaned intervals.
- Proportional attribution (driven length in region / total driven length) requires iterating all intervals per trip, calling `regionAt` per interval, and attributing fractions of `durationSeconds`. This is an O(trips × intervals × regions) compute on the UI.
- A simple "sum duration of trips that passed through region" overcounts hugely (a 2-hour trip through Bavaria also counts fully toward every Ortsteil it crosses).
- The CONTEXT.md (`08-CONTEXT.md:45`) says "possibly total driving time in region — see research flag below. Ship the metric in the sheet if cheap; skip it if it requires expensive per-fix region attribution." This IS expensive.

**Conclusion:** Skip total driving time in Phase 8. The sheet shows driven km + total km. Leave a comment `// TODO(phase-9): per-trip time attribution` in the coverage compute service. The `durationSeconds` column is available for Phase 9 to wire up if wanted.

---

### Flag 2: Live-Pill Read Path — WARM IN-MEMORY CACHE IS ALREADY THERE; DB PATH IS INSUFFICIENT ALONE

**Verdict: The admin polygon point-in-polygon path IS fast enough for live pill; the DB `coverage_by_region` path is NOT populated yet and must be computed first.**

**Evidence for polygon lookup speed:**

`AdminRegionLookup` (`lib/features/admin/data/admin_region_lookup.dart`) keeps the full bundle in memory after first load, bucketed by `adminLevel` (`_byLevel: Map<int, List<AdminRegion>>`). A `regionAt(lat, lon, level)` call:
1. Checks `_byLevel![adminLevel]` — the Germany bundle has ~20K regions total across all levels. Level 10 (Ortsteil) has the most; Level 4 (Bundesland) has ~16 entries.
2. Runs a linear bbox-cull scan over one level's bucket (a few hundred to ~3K entries depending on level).
3. Runs `containsPoint` (ray-cast) only on bbox matches — typically 1-5 per call after the cull.

Per the comment at `lib/features/admin/data/admin_region_lookup.dart:4`: _"returns the containing region at the requested admin_level in <5 ms after the first load."_ This is CPU-bound synchronous work on the main isolate, but it's microseconds in practice (linear scan over a few thousand bbox checks). No isolate needed for a single-point lookup.

**The live pill path therefore needs:**
1. `AdminRegionLookup` already in memory (guaranteed after first use — the `ensureLoaded` single-flight guard at `admin_region_lookup.dart:79-81` ensures exactly one parse).
2. A `regionAt(center.lat, center.lon, zoomToLevel(zoom))` call — this is synchronous after load (the `await ensureLoaded()` is a fast no-op once loaded).
3. A `coverage_by_region` DB read for the resolved region's `drivenLengthM / totalLengthM`.

**The DB read (coverage_cache) problem:**

`coverage_cache` (`lib/core/db/tables/coverage_cache_table.dart`) has the right schema (`regionId TEXT PK`, `drivenLengthM REAL`, `totalLengthM REAL`). But:
- The `upsert` method on `CoverageCacheDao` (`lib/features/coverage/data/coverage_cache_dao.dart:30`) is NEVER CALLED by any production code path in Phase 6 or Phase 7. The DAO comment at line 27 says: _"Used by the Phase-8 recompute pass — ships now for symmetry so Phase 8 does not need to reopen this DAO."_
- Phase 6 only invalidates (deletes) rows from `coverage_cache`; it never writes them.
- Phase 7 does not touch `coverage_cache` at all.

**Conclusion:** Phase 8 must build the coverage compute service that actually populates `coverage_cache`. Until that runs, all `getByRegionId` calls return null. The warm in-memory admin polygon path is fast enough for live-during-movement lookups (sub-millisecond per call). The rate-limiting step is the DB read after region resolution — which is a simple PK point-read once the cache is populated.

**Live-pill anti-flicker strategy (confirmed feasible):** Use `cameraStateProvider` which already emits on every `onCameraIdle` (map_widget.dart:266-276). For truly live movement, wire to `onCameraMove` callback on `MapLibreMap` (confirmed present at `maplibre_gl-0.26.2/lib/src/controller.dart:116`, `typedef OnCameraMoveCallback = void Function(CameraPosition cameraPosition)`). Add a short debounce (100-200 ms trailing) on the camera-center stream → trigger `regionAt` → hold last value while resolving. This keeps the pill non-blank at all times.

---

## Summary

Phase 8 builds three deliverables on a solid foundation: the admin polygon lookup is production-ready and in-memory; the `coverage_cache` table schema is correct but needs its first writer (the recompute service); the focus pill stub exists at `lib/features/map/presentation/widgets/focus_area_pill.dart`; the regions screen stub exists at `lib/features/regions/presentation/regions_screen.dart`; and the MapLibre camera exposes both `onCameraMove` and `onCameraIdle` callbacks.

**Primary recommendation:** Build the Phase 8 coverage compute service first (runs on a compute isolate, iterates all driven intervals + all Overpass-cached ways, calls `regionAt` for each way, writes `coverage_cache`). Everything else in Phase 8 reads from that cache. The live pill can use a hybrid: show the last-known `%` while the camera moves (hold-last-value), refresh from cache on settle.

---

## Standard Stack

All libraries already in `pubspec.yaml`. No new dependencies are required for Phase 8 functionality. One potential addition for fuzzy search is discussed below.

### Core (already present)

| Library | Version | Purpose in Phase 8 |
|---------|---------|---------------------|
| `drift` | ^2.34.0 | `coverage_cache` reads/writes, custom SQL queries |
| `flutter_riverpod` | ^3.3.2 | `Provider<T>` / `Notifier` for pill, browser, detail state |
| `maplibre_gl` | ^0.26.2 | `onCameraMove`, `onCameraIdle`, `CameraUpdate.newLatLngBounds` |
| `liquid_glass_renderer` | 0.2.0-dev.4 | `GlassPill` reuse for detail sheet + pill |
| `logging` | ^1.3.0 | Consistent with all other features |

### For Fuzzy Search

No fuzzy-match library is currently in `pubspec.yaml`. Options:
- **Pure Dart (no dep):** Implement a simple score function: `contains(query)` → rank 100, initials match → rank 80, trigram overlap → rank 60. For < 10K entries this is instant and avoids adding a dependency.
- **`fuzzy` package** (if desired): Not currently in pubspec. Would need adding alphabetically between `flutter_riverpod` and `go_router`. Simple `Fuzzy(items).search(query)` API. **Recommendation: do NOT add a dep for this.** Dart string `.toLowerCase().contains(query.toLowerCase())` is sufficient for region names and eliminates a dep. Ranked display (exact-name first, contains-anywhere second) can be done in-Dart.

**Recommendation:** Use pure-Dart `String.toLowerCase().contains()` with a two-tier rank (starts-with > contains). Zero new dependencies. Satisfies the fuzzy-search requirement for names like "greb" → "Grebenhain".

### No New Dependencies Needed

**Installation:** Nothing to add. All Phase 8 code uses the existing stack.

---

## Architecture Patterns

### Recommended Project Structure for Phase 8

```
lib/features/regions/
├── data/
│   ├── coverage_compute_service.dart    # Compute isolate, writes coverage_cache
│   └── coverage_compute_providers.dart  # Provider<CoverageComputeService>
├── domain/
│   ├── region_coverage.dart             # Immutable value: AdminRegion + driven/total km
│   └── zoom_level_mapper.dart           # zoomToAdminLevel(double zoom) → int
├── presentation/
│   ├── providers/
│   │   ├── focus_pill_provider.dart     # Pill state: region + % + loading flag
│   │   └── region_browser_provider.dart # Sorted/filtered list of RegionCoverage
│   ├── widgets/
│   │   ├── region_detail_sheet.dart     # DraggableScrollableSheet Liquid Glass
│   │   └── region_card.dart             # One card in the browser list
│   └── regions_screen.dart              # Replace stub
```

`lib/features/map/presentation/widgets/focus_area_pill.dart` is replaced in-place (it's already a stub).

### Pattern 1: Coverage Compute on Isolate (COV-07)

**What:** A `compute()`-based service that iterates all driven intervals, fetches Overpass-cached way geometry per region bbox, computes `Σ drivenLengthM` and `Σ totalLengthM` per region, then upserts into `coverage_cache`.

**Algorithm:**
```
For each adminLevel in [4, 6, 8, 10]:
  For each WayCandidate in fetchWaysInBbox(germany_bbox, throwOnError: false):
    region = regionAt(way.centroid.lat, way.centroid.lon, level)
    totalLengthM[region.osmId.toString()] += haversine(way.geometry)
  For each DrivenWayInterval row (all intervals, globallyS):
    way = byId[interval.wayId]                // from the fetched ways map
    if way == null: skip
    region = regionAt(way.centroid.lat, way.centroid.lon, level)
    drivenLengthM[region.osmId.toString()] += drivenLengthMeters([interval])
  For each (regionId, totals) in accumulator:
    cacheDao.upsert(regionId, drivenLengthM, totalLengthM, now)
```

**Key constraint:** `regionAt` is synchronous after `ensureLoaded` but uses await. For the compute-isolate path, `AdminRegionLookup` must be run on the main isolate (asset bundle not accessible from spawned isolates — same lesson as `admin_region_lookup.dart:74`: _"The cheap asset read stays on the UI isolate because the asset bundle is not reachable from a spawned isolate."_). Therefore the compute service must run on the main isolate but use `compute` only for the pure arithmetic, OR run as a `Notifier` + `Future` on the main isolate with `await` at each step. See Pitfall 3 below.

**Trigger:** Compute runs when `coverage_cache` rows are missing for known driven regions (detected by checking `getByRegionId` after `confirmTrip` invalidation). Wire via `coverageInvalidatorProvider` + a post-confirm hook.

### Pattern 2: Focus Pill Provider (Live + Smooth)

**What:** A `Notifier<PillState>` that watches `cameraStateProvider` and resolves the current region + coverage %.

```dart
// Source: lib/features/map/presentation/providers/camera_state_provider.dart
// cameraStateProvider emits on every onCameraIdle.
// For live feel: add onCameraMove to MapWidget and emit to a separate
// cameraPositionStreamProvider (StreamProvider from controller stream).
```

**Anti-flicker via hold-last-value:** The `PillState` carries `name: String?` and `percent: double?`. The pill widget renders the last non-null values while a new resolution is in flight. Never shows a spinner or blank. The provider sets a `resolving: bool` flag to suppress number-jitter (don't update `%` mid-resolve).

**Provider wiring:**
```dart
// Watch cameraStateProvider (idle) OR a debounced onCameraMove stream
// → derive adminLevel from zoom via zoomToAdminLevel(zoom)
// → call adminRegionLookup.regionAt(lat, lon, level) [async, fast after load]
// → if null: try parent levels (level-1 fallback chain: 10→9→8→6→4→2)
// → read coverageCacheDao.getByRegionId(region.osmId.toString())
// → compute percent = drivenLengthM / totalLengthM * 100
// → emit PillState(name: region.name, percent: percent)
```

### Pattern 3: Region Browser List

**What:** A `StreamProvider` or `FutureProvider` that:
1. Reads all `coverage_cache` rows where `drivenLengthM > 0`.
2. Joins with `AdminRegionLookup` to get region names and levels.
3. Returns a flat `List<RegionCoverage>` sorted by `drivenLengthM / totalLengthM` descending.

**Lazy loading:** Use `ListView.builder` with `itemCount` (the existing pattern from `lib/features/trips/presentation/trips_screen.dart:110`). Do NOT eagerly build all cards. For Germany-scale (~10K regions with coverage > 0%), this is sufficient — Flutter's lazy `ListView.builder` only builds visible items.

**Search:** Filter the in-memory list with a `TextEditingController` + `ref.watch(searchQueryProvider)`. No need for server-side filtering.

### Pattern 4: Region Detail Sheet

**What:** A `DraggableScrollableSheet` wrapped in a Liquid Glass container, shown via `showModalBottomSheet`.

**Jump to map:** Use `CameraUpdate.newLatLngBounds(LatLngBounds(southwest, northeast), left: 40, top: 40, right: 40, bottom: 40)` — this is exactly what `trip_overlay_layers.dart:247-255` already does. The `AdminRegion` bbox fields (`bboxMinLat`, `bboxMinLon`, `bboxMaxLat`, `bboxMaxLon`) map directly to `LatLngBounds`.

### Anti-Patterns to Avoid

- **Spinner in the pill:** The pill must never be blank or show a spinner. Always hold last value.
- **Reloading admin bundle per pill update:** `AdminRegionLookup` is a singleton provider (`adminRegionLookupProvider`). One load, zero reloads.
- **Running `regionAt` inside a `compute()` isolate:** Asset bundle is not accessible off the main isolate. See `admin_region_lookup.dart:74`.
- **Writing coverage_cache rows from the UI thread synchronously:** The coverage compute pass iterates thousands of ways — run as an async operation (series of awaits), not a blocking sync loop.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Fuzzy region name search | Custom Levenshtein | Pure Dart `toLowerCase().contains()` + starts-with rank | Germany region names are short; no typo correction needed for navigation |
| Bbox camera fit | Custom zoom calc | `CameraUpdate.newLatLngBounds()` | Already used in `trip_overlay_layers.dart:248` |
| Admin polygon parsing | Custom GeoJSON parser | Existing `_parseAdminBundle` + `AdminRegionLookup` | 12 MB bundle already parsed, bucketed, bbox-indexed |
| Bottom sheet | Custom overlay widget | Flutter `DraggableScrollableSheet` | The exact widget for partial→full height pattern |
| Coverage % formatting | Custom precision | `(driven / total * 100).toStringAsFixed(1)` | One-liner, matches the "one decimal" spec |
| Interval union arithmetic | Custom merge | `drivenLengthMeters()` from `lib/features/coverage/domain/interval_union.dart:72` | Already correct sweep-line union, isolate-safe |

---

## Data Model: What Exists

### `coverage_cache` table (physical) / `coverage_by_region` (logical alias)

File: `lib/core/db/tables/coverage_cache_table.dart`

| Column | Type | Notes |
|--------|------|-------|
| `region_id` | TEXT PK | OSM relation ID as string (`osmId.toString()`) — business-key PK |
| `driven_length_m` | REAL | Default 0.0 — numerator for % |
| `total_length_m` | REAL | Default 0.0 — denominator for % |
| `updated_at` | DATETIME | Default `CURRENT_TIMESTAMP` |
| `extract_version` | TEXT nullable | For future OSM extract change detection |
| `invalidation_gen` | INT | Default 0; bumped without deleting row |

**Status:** Schema correct, table created. Rows are NEVER written by Phase 6 or Phase 7. Phase 8 must write them via `CoverageCacheDao.upsert()` (`lib/features/coverage/data/coverage_cache_dao.dart:30-45`). The DAO comment at line 27 explicitly says: _"Used by the Phase-8 recompute pass — ships now for symmetry so Phase 8 does not need to reopen this DAO."_

**No `region_name` column.** Names come from `AdminRegionLookup` (in-memory, not DB). The `region_id` is the OSM relation ID; the name is resolved on demand via `adminRegionLookupProvider`.

### `driven_way_intervals` table

File: `lib/core/db/tables/driven_intervals_table.dart`

| Column | Type | Notes |
|--------|------|-------|
| `id` | INT PK autoincrement | |
| `way_id` | INT | OSM way ID — join key for WayCandidate |
| `trip_id` | INT nullable | FK to trips ON DELETE SET NULL |
| `start_meters` | REAL | Start of driven interval on way |
| `end_meters` | REAL | End of driven interval on way |
| `direction` | TEXT | 'forward' | 'backward' | 'both' |
| `matched_at` | DATETIME | When matcher wrote this row |

**No geometry or admin region columns.** Per-region attribution requires joining with Overpass way geometry (from `overpass_way_cache`) and `AdminRegionLookup`.

### `trips` table

File: `lib/core/db/tables/trips_table.dart`

Key columns for Phase 8:
- `duration_seconds INT nullable` — trip total duration (for Flag 1 verdict: present but attribution to region is too expensive)
- `bbox_min_lat/lon/max_lat/lon REAL nullable` — used by `CoverageInvalidator._invalidateByTripBbox`
- `vehicle_id INT nullable` — Phase 9 hook: filter by vehicle for per-vehicle coverage
- `status TEXT` — only `matched` and `confirmed` trips feed coverage

### `AdminRegion` domain model

File: `lib/features/admin/data/admin_region.dart`

Fields: `osmId: int`, `adminLevel: int`, `name: String`, `nameDe: String?`, `bboxMinLat/Lon/MaxLat/Lon: double`, `polygons: List<List<List<List<double>>>>`.

Admin levels in the bundle: 2 (country/Deutschland), 4 (Bundesland), 6 (Regierungsbezirk, rare), 8 (Landkreis), 9 (Samtgemeinde, rare in Low Saxony), 10 (Gemeinde/Ortsteil).

Level 9 is present in the bundle but was skipped by `kCoverageAdminLevels = [4, 6, 8, 10]` (coverage_invalidator.dart:31). Phase 8 should handle level 9 consistently — include it in coverage compute and zoom-level mapping.

### `kCoverageAdminLevels` constant

File: `lib/features/coverage/data/coverage_invalidator.dart:31`

```dart
const List<int> kCoverageAdminLevels = [4, 6, 8, 10];
```

Level 2 (whole Germany) is excluded from invalidation (invalidating on every trip would defeat caching). Phase 8 should similarly exclude level 2 from the browser list, but INCLUDE it in the pill fallback (if nothing else matches, show "Deutschland"). Phase 8 should also include level 9 in both compute and browser.

---

## Camera State and Map Controller

### `CameraState` domain model

File: `lib/features/map/domain/camera_state.dart`

Fields: `latitude: double`, `longitude: double`, `zoom: double`, `bearing: double`, `followMode: FollowMode`.

`CameraState.initial.zoom = 16` (street level, Ortsteil/Gemeinde range).

### `cameraStateProvider`

File: `lib/features/map/presentation/providers/camera_state_provider.dart:37`

```dart
final cameraStateProvider = NotifierProvider<CameraStateNotifier, CameraState>(CameraStateNotifier.new);
```

Updated via `updateFromMap(CameraPosition position)` on `onCameraIdle` only (map_widget.dart:266-276). **For live-during-movement, Phase 8 must add `onCameraMove` to `MapWidget`'s `MapLibreMap` constructor** — `onCameraMove` delivers `CameraPosition` on every frame while the user pans.

### `mapControllerProvider`

File: `lib/features/map/presentation/providers/map_controller_provider.dart:24`

`NotifierProvider<MapControllerNotifier, MapLibreMapController?>` — null before map creation (or after tab-switch dispose).

### Camera Fit to Bbox

Pattern already in production at `lib/features/trips/presentation/widgets/trip_overlay_layers.dart:247-255`:
```dart
await controller.moveCamera(
  CameraUpdate.newLatLngBounds(bounds, left: 40, top: 40, right: 40, bottom: 40),
);
```

`AnimateCamera` vs `moveCamera`: use `animateCamera` with a duration for the "Jump to on map" button (smooth, like RecenterButton's 500 ms).

---

## Glass UI Reuse

### `GlassPill` widget

File: `lib/features/map/presentation/widgets/glass_pill.dart`

The `GlassPill` widget is the pill shell. Phase 8 replaces `FocusAreaPill` (currently a stub returning `GlassPill(child: Text('—'))`) with a live `ConsumerWidget` that reads `focusPillProvider` and renders two centered lines.

Critical constraint from `glass_pill.dart:41-48`:
```dart
// Guard against 0-dim constraints. liquid_glass_renderer calls
// Picture.toImageSync(w, h) during paint; if either dim is 0 that throws.
return LayoutBuilder(builder: (context, constraints) {
  if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
    return const SizedBox.shrink();
  }
  ...
```
The 0-dim guard must be preserved in the live pill widget. Do NOT use `Flexible/Expanded` on the pill in a `Row` — this caused 0-width crashes (see `map_screen.dart:247`).

### `GlassCircle` widget

File: `lib/features/map/presentation/widgets/glass_circle.dart`

Used for FAB and recenter. Not directly needed for Phase 8 but available as reference for any circular badges.

### `LiquidGlassSettings`

File: `lib/core/theme/liquid_glass_settings.dart`

```dart
static bool platformBlurEnabled = false; // set once at startup
bool get platformSupportsBlurOverMap => LiquidGlassSettings.platformBlurEnabled;
double get pillBorderRadius => 28;
Color get lightGlassTint => const Color(0x38FFFFFF);
Color get darkGlassTint => const Color(0x2A0A1728);
```

All glass widgets must branch on `platformSupportsBlurOverMap` and use `GlassPillFallback` when false.

### Bottom Sheet

No existing `DraggableScrollableSheet` in the app. Phase 8 introduces the first instance. Use Flutter's standard:
```dart
showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  builder: (_) => DraggableScrollableSheet(
    initialChildSize: 0.45,
    minChildSize: 0.3,
    maxChildSize: 0.9,
    expand: false,
    builder: (_, scrollController) => _RegionDetailContent(scrollController),
  ),
);
```

Wrap the sheet content in a `GlassPill`-equivalent container (use `GlassPillFallback` with a `borderRadius: 28` + the same tint colors).

---

## Zoom-to-Admin-Level Mapping

No zoom constants exist yet. **Recommended breakpoints** (based on standard OSM/MapLibre conventions and the admin levels in the bundle):

| Zoom range | Admin level | German name |
|-----------|------------|-------------|
| < 6 | 2 | Deutschland |
| 6–8 | 4 | Bundesland |
| 9–10 | 6 | Regierungsbezirk (rare; fallback to 4 if null) |
| 11–12 | 8 | Landkreis / kreisfreie Stadt |
| 13–14 | 9 | Samtgemeinde (rare; fallback to 8 if null) |
| ≥ 15 | 10 | Gemeinde / Ortsteil |

`CameraState.initial.zoom = 16` → level 10. This matches the "street-level tracking" use case: you're looking at a specific Ortsteil while driving.

The fallback chain (water/no-region): if `regionAt(lat, lon, level)` returns null, try the next coarser level: 10 → 9 → 8 → 6 → 4 → 2. Stop at the first non-null result.

Implement as:
```dart
// lib/features/regions/domain/zoom_level_mapper.dart
int zoomToAdminLevel(double zoom) {
  if (zoom < 6) return 2;
  if (zoom < 9) return 4;
  if (zoom < 11) return 6;
  if (zoom < 13) return 8;
  if (zoom < 15) return 9;
  return 10;
}

const List<int> kFallbackLevels = [10, 9, 8, 6, 4, 2];
```

---

## Riverpod Wiring Patterns

All providers use **plain `Provider<T>` / `Notifier`**, no `@Riverpod` codegen. Per `STATE.md Plan 01-01` and `CLAUDE.md`.

### Existing providers Phase 8 builds on

| Provider | File | What it provides |
|----------|------|-----------------|
| `adminRegionLookupProvider` | `lib/features/admin/data/admin_region_providers.dart:11` | Singleton `AdminRegionLookup` |
| `coverageCacheDaoProvider` | `lib/features/coverage/data/coverage_providers.dart:12` | Singleton `CoverageCacheDao` |
| `coverageInvalidatorProvider` | `lib/features/coverage/data/coverage_providers.dart:18` | `CoverageInvalidator` |
| `cameraStateProvider` | `lib/features/map/presentation/providers/camera_state_provider.dart:37` | Live camera position |
| `mapControllerProvider` | `lib/features/map/presentation/providers/map_controller_provider.dart:24` | `MapLibreMapController?` |
| `appDatabaseProvider` | (via `app_database_providers.dart`) | Singleton `AppDatabase` |
| `tripsDaoProvider` | (via `trips_repository_providers.dart`) | `TripsDao` |

### New providers for Phase 8

```
// Coverage compute
coverageComputeServiceProvider  → Provider<CoverageComputeService>
// Pill
focusPillStateProvider          → NotifierProvider<FocusPillNotifier, PillState>
// Browser
regionBrowserProvider           → StreamProvider<List<RegionCoverage>> or FutureProvider
regionSearchQueryProvider       → StateProvider<String> (text field value)
regionBrowserFilteredProvider   → Provider<List<RegionCoverage>> (derived, filters/sorts)
```

---

## Common Pitfalls

### Pitfall 1: Admin bundle parse on non-main isolate

**What goes wrong:** Calling `AdminRegionLookup.ensureLoaded()` from a `compute()` isolate throws because `rootBundle.load()` is not accessible off the main isolate.

**Evidence:** `lib/features/admin/data/admin_region_lookup.dart:73-74` explicitly documents this: _"The cheap asset read stays on the UI isolate because the asset bundle is not reachable from a spawned isolate."_

**How to avoid:** Call `await adminRegionLookup.ensureLoaded()` on the main isolate before dispatching any compute work. The `_parseAdminBundle(Uint8List bytes)` function at line 167 is already the isolate entry point — pass raw bytes in, not the lookup object.

### Pitfall 2: OOM from large admin-level region

**What goes wrong:** Level 2 (Deutschland) is ONE polygon covering all of Germany. If you iterate all ways in Germany and call `regionAt(lat, lon, 2)` for each, every call runs the full bbox scan + `containsPoint`. For Germany with 100K+ ways this is ~100K × single-polygon containment tests — not catastrophic, but avoidable.

**Evidence:** The OOM crash described in `admin_region_lookup.dart:15-21` was caused by a level-2 country polygon (Netherlands boundary) creating an enormous hash grid. The grid is gone now, replaced by linear scan. But: the coverage compute should still skip level 2 for the initial per-region breakdown (as `kCoverageAdminLevels` does — line 31 of `coverage_invalidator.dart`).

**How to avoid:** Exclude level 2 from coverage compute and browser. Include it only as the final pill fallback.

### Pitfall 3: `regionAt` is async — don't block the UI on thousands of calls

**What goes wrong:** A coverage recompute that calls `await regionAt(lat, lon, level)` in a tight loop for every way × every level would block the main isolate for seconds.

**How to avoid:** The coverage recompute must batch work using isolate-safe data. Specifically:
- Run `ensureLoaded()` once.
- The per-region attribution loop can run synchronously (after `ensureLoaded`, `regionAt` doesn't actually use `await` for the lookup itself — it only awaits `ensureLoaded` which is a no-op after first load). However, the DB writes (`cacheDao.upsert`) ARE async. Use `await Future.microtask(fn)` or `await Future.delayed(Duration.zero)` periodically to yield.

### Pitfall 4: `setStyle` wipes map sources — pill region highlight

**What goes wrong:** If Phase 8 adds any MapLibre layers (e.g., region boundary highlight on "Jump to map"), `setStyle()` on brightness-swap wipes all programmatic sources.

**How to avoid:** Wire any region-boundary source + layer through `mapStyleLoadedTickProvider` like `CoverageOverlayBridge` does. The bridge pattern at `lib/features/coverage/presentation/coverage_overlay_bridge.dart` is the template.

### Pitfall 5: `liquid_glass_renderer` 0-dim crash in DraggableScrollableSheet

**What goes wrong:** If a `GlassPill`/`LiquidGlass` widget is inside a `DraggableScrollableSheet` at initial size, it may transiently get 0 width/height during the sheet animation.

**Evidence:** `glass_pill.dart:41-48` has the 0-dim guard. **Must be replicated in the detail sheet's glass container.**

### Pitfall 6: MapWidget off-tab dispose

**What goes wrong:** When the user navigates from Map → Regions, `MapWidget` is disposed (freed GL surface). `mapControllerProvider` is set to null. The "Jump to on map" button must:
1. Navigate to the Map tab (`navigationShell.goBranch(0)` or `context.go('/')`).
2. Wait for `mapControllerProvider` to become non-null.
3. Then call `animateCamera`.

**How to avoid:** Use `ref.listen(mapControllerProvider, ...)` to watch for controller availability after tab switch, OR perform the navigation first and defer the camera move to the next non-null controller emission.

### Pitfall 7: `coverage_cache` regionId uniqueness across admin levels

**Evidence:** `coverage_invalidator.dart:118` has a comment: _"NOTE: OSM relation IDs are globally unique across admin levels (04-01 pitfall). Do NOT prefix with `$level:`."_ This is because OSM IDs are globally unique — a Bundesland and a Landkreis cannot share the same OSM ID. The `coverage_cache.region_id = osmId.toString()` scheme is correct and unambiguous.

---

## Integration Risks with Phase 6/7

### Risk 1: `coverageOverlayDataProvider` triggers on the same table writes

`coverageOverlayDataProvider` is a `StreamProvider` that re-resolves whenever `tripsUnionBoundsProvider` emits (via `watchUnionBbox`). `watchUnionBbox` has `readsFrom: {trips, drivenWayIntervals}`. If Phase 8's coverage compute triggers any writes to these tables (unlikely — it only writes to `coverage_cache`), it won't trigger overlay recompute. **Safe.**

### Risk 2: `CoverageInvalidator` deletes rows Phase 8 just wrote

When a user confirms a trip (`TripsInboxRepository.confirmTrip`), `CoverageInvalidator.invalidateForTrip` deletes the affected `coverage_cache` rows. Phase 8's compute service must re-populate them afterward. **Wire this explicitly:** after invalidation, trigger the compute service for the affected regions.

### Risk 3: Per-vehicle hook cleanliness (COV-08)

Phase 8 computes GLOBAL coverage only (no `vehicle_id` filter). The `trips.vehicle_id` column is nullable and already exists (`lib/core/db/tables/trips_table.dart:13`). For Phase 9 compatibility:
- Keep the `coverage_cache.region_id` PK as `osmId.toString()` (no vehicle dimension in the PK for now).
- In the compute service, leave a `// TODO(phase-9): add vehicleId parameter and filter driven_way_intervals by trip.vehicle_id` comment.
- Phase 9 will either add a `vehicle_id` column to `coverage_cache` (new migration) or create a separate `coverage_cache_by_vehicle` table.

---

## Code Examples

### regionAt call (after ensureLoaded)

```dart
// Source: lib/features/admin/data/admin_region_lookup.dart:117-129
// After ensureLoaded() — returns in microseconds (sync bbox scan + PIP test)
Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async {
  await ensureLoaded();                    // No-op after first load
  final candidates = _byLevel![adminLevel]; // O(1) map lookup
  if (candidates == null) return null;
  for (final region in candidates) {       // Linear scan, bbox-culled
    if (region.containsPoint(lat, lon)) return region;  // Ray-cast
  }
  return null;
}
```

### Coverage % computation

```dart
// Source: lib/features/coverage/domain/interval_union.dart:72
// Source: lib/features/coverage/domain/coverage_threshold.dart:79
double percent(double drivenLengthM, double totalLengthM) {
  if (totalLengthM <= 0) return 0;
  return (drivenLengthM / totalLengthM * 100).clamp(0, 100);
}

// One decimal: percent.toStringAsFixed(1) + '%'
```

### Camera fit to region bbox

```dart
// Source: lib/features/trips/presentation/widgets/trip_overlay_layers.dart:247-255
// AdminRegion has bboxMinLat/Lon/MaxLat/Lon directly
await controller.animateCamera(
  CameraUpdate.newLatLngBounds(
    LatLngBounds(
      southwest: LatLng(region.bboxMinLat, region.bboxMinLon),
      northeast: LatLng(region.bboxMaxLat, region.bboxMaxLon),
    ),
    left: 40, top: 40, right: 40, bottom: 40,
  ),
  duration: const Duration(milliseconds: 500),
);
```

### onCameraMove callback (confirmed in maplibre_gl-0.26.2)

```dart
// Source: maplibre_gl-0.26.2/lib/src/controller.dart:116
// Source: maplibre_gl-0.26.2/lib/src/maplibre_map.dart:295
// typedef OnCameraMoveCallback = void Function(CameraPosition cameraPosition);
// Add to MapLibreMap constructor in map_widget.dart:
onCameraMove: (CameraPosition pos) {
  // Emit to a StreamController or update a dedicated provider for live pill
  // Use a debounce timer here — NOT in the callback itself
},
```

### `DrivenWayIntervalsDao.getAllIntervals()` usage pattern

```dart
// Source: lib/core/db/daos/driven_way_intervals_dao.dart:53
// Returns ALL intervals across ALL trips (way-centric, trip-agnostic).
// Rows whose tripId is null (trip deleted) are included — coverage survives trip deletion.
final allIntervals = await intervalsDao.getAllIntervals();
final byWayId = <int, List<Interval>>{};
for (final row in allIntervals) {
  byWayId.putIfAbsent(row.wayId, () => []).add(Interval(row.startMeters, row.endMeters));
}
```

### `CoverageCacheDao.upsert()` usage pattern

```dart
// Source: lib/features/coverage/data/coverage_cache_dao.dart:30-45
await cacheDao.upsert(
  regionId: region.osmId.toString(),
  drivenLengthM: accumulator.driven,
  totalLengthM: accumulator.total,
  updatedAt: DateTime.now(),
  extractVersion: null,  // Phase 10 wires this
);
```

### GlassPill two-line focus content

```dart
// Replaces lib/features/map/presentation/widgets/focus_area_pill.dart
// 0-dim guard inherited from GlassPill via LayoutBuilder
GlassPill(
  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Text(name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      Text('${percent.toStringAsFixed(1)}%', style: theme.textTheme.bodySmall),
    ],
  ),
),
```

---

## State of the Art

| Old Approach | Current Approach | Impact for Phase 8 |
|--------------|-----------------|-------------------|
| Grid-indexed bbox scan (OOM) | Linear per-level bbox scan | Safe to call `regionAt` in loops; ~20K regions |
| Stub FocusAreaPill | Live ConsumerWidget needed | Replace the stub in-place |
| RegionsScreen placeholder | Full screen needed | Replace the placeholder |
| coverage_cache never written | Phase 8 writes it | First population of this table |
| onCameraIdle only | onCameraMove available | Use for live-during-movement pill |

**Deprecated/outdated:**
- `FocusAreaPill` stub at `lib/features/map/presentation/widgets/focus_area_pill.dart` — replace entirely.
- `RegionsScreen` placeholder at `lib/features/regions/presentation/regions_screen.dart` — replace entirely.
- FOC-06 (breadcrumb) — explicitly deferred/removed in `08-CONTEXT.md:43`.
- REG-01 (tabbed by admin level) — replaced by flat mixed-level list per `08-CONTEXT.md:34`.
- REG-03 (alternative sorts) — only % descending in Phase 8.
- REG-05 (driven ways list, top trips) — permanently dropped per `08-CONTEXT.md:45`.

---

## Open Questions

1. **Level 9 in Germany bundle**: Level 9 (Samtgemeinde) regions exist in the bundle (`admin_region.dart:32` mentions "2/4/6/8/9/10 per plan scope"). The coverage invalidator only uses `[4, 6, 8, 10]`. Should Phase 8's compute and browser include level 9?
   - What we know: Level 9 is in the bundle; ~900 Samtgemeinde exist in Lower Saxony.
   - Recommendation: Include level 9 in the compute pass and browser to be complete. The pill zoom mapping recommends level 9 at zoom 13-14.

2. **Coverage compute trigger timing**: When should the compute service run after `confirmTrip` invalidates rows?
   - What we know: `CoverageInvalidator.invalidateForTrip` only deletes rows. There's no hook to trigger recompute after deletion.
   - Recommendation: Add a `triggerRecomputeForRegions(Set<String> regionIds)` method to the compute service; call it from `TripsInboxRepository.confirmTrip` after invalidation (same ordering rule as the invalidation: after the status flip).

3. **Overpass cache coverage for total-km computation**: The `fetchWaysInBbox` path returns all cached Kfz ways. But for regions where no trip has been taken, no tiles may be cached.
   - What we know: `throwOnError: false` returns whatever is cached offline. Coverage compute for "total km" requires the Overpass cache to have been populated (which happens when a trip goes through the area and road-fetch runs).
   - Recommendation: `totalLengthM` will be 0 for uncached regions (no trip ever came close). This is correct behavior — if no road data is cached, there's nothing to display. Include a note in the compute service.

---

## Sources

### Primary (HIGH confidence)
- `lib/features/admin/data/admin_region_lookup.dart` — admin lookup impl, single-flight, linear bbox scan
- `lib/features/admin/data/admin_region.dart` — AdminRegion model + containsPoint
- `lib/features/admin/data/admin_region_providers.dart` — adminRegionLookupProvider
- `lib/core/db/tables/coverage_cache_table.dart` — coverage_cache schema
- `lib/features/coverage/data/coverage_cache_dao.dart` — CoverageCacheDao upsert/read
- `lib/features/coverage/data/coverage_invalidator.dart` — invalidation triggers, kCoverageAdminLevels
- `lib/features/map/presentation/providers/camera_state_provider.dart` — CameraStateNotifier
- `lib/features/map/presentation/widgets/map_widget.dart` — onCameraIdle, onCameraMove slot
- `lib/features/map/presentation/widgets/glass_pill.dart` — GlassPill, 0-dim guard
- `lib/features/map/presentation/widgets/focus_area_pill.dart` — stub (Phase 8 replaces)
- `lib/features/regions/presentation/regions_screen.dart` — placeholder (Phase 8 replaces)
- `lib/features/trips/presentation/widgets/trip_overlay_layers.dart:247-255` — CameraUpdate.newLatLngBounds pattern
- `lib/core/db/tables/driven_intervals_table.dart` — DrivenWayIntervals schema
- `lib/core/db/tables/trips_table.dart` — trips schema (durationSeconds, vehicleId)
- `maplibre_gl-0.26.2/lib/src/controller.dart:116` — OnCameraMoveCallback typedef confirmed
- `maplibre_gl-0.26.2/lib/src/maplibre_map.dart:295` — onCameraMove parameter confirmed
- `maplibre_gl_platform_interface-0.26.2/lib/src/camera.dart:109` — CameraUpdate.newLatLngBounds confirmed

### Secondary (MEDIUM confidence)
- `lib/features/coverage/domain/interval_union.dart` — drivenLengthMeters, isolate-safe
- `lib/features/coverage/domain/coverage_threshold.dart` — classifyCoverage
- `lib/features/coverage/data/driven_way_geometry_resolver.dart` — compute pattern for iterating intervals + ways
- `.planning/REQUIREMENTS.md` — FOC-01..07, REG-01..07, COV-04/07/08 requirements
- `lib/core/db/app_database.dart` — schema version 3, all tables
- `lib/features/matching/domain/way_candidate.dart` — kfzHighwayClasses (14 classes)

---

## Metadata

**Confidence breakdown:**
- Data model / schema: HIGH — read from actual source files
- Admin lookup mechanism: HIGH — read full implementation
- Camera API: HIGH — verified in maplibre_gl-0.26.2 pub cache
- Coverage compute (Phase 8 new): MEDIUM — algorithm design inferred from existing Phase 7 resolver pattern
- Fuzzy search recommendation: HIGH — pure Dart approach, no third-party verification needed
- Zoom-to-level breakpoints: MEDIUM — recommended values, not grounded in user testing

**Research date:** 2026-07-10
**Valid until:** 2026-08-10 (stable; no fast-moving external dependencies)
