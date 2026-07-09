# Phase 6: Inbox + Match Wire-Up — Research

**Researched:** 2026-07-09
**Domain:** Flutter UI (inbox card list, static map thumbnails), Drift schema migration, coverage-cache invalidation, reverse-geocoding, matcher enqueue orchestration, golden corpus expansion
**Confidence:** HIGH on codebase state (files verified); HIGH on maplibre_gl snapshot API (verified in pub cache); HIGH on schema+existing infrastructure; MEDIUM on thumbnail rendering approach; MEDIUM on invalidation strategy (multiple viable paths).

---

## Executive Summary

Phase 6 is primarily a **wiring + UI phase**, not a new-algorithm phase. Almost every piece of infrastructure already exists:

- `trips.vehicle_id` **already exists** as a nullable INT (schema v3 confirmed) — NO schema bump needed for the vehicle_id column. See "Q7 — App DB migration."
- `coverage_cache` table **already exists** at schema v3 with `regionId` (PK), `drivenLengthM`, `totalLengthM`, `updatedAt`, `extractVersion`, `invalidationGen`. NO new table needed.
- `TripStatus` enum already has `confirmed` and `rejected` variants (Phase 3 seed) — but converter comment omits `pendingRoadData`. Comment-only fix needed.
- Matcher pipeline is fully wired: `TripMatchCoordinator.onTripReadyForMatching(tripId)` is triggered by `TripRoadFetchCoordinator` on trip-stop; writes intervals; transitions `pending → matched`. **Phase 6 must add `matched → confirmed` (Keep) and `matched → hard-delete` (Discard) transitions.**
- Admin polygons + `AdminRegionLookup.regionAt(lat, lon, adminLevel)` are already in-memory and <5 ms/lookup — reverse-geocoding is a direct call.
- `maplibre_gl 0.26.2` **has** `takeSnapshot({width, height})` on `MapLibreMapController` — verified in pub cache at `controller.dart:2009`. Cross-platform (iOS/Android/Web).

**Primary recommendation:** Ship P6 as **6 plans** across **3 waves**. Wave 1 (parallel, 4 plans) builds independent data-layer pieces: coverage cache DAO + invalidator, reverse-geocoder service, matcher queue watcher, thumbnail renderer. Wave 2 (2 plans, one after Wave 1) builds the UI: Inbox screen + Trip History screen. Wave 3 (1 plan) is golden-corpus expansion via a debug export path.

---

## Answers to Research Questions

### Q1 — Static-map thumbnail rendering approach

**FACT:** `MapLibreMapController.takeSnapshot({int? width, int? height})` returns `Future<Uint8List>` (PNG bytes), works on iOS/Android/Web per the package changelog. Uses an offscreen renderer preserving camera position/style. Verified: `maplibre_gl_platform_interface-0.26.2/lib/src/method_channel_maplibre_gl.dart:1090` and `maplibre_gl-0.26.2/lib/src/controller.dart:2009`. HIGH confidence.

**Three candidate approaches:**

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **A. Pre-bake at trip-stop** (spin up hidden `MapLibreMap`, `addGeoJsonSource` polyline, `moveCamera` to bbox, `takeSnapshot`, save PNG to app-docs, drop path into a new `trips.thumbnail_path` column) | Cheap at inbox render time (Image.file). Battery-cost paid once. Works offline for repeat views. | Requires a hidden widget in the tree at trip-stop → complicates `TrackingService`. Extra schema column. Bytes on disk. | Not recommended — adds coupling between tracking service and widget tree. |
| **B. Offscreen on-demand per card** (each `TripCard` briefly builds a `MapLibreMap` with `SizedBox(width: 320, height: 120)`, awaits `waitUntilMapTilesAreLoaded()`, calls `takeSnapshot`, disposes) | No schema change. Always current. | Spinning up N maps in a scrolling list is heavy. Battery + network (tiles refetched). List jank likely. | Not recommended. |
| **C. Lazy-pre-bake on first inbox view + cache in memory + disk** (`ThumbnailCache` keyed by `tripId`; on first card build, spin up ONE offscreen `MapLibreMap` at 320×120, layer polyline via `addGeoJsonSource` + `addLineLayer`, `moveCamera(newLatLngBounds(...))` from trip bbox with 40px padding, `waitUntilMapTilesAreLoaded()`, `takeSnapshot`, cache to `<AppDocs>/thumbs/<tripId>.png`) | No schema change. Battery-cost only on first view. Repeat views instant. Card renders `Image.file` synchronously with `FileImage` caching. Cache invalidation trivial (`File.delete` on trip delete). | Requires one offscreen `MapLibreMap` widget stack (headless). First-view cost per card. | **RECOMMENDED.** Best perf/battery/UX balance. Same code path reusable for Trip History detail. |

**Implementation note for C:** MapLibre's headless snapshot requires the widget to actually be laid out (`Offstage` + `SizedBox` in a hidden overlay of the `TripsScreen`). Reuse the existing `mapControllerProvider` factory pattern — a dedicated `thumbnailMapControllerProvider` scoped to the thumbnail-renderer. Fall back to a plain polyline-on-neutral-background `CustomPainter` if `takeSnapshot` throws (belt-and-suspenders — `takeSnapshot` is v0.26.2-new; unproven on Trailblazer's target devices).

**Pitfall:** MapLibre wipes programmatic sources on `setStyle()`. Dark-mode swap during thumbnail render would blank the polyline. Force `styleString` from `mapStyleUrlProvider` at build time and don't listen to brightness changes on the thumbnail map.

### Q2 — Reverse geocoding from bundled admin polygons

**FACT:** `AdminRegionLookup.regionAt(lat, lon, adminLevel)` already exists at `lib/features/admin/data/admin_region_lookup.dart`. Hash grid at 0.01° cells (~1.1km). <5ms per lookup after warm-up. HIGH confidence — file verified.

**Bundle contents:** Germany admin_level values `2/4/6/8/9/10` per the Overpass query in `packages/admin_geometry/lib/src/admin_polygon_downloader.dart:45`. Mapping:
- 2 = Land (DE)
- 4 = Bundesland (Bayern)
- 6 = Regierungsbezirk (Unterfranken)
- 8 = Landkreis or kreisfreie Stadt (Miltenberg)
- 9 = Amt/Verwaltungsgemeinschaft (rare)
- 10 = Gemeinde (Kleinheubach)

**Card readability recommendation:** Use **level 8 (Landkreis/Stadt) with fallback to level 10 (Gemeinde)** on the trip card. Rationale:
- Level 8 gives a familiar administrative name for locals ("Miltenberg", "Aschaffenburg") — recognizable and unique in most of DE.
- Level 10 (Gemeinde) is often too granular for a card ("Kleinheubach" vs. driver's actual perception "just left home").
- Fall back to level 10 only when level 8 returns null (over water, over disputed boundary).
- Display format: `"$startName → $endName"` (e.g. "Miltenberg → Aschaffenburg"). When start == end, show just `startName` with a small "loop" indicator.

**Placement in architecture:** A new `TripPlaceLookup` domain service in `lib/features/trips/domain/` that wraps `AdminRegionLookup` for the two-endpoint (start/end) query. Called at trip-card build time or memoized in a Provider keyed by `tripId`. `AdminRegionLookup` is already `Provider<AdminRegionLookup>` (see `admin_region_providers.dart:11`).

**Do NOT build:** New spatial index — the hash grid already meets the <5ms budget.

### Q3 — Interval merging (COV-01: overlaps collapsed into unions per way)

**Current state:** `HmmMatcher._collapseToIntervals` (hmm_matcher.dart:120) already merges consecutive per-trip steps into intervals by wayId. `DrivenWayIntervalsDao.insertBatch` appends them as raw rows. **The per-trip intra-way merge exists. What P6 needs is per-way cross-trip UNION** for `coverage_by_region` calculation.

**Recommendation — sweep-line union in Dart at cache-recompute time (NOT at write time):**

- **Don't** try to maintain a canonical merged interval table on every insert (write amplification; complex delete semantics).
- **Do** keep `driven_way_intervals` as an append-only log (one row per matcher output), and compute the per-way union **on demand** during cache recomputation.

**Algorithm** — per way:
```
sort intervals by startMeters
merged = []
for i in intervals:
  if merged.isEmpty or merged.last.end < i.start: merged.append(i)
  else: merged.last.end = max(merged.last.end, i.end)
drivenLengthForWay = sum(end - start for m in merged)
```

**Location in code:** New pure-Dart utility `lib/features/coverage/domain/interval_union.dart` (Drift-free, testable in isolation, isolate-safe). Consumed by `CoverageRecomputeService` (see Q4).

**Alternative considered:** Drift SQL trigger doing `INSERT OR REPLACE` on merge. **Rejected** — SQLite has no native interval-union operator; would require a stored procedure emulation via multiple statements per insert, and complicates the delete-trip path significantly.

### Q4 — `coverage_by_region` cache schema + invalidation

**FACT:** Table `coverage_cache` **already exists at schema v3** with:
```
regionId TEXT PK, drivenLengthM REAL, totalLengthM REAL,
updatedAt DATETIME, extractVersion TEXT?, invalidationGen INT DEFAULT 0
```
Verified `lib/core/db/tables/coverage_cache_table.dart` and `drift_schemas/drift_schema_v3.json`. HIGH confidence.

**Naming discrepancy with roadmap:** ROADMAP references `coverage_by_region` (COV-05); actual table is `coverage_cache`. **Recommendation: KEEP the existing name.** Renaming would require a v3→v4 migration for no functional benefit.

**Column adequacy for P6:** Sufficient. `invalidationGen` (already present) is the invalidation counter. **No schema bump needed for coverage.**

**Missing dimension — admin level:** The current PK is `regionId` alone (OSM relation ID as string). To surface "N%, last computed X" for a specific admin level, `regionId` string uniquely identifies the polygon since OSM relation IDs are globally unique across levels. Adequate.

**Recommended invalidation pattern — "bump-and-lazy-recompute":**

1. **Write path** (matcher completes): a `CoverageInvalidator` service resolves affected regions (point-in-polygon on the trip's bbox corners + midpoints; conservative — invalidate all matched levels). For each affected `regionId`: `UPDATE coverage_cache SET invalidation_gen = invalidation_gen + 1 WHERE region_id = ?`.
2. **Read path** (user opens Regions screen — Phase 8): reads `coverage_cache`; if `invalidation_gen > lastComputedGen` OR `updatedAt` is null, triggers recompute in-place.
3. **Cheaper alternative for P6 scope:** Since Regions screen isn't in P6, `CoverageInvalidator` can simply DELETE the affected `coverage_cache` rows and let Phase 8 recompute on first read. Test coverage stays trivial.

**Recommendation for P6:** **DELETE affected rows** on invalidation, keep `invalidationGen` untouched. Phase 8 will introduce the read-side recompute. This is a smaller P6 surface and matches the "hook may be a stub in P6" spirit of the CONTEXT.

### Q5 — Invalidation trigger wiring (COV-06)

Three triggers active in P6:

1. **New intervals written** — Extend `TripMatchCoordinator._writeIntervals` (line 145) or add a hook right after `transitionToMatched(tripId)` (line 130). Call `CoverageInvalidator.invalidateForTrip(tripId)` which:
   - Reads the trip row's bbox
   - Samples corners + centroid → `AdminRegionLookup.regionAt(lat, lon, level)` for levels 4/6/8/10
   - Collects unique `regionId`s → issues one `DELETE FROM coverage_cache WHERE region_id IN (?)` batch.

2. **Trip deleted from history** — `TripsRepository.deleteTrip(tripId)` is where the CASCADE runs. **Extend it to:**
   - BEFORE deletion, read the trip's bbox (deletion cascades trip_points but NOT intervals — FK is `ON DELETE SET NULL`).
   - Compute affected regions the same way as (1).
   - Delete `driven_way_intervals` rows explicitly (they'd otherwise linger as tripId=NULL orphans).
   - Delete the trip row (CASCADE handles trip_points).
   - Invalidate cache.

3. **OSM extract updated** — Phase 10 concern. **Stub** in P6: `CoverageInvalidator.invalidateAll()` that truncates `coverage_cache`. Called from a Provider that Phase 10 will wire to the extract-update signal. Zero UI in P6.

**Location:** `lib/features/coverage/data/coverage_invalidator.dart`. Provider in `coverage_providers.dart`. All three triggers point to the same invalidator API.

### Q6 — Trip History detail screen (map + intervals overlay)

**Reuse the existing `MapWidget`** with additional layers. The widget is already provider-driven, has `onMapCreated` callback exposing the controller. Approach:

1. Create `TripDetailScreen` (`lib/features/trips/presentation/trip_detail_screen.dart`) — full-screen route, NOT a shell branch (like `/settings`).
2. Wrap `MapWidget` and use `onStyleLoaded` callback to:
   - `addGeoJsonSource('trip_raw', ...)` with the raw polyline from `TripsDao.listPointsForTrip(tripId)`.
   - `addLineLayer('trip_raw', 'trip_raw_layer', LineLayerProperties(lineColor: <gray>, lineWidth: 3, lineOpacity: 0.4))`.
   - Query intervals via `DrivenWayIntervalsDao.getByTrip(tripId)` and — for each way, walking the way's stored geometry from Overpass cache — build a GeoJSON FeatureCollection of matched segments.
   - `addGeoJsonSource('trip_matched', ...)` + `addLineLayer('trip_matched', 'trip_matched_layer', LineLayerProperties(lineColor: <accent>, lineWidth: 5))`.
   - `moveCamera(CameraUpdate.newLatLngBounds(...))` from trip bbox.
3. **Reuse in Phase 7:** Same layer names + provider (`tripOverlayProvider`) can be extracted to `lib/features/coverage/presentation/trip_overlay_layers.dart` for Phase 7's app-wide coverage paint.

**Gotcha:** `MapWidget` currently swaps style on brightness change and wipes programmatic layers. `TripDetailScreen` must re-add layers inside `_onStyleLoaded`. Extract the layer-add logic into a reusable function.

**Way geometry lookup:** `OverpassWayCacheDao` stores gzipped Overpass payloads per tile. To reconstruct the polyline of a specific way at detail time, either (a) re-fetch the trip's bbox from cache and pluck the way IDs, or (b) add a `driven_ways_geometry` cache (over-engineering for P6). Recommendation: **(a)** — same code path as `TripMatchCoordinator._source.fetchWaysInBbox`. Ways are already cache-first; second call is free.

### Q7 — App DB migration

**FACT:** `trips.vehicle_id` **already exists** at schema v3 (verified `drift_schemas/drift_schema_v3.json:109` and `trips_table.dart:17`). HIGH confidence.

**Implication:** **NO migration needed for `vehicle_id`.** The column was seeded eagerly in v1 (or earlier), anticipating Phase 9. Phase 6 just starts *reading* it as nullable — no schema bump. `TripStatus.rejected` is already in the enum. `coverage_cache` already exists.

**When would P6 need a migration?** Only if the plan chooses to add a `thumbnail_path TEXT NULL` column to trips (approach A from Q1) — but the recommended approach C uses on-disk file cache keyed by `tripId`, no DB column. **Recommendation: no schema bump in P6.** Schema stays at v3.

**If a migration IS added:** bump to v4, add `if (from < 4) { await m.addColumn(trips, trips.<newcol>); }`, generate v4 schema snapshot via `dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas`, then `dart run drift_dev schema generate drift_schemas test/generated_migrations`, add `migration_v3_to_v4_test.dart` following the pattern in `test/core/db/migration_v2_to_v3_test.dart`.

### Q8 — Matcher enqueue wiring

**Current state:** Matcher runs **automatically at trip-stop time** — `TripRoadFetchCoordinator.onTripStopped` → `transitionToPending` → `matchCoordinator.onTripReadyForMatching(tripId)` fire-and-forget. Trips reach the inbox in `matched` state.

**Implication:** In P6 semantics, **"Keep" does NOT enqueue matching** — matching has already run by the time the user sees the card. Keep transitions `matched → confirmed`; the "N trips matching in background" indicator counts trips still in `pending` / `pendingRoadData` (trips whose matcher hasn't returned yet, e.g. offline queue).

**Post-Keep flow:**
1. User taps Keep → `TripsRepository.transitionToConfirmed(tripId)` (new method — add to DAO + repo alongside existing transition helpers).
2. Card disappears from Inbox stream (filter `status == matched`).
3. Trip appears in History stream (filter `status IN (matched, confirmed, pendingRoadData, pending)` — matched shows in-flight pill; confirmed shows normal row).

**Global queue indicator:** `matcherQueueSizeProvider` = a `StreamProvider<int>` watching `TripsDao.watchInFlightTripCount()` (COUNT of rows where `status IN (pendingRoadData, pending)`). Renders as a Liquid Glass pill above the Inbox when > 0. Persists across app restarts because it's a DB query — matches Phase 3's cold-start rehydration pattern.

**Persistence across restart:** No queue table needed. The `pending` status IS the queue. `TripMatchCoordinator.processPending()` runs on `AppLifecycleState.resumed` (already wired via `TripRoadFetchCoordinator.drainQueue`).

**New DAO methods:**
- `TripsDao.watchInboxTrips()` — WATCH `status = matched`, ORDER BY endedAt DESC.
- `TripsDao.watchHistoryTrips()` — WATCH `status IN (matched, confirmed, pending, pendingRoadData)`, ORDER BY endedAt DESC (matched + in-flight interleave chronologically).
- `TripsDao.watchInFlightCount()` — WATCH COUNT where `status IN (pending, pendingRoadData)`.
- `TripsDao.transitionToConfirmed(int tripId)` — status flip only.

### Q9 — Golden corpus expansion (1 → ≥ 20 fixtures)

**Current state:** `test/features/matching/golden_corpus_test.dart` iterates `test/fixtures/golden_trips/*/` and asserts wayId sequence match. One fixture exists (`001_synthetic_straight_east`). Fixture format = `(gps_trace.json, ways.json.gz, expected_ways.json)` triple per directory.

**Workflow recommendation — export from Trip History detail screen (debug-mode only):**

1. In `TripDetailScreen`, in `kDebugMode`, add a floating action: **"Export as golden fixture"**.
2. Handler:
   - Read `TripsDao.listPointsForTrip(tripId)` → serialize as `gps_trace.json`.
   - Read the trip's bbox → `OverpassWayCandidateSource.fetchWaysInBbox(...)` → serialize the raw Overpass payload as `ways.json.gz` (the cache DAO already stores it gzipped).
   - Read `DrivenWayIntervalsDao.getByTrip(tripId)` → serialize as `expected_ways.json` (`[{wayId: ...}, ...]`).
   - Write to `<AppDocs>/golden_export/<slug>/` — user copies to repo manually.
3. Slug naming: `NNN_<region>_<scenario>` e.g. `002_kleinheubach_roundabout`.

**Where the 20 fixtures come from:** User's own drives in Kleinheubach + gym-trip corridor + Aschaffenburg + a few motorway spans. Since P6 close-out is a batched drive checkpoint anyway (per memory `phase-4-drives-deferred-to-gym-trip`), fixtures accumulate naturally as the user drives during P6 dogfooding.

**Location:** New file `lib/features/trips/presentation/widgets/debug_export_button.dart` (guarded by `kDebugMode` so tree-shaken from release).

### Q10 — Fail-matched trip UX (0 driven intervals)

**Recommendation: distinct status pill on History rows, no separate enum state.**

Reasoning: adding a `matchedZeroIntervals` enum value bloats the status machine (converter, migration test, everywhere). Better to derive at read-time:

- `TripHistoryRow` displays `status = matched, drivenIntervalCount = 0` → "No roads matched" chip in warning color + a subtitle like "GPS may have been indoors or in a parking lot."
- Same row still tappable → Detail screen shows raw polyline (no matched overlay) + delete button.
- Same for `confirmed, drivenIntervalCount = 0` — happens if the user Kept a fail-matched trip.

**DAO:** Extend `watchInboxTrips`/`watchHistoryTrips` to LEFT JOIN a `COUNT(driven_way_intervals)` subquery, exposing `interval_count` to the UI layer as a derived field on a `TripListItem` DTO.

**Handling in matcher path:** No change. `TripMatchCoordinator` already transitions null-bbox and empty-ways trips to `matched` with 0 intervals (lines 82, 98, 106). The behavior is correct — just needs the UI treatment.

---

## Concrete File Paths to Reuse

| Purpose | Path |
|---------|------|
| Trip lifecycle DAO | `lib/features/trips/data/trips_dao.dart` |
| Trip repository (Result<T> boundary) | `lib/features/trips/data/trips_repository.dart` |
| Trip status enum (already has confirmed/rejected) | `lib/features/trips/domain/trip_status.dart` |
| Matcher coordinator (entry point for post-Keep flow) | `lib/features/matching/data/trip_match_coordinator.dart` |
| Driven-intervals DAO (getByTrip, deleteByTrip, insertBatch) | `lib/core/db/daos/driven_way_intervals_dao.dart` |
| Coverage cache table (already at v3) | `lib/core/db/tables/coverage_cache_table.dart` |
| Admin region lookup (reverse geocoding) | `lib/features/admin/data/admin_region_lookup.dart` |
| Admin providers | `lib/features/admin/data/admin_region_providers.dart` |
| MapWidget (reuse for detail + thumbnail) | `lib/features/map/presentation/widgets/map_widget.dart` |
| Tile provider config (MapTiler URLs) | `lib/features/map/data/tile_provider_config.dart` |
| Overpass way candidate source (way geometry lookup) | `lib/features/matching/data/overpass_way_candidate_source.dart` |
| Trips screen placeholder (replace) | `lib/features/trips/presentation/trips_screen.dart` |
| Router (add /trips/:id detail route) | `lib/core/routing/app_router.dart` |
| Bottom nav shell (Trips tab already wired) | `lib/features/map/presentation/widgets/bottom_nav_shell.dart` |
| Domain error + Result<T> | `lib/core/errors/domain_error.dart`, `result.dart` |
| Golden corpus test (iterates fixtures automatically) | `test/features/matching/golden_corpus_test.dart` |
| Golden fixtures directory | `test/fixtures/golden_trips/` |
| Migration test pattern | `test/core/db/migration_v2_to_v3_test.dart` |

---

## Recommended Plan Slicing

**6 plans across 3 waves.** Wave 1 is heavily parallel; Waves 2 and 3 sequential.

### Wave 1 (parallel — 4 plans, independent files)

**06-01: Coverage cache DAO + invalidator (data layer)**
- New: `lib/features/coverage/data/coverage_cache_dao.dart` (DatabaseAccessor pattern per Phase 1 STATE — no `@DriftAccessor` to match trips_dao style).
- New: `lib/features/coverage/data/coverage_invalidator.dart` — three entry points (`invalidateForTrip`, `invalidateForTripDelete`, `invalidateAll` stub).
- New: `lib/features/coverage/domain/interval_union.dart` — pure Dart sweep-line merger.
- New: `lib/features/coverage/data/coverage_providers.dart`.
- Tests: `test/features/coverage/coverage_invalidator_test.dart`, `interval_union_test.dart`.

**06-02: Reverse-geocoding + trip metadata service**
- New: `lib/features/trips/domain/trip_place_lookup.dart` — wraps `AdminRegionLookup` for `(startLat, startLon, endLat, endLon) → (startName, endName)` at level 8 with 10 fallback.
- Extend: New `trips_dao.dart` queries — `watchInboxTrips`, `watchHistoryTrips`, `watchInFlightCount`, `transitionToConfirmed`, `getTripWithIntervalCount(int)` — plus DTO `TripListItem` in domain.
- Extend: `TripsRepository` — `confirmTrip(tripId)`, and the delete-invalidate-orchestration (calls invalidator BEFORE deletion, then deletes intervals + trip).
- Tests: repo + DAO tests using in-memory Drift.

**06-03: Thumbnail renderer**
- New: `lib/features/trips/presentation/widgets/trip_thumbnail.dart` — Consumer widget that reads from `thumbnailCacheProvider(tripId)`, shows placeholder while rendering, `Image.file` once ready.
- New: `lib/features/trips/data/thumbnail_cache.dart` — Notifier<Map<int, String>>, disk cache under `<AppDocs>/thumbs/`.
- New: `lib/features/trips/data/thumbnail_renderer.dart` — spins up hidden `MapLibreMap`, waits for style + tiles, adds polyline via `addGeoJsonSource` + `addLineLayer`, `moveCamera(newLatLngBounds)` with padding, `takeSnapshot`, writes PNG. Fallback: `CustomPainter` polyline on gray background if `takeSnapshot` throws.
- Tests: cache eviction + delete-invalidation.

**06-04: Matcher-queue indicator + status provider**
- New: `lib/features/trips/presentation/providers/inbox_providers.dart` — `inboxTripsProvider`, `historyTripsProvider`, `inFlightCountProvider`.
- New: `lib/features/trips/presentation/widgets/matching_queue_pill.dart` — Liquid Glass pill "N trips matching…" shown when count > 0.
- Tests: widget test with mock stream.

### Wave 2 (sequential — depends on Wave 1)

**06-05: Inbox + History UI (replaces trips_screen placeholder)**
- Replace: `lib/features/trips/presentation/trips_screen.dart` — sub-tab `TabBar` (Inbox / History), default landing driven by pending-count.
- New: `lib/features/trips/presentation/widgets/trip_card.dart` — card with thumbnail (06-03), place names (06-02), date/duration/distance, dormant vehicle chip, Keep + Discard buttons.
- New: `lib/features/trips/presentation/widgets/discard_confirmation_dialog.dart`.
- New: `lib/features/trips/presentation/widgets/history_row.dart` — with in-flight pill + fail-matched chip.
- New: `lib/features/trips/presentation/trip_detail_screen.dart` — full-screen route via `/trips/:id`. Map + raw polyline + matched intervals overlay + delete button.
- Update: `lib/core/routing/app_router.dart` — add `/trips/:id` route.
- Empty-state widgets (both tabs).
- Tests: pumpWidget golden tests for each widget; provider-override tests for Keep/Discard flows.

### Wave 3 (post-UI — 1 plan)

**06-06: Golden corpus expansion + debug export**
- New: `lib/features/trips/presentation/widgets/debug_export_button.dart` (kDebugMode-gated) attached to `TripDetailScreen`.
- Fixture recording during P6 dogfooding drives (batched at phase close-out per memory note `phase-4-drives-deferred-to-gym-trip`).
- Update: `test/fixtures/golden_trips/README.md` — document the export → commit workflow.
- Goal: ≥ 20 fixtures committed OR (if drive schedule slips) at minimum the export tooling wired + 3–5 seed fixtures.

**Parallel wave metadata hygiene** (per memory `wave-2-parallel-metadata-hygiene`): each Wave 1 plan owns a distinct, non-overlapping file set. Add an explicit "Files owned" section to each PLAN so the orchestrator's metadata commits don't sweep sibling agent work.

---

## Pitfalls / Gotchas Callouts

1. **maplibre_gl style-swap wipes programmatic layers** (already documented in `map_widget.dart:114`). Any Phase 6 screen that adds sources/layers MUST re-add them in `_onStyleLoaded`. Applies to `TripDetailScreen` AND the thumbnail renderer. Extract layer-add into a reusable function.

2. **`takeSnapshot` unproven on Trailblazer's target devices** (v0.26.2-new API, no in-repo usage). Recommendation: implement with a `try/catch → CustomPainter fallback` from day one. Log failures.

3. **`driven_way_intervals` FK is `ON DELETE SET NULL`, not CASCADE** (verified `driven_intervals_table.dart:8`). Deleting a trip does NOT drop its intervals — they orphan as `tripId=NULL`. Phase 6's delete path must call `DrivenWayIntervalsDao.deleteByTrip(tripId)` BEFORE `deleteTrip(tripId)`, or those orphaned intervals will bloat coverage forever.

4. **TripStatus converter comment stale** (`trip_status_converter.dart:6` omits `pendingRoadData`). Not a bug — the converter uses `.name` matching and iterates `TripStatus.values` — but fix the comment while touching the file.

5. **CoverageCache PK is `regionId` alone** — same OSM relation ID can't collide across admin levels (OSM guarantees globally unique relation IDs), so this is safe. Just don't naively concatenate `"$level:$regionId"` — the existing schema doesn't.

6. **`TripMatchCoordinator.processPending`** on resume queries `status = pending` — after P6, ALSO need to run on trips stuck at `pendingRoadData` after network return (already handled by `TripRoadFetchCoordinator.drainQueue`). Verify both drain paths still fire on `AppLifecycleState.resumed`.

7. **Parallel wave metadata hygiene** (from user memory): declare `Files owned` in each Wave-1 plan; orchestrator must not sweep unowned files into metadata commits.

8. **In-car verification deferred to phase close-out** (from user memory `defer-in-car-verification`): P6 plans MUST NOT contain per-plan drive checkpoints. All drive validation batched at phase close-out. Individual plans complete code-complete on `flutter analyze` + `flutter test` green.

9. **Riverpod codegen OFF** (STATE Plan 01-01, CLAUDE.md): all new providers use `Provider<T>` / `Notifier`, no `@Riverpod`. Match the pattern in `matching_providers.dart`.

10. **`withValues(alpha:)` not `withOpacity`** (CLAUDE.md): any inbox card / pill styling uses the new API.

11. **`sort_pub_dependencies` lint**: any new dep (unlikely for P6 — recommendation avoids new packages) must be alphabetized.

12. **`counts_for_coverage` column exists in `vehicles` table already** (verified `vehicles_table.dart:9`) — but the CONTEXT deliberately defers the flag to P9. In P6, all trips count for coverage; do not query `vehicles.counts_for_coverage` even though the column is there.

---

## Sources

**Primary (HIGH confidence, verified files/paths):**
- `C:\Users\I551358\AppData\Local\Pub\Cache\hosted\pub.dev\maplibre_gl-0.26.2\lib\src\controller.dart:2009` — `takeSnapshot` API.
- `C:\Users\I551358\AppData\Local\Pub\Cache\hosted\pub.dev\maplibre_gl_platform_interface-0.26.2\lib\src\method_channel_maplibre_gl.dart:1090` — platform wiring for `takeSnapshot`.
- `C:\Users\I551358\AppData\Local\Pub\Cache\hosted\pub.dev\maplibre_gl_platform_interface-0.26.2\CHANGELOG.md:23` — "Cross-platform map snapshot functionality via `takeSnapshot()` (#726)".
- `drift_schemas/drift_schema_v3.json` — verified `trips.vehicle_id` exists, `coverage_cache` exists with `invalidationGen`.
- `lib/core/db/tables/*.dart`, `lib/features/matching/**`, `lib/features/trips/**` — codebase inspected directly.
- `.planning/phases/06-inbox-match-wire-up/06-CONTEXT.md` — user-locked decisions.
- User memory: `defer-in-car-verification.md`, `phase-4-drives-deferred-to-gym-trip.md`, `wave-2-parallel-metadata-hygiene.md`.

**Secondary (MEDIUM confidence):**
- Thumbnail approach comparison — no in-repo precedent for `takeSnapshot`; approach C (lazy pre-bake + disk cache) is a design recommendation grounded in the API surface but unproven on-device.
- Level-8 vs level-10 admin readability — judgment call; user drive testing will settle it.

**Tertiary (LOW confidence / open questions):** none — CONTEXT.md locks the ambiguous decisions.

---

## Metadata

**Confidence breakdown:**
- Codebase state: HIGH (files verified directly)
- Standard stack (`maplibre_gl` snapshot, Drift patterns, admin lookup): HIGH
- Coverage-cache invalidation strategy: MEDIUM (delete-vs-bump is a design call; delete is simpler for P6)
- Thumbnail rendering approach: MEDIUM (recommendation is sound; `takeSnapshot` unproven on Trailblazer devices — fallback path required)

**Research date:** 2026-07-09
**Valid until:** 30 days (stable — no library upgrades expected mid-phase)
