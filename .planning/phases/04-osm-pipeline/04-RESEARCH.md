# Phase 4 (Rescoped): Map & Matching Data Sources — Research

**Researched:** 2026-07-08
**Domain:** External OSM data sources (map tiles, road geometry, admin polygons, geocoding) + Flutter integration
**Confidence:** HIGH on API endpoints and quotas (verified against official docs); MEDIUM on payload sizes and Kumi mirror (community-reported); LOW on quota-exceed HTTP status codes (docs are silent, must be probed).

## Summary

The rescoped Phase 4 replaces the abandoned "bundle 200 MB → 2.5 GB osm.sqlite" architecture with an **OSM-client architecture**: fetched vector tiles from MapTiler Cloud for the visual map, on-demand Overpass API road fetches per trip for map-matching, a small bundled GeoJSON of Germany admin polygons for the focus-area pill (refreshable via Settings), and Nominatim only if the bundled admin GeoJSON lacks names (spoiler: it doesn't — 04-17 is likely deletable).

The existing `tool/osm_pipeline/` sub-package stays untouched as a dev-only fixture generator for Phase 5's golden corpus; the Wave 2 `WayCandidateSource` interface is what lets Phase 5 tests continue to consume it. The runtime app never touches PBF, R-Tree, or admin joins — it just fetches JSON and paints tiles.

**Primary recommendation:** Wave 1 (MapTiler swap) is the quickest, lowest-risk win — deletes 3 deps, removes the loopback HTTP server, and gives infinite zoom. Do it first even if the Overpass adapter takes longer than expected. Do NOT invest engineering effort in a self-hosted Overpass instance or in tile caching beyond what MapLibre's built-in disk cache already provides.

## 1. MapTiler Cloud

### Style + tile URL format (HIGH confidence)

- **Style JSON:** `https://api.maptiler.com/maps/{mapId}/style.json?key={KEY}`
- **Vector tiles:** referenced from within the style JSON (`sources.openmaptiles.url = https://api.maptiler.com/tiles/v3/tiles.json?key={KEY}` — MapLibre resolves this into per-tile URLs automatically)
- **Raster tiles (fallback / offline hack):** `https://api.maptiler.com/maps/{mapId}/256/{z}/{x}/{y}.png?key={KEY}`
- **Sprite:** `https://api.maptiler.com/maps/{mapId}/sprite.png?key={KEY}`
- **Glyphs (fonts):** `https://api.maptiler.com/fonts/{fontstack}/{range}.pbf?key={KEY}`

**Practical implication:** for Wave 1 we point `styleString` at the MapTiler style URL directly and let MapLibre resolve everything. We do NOT rewrite `assets/map_style_light.json` from scratch; instead, MapTiler serves a complete style and the "rewrite" from CONTEXT is now a "point at MapTiler" + light overrides for our brand colors.

### Recommended style IDs (MEDIUM confidence — dashboard-listed, not in the docs API reference)

MapTiler exposes multiple styles; the following exist and work today on the free tier:

| Style ID | Description | Notes |
|----------|-------------|-------|
| `streets-v2` | Google-Maps-like default | Widely used, dense POIs |
| `basic-v2` | Minimal roads + admin | Best for driven-way overlay legibility |
| `bright-v2` | High-contrast light | Alternative light option |
| `outdoor-v2` | Topo/hiking-oriented | Not a fit for Trailblazer |
| `topo-v2` | Terrain shading | Not a fit |
| `winter-v2` | Snow style | Not a fit |
| `hybrid` | Satellite + labels | Raster, expensive |
| `dataviz` (`dataviz-dark`, `dataviz-light`) | Neutral basemap | Great candidate for our dark overlay theme |

**Recommendation:** default to `dataviz` (light) + `dataviz-dark` — they're deliberately muted, which makes the future driven-way overlay pop. Fall back to `streets-v2`/`streets-v2-dark` if user testing shows the map feels too empty.

**Confidence note:** The MapTiler docs API pages I fetched only show `streets-v4` as an example; the full catalog lives in the (auth-gated) dashboard at `https://cloud.maptiler.com/maps/`. Plan should include a 15-min spike in Wave 1 to confirm exact IDs by opening the dashboard once with a real account key.

### Free-tier quota (HIGH confidence)

- **100,000 API requests / month total** on the free plan — pooled across tiles, geocoding, elevation, etc. (source: MapTiler pricing page). One map render on the app is ≈ 15–40 tile requests depending on viewport size; cold-cache first launch might be 60–80 requests. Rough back-of-envelope: ~1,500–3,000 fresh map viewings per month per user before the quota bites. Personal use = never bites.
- **Additional cap: 5,000 "map sessions" / month.** A "map session" is a distinct end-user viewing the map (not per-tile). This is the tighter of the two caps for our use.
- **Behavior on exceed:** MapTiler docs state "service will pause until the next month without an upgrade to paid plans" — but do NOT specify the HTTP status (likely 402 Payment Required or 403 Forbidden; unverified). MapLibre GL will silently show blank tiles.
- **Free plan requires MapTiler logo attribution on the map**, plus text "© MapTiler © OpenStreetMap contributors" with clickable links (see §Attribution below).

### API key delivery best practices (HIGH confidence)

- **Use `--dart-define=MAPTILER_KEY=…`** at build time. Read via `const String kMaptilerKey = String.fromEnvironment('MAPTILER_KEY');` — the `const` is important; it inlines the value and lets the compiler tree-shake dead paths.
- **CI (`.github/workflows/*`):** add `MAPTILER_KEY` as a repo secret; inject via `flutter build … --dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }}`.
- **Local dev:** wrap `flutter run` in a shell script that reads from a gitignored `.env.local` file, OR use `--dart-define-from-file=env/dev.json` (Dart SDK ≥ 3.1). Recommendation: use `--dart-define-from-file` — cleaner, one flag.
- **Restrict the key at MapTiler dashboard** to specific `Origin`/`Referer` headers where possible (Android/iOS don't send Origin — but restricting to `de.autoexplore.*` bundle IDs / package names via the User-Agent-style HTTP-Referer field in the dashboard is a defense-in-depth win).
- **Do NOT commit the key.** Even the "restricted for personal use" free-tier key is a nuisance if scraped.

**Empty-key guard:** if `kMaptilerKey.isEmpty`, the app should show a diagnostic banner "MapTiler key not configured — set MAPTILER_KEY at build time" instead of a blank map. Cheap check, saves a lot of head-scratching in fresh clones.

### Attribution requirements (HIGH confidence)

Must display visibly on the map surface (Phase 2 currently pushes MapLibre's default attribution button off-screen at `Point(-9999, -9999)` and defers to Settings > About — this is legally OK for OSM but MapTiler requires more):

- **Text:** `© MapTiler © OpenStreetMap contributors`
- **Links must be clickable** to `https://www.maptiler.com/copyright/` and `https://www.openstreetmap.org/copyright`.
- **MapTiler logo required on free plan.** Cannot be hidden, cannot be moved off-screen. Bottom-left or bottom-right, sized so it's readable.

**Practical implication for Wave 1:** the current off-screen attribution trick needs to end. Either (a) restore MapLibre's built-in attribution button on-screen (fastest), or (b) build a small always-visible glass-styled attribution chip in the bottom-left. Recommend (a) for Wave 1 and defer (b) to a later polish pass — CONTEXT already earmarked custom-styled attribution as deferred.

### OpenMapTiles schema layer names (HIGH confidence)

The vector tiles MapTiler serves follow the OpenMapTiles v3 schema. Our rewritten style JSON references these `source-layer` names:

| Layer | Contains | Key fields |
|-------|----------|-----------|
| `transportation` | Roads, rails, aeroways | `class` (motorway/trunk/primary/secondary/tertiary/minor/service/track/path), `subclass`, `oneway`, `brunnel`, `surface`, `network` |
| `transportation_name` | Road labels | `name`, `ref`, `class`, `network` |
| `boundary` | Admin lines | `admin_level` (2, 4, 6, 8, …), `disputed`, `maritime` |
| `water` | Oceans + lakes (polygons) | `class` (ocean/lake/river/pond) |
| `waterway` | Rivers + canals (lines) | `class`, `brunnel` |
| `place` | Cities, towns, states | `name`, `class` (city/town/village/…), `rank`, `capital`, `iso_a2` |
| `landuse`, `landcover`, `park`, `building`, `poi`, `aeroway`, `mountain_peak`, `water_name`, `housenumber`, `aerodrome_label` | Standard fills / decorations | Various |

**Style-rewrite scope (04-12):** the current Trailblazer style JSON uses layer names `water`, `roads`, `admin_boundaries`, `labels` (custom Trailblazer schema from the abandoned pipeline). All references must be renamed: `roads` → `transportation`, `admin_boundaries` → `boundary`, `labels` → split into `transportation_name` + `place`. The `water` layer stays a name-collision but the internal `kind` field becomes `class`.

### Fallback: Stadia Maps / Protomaps (LOW confidence — I could not confirm exact quotas)

- **Stadia Maps** — free tier for non-commercial. Quotas not published on the docs pages I fetched; the reference "200k/month" from user memory is community-cited (memory file `overpass-and-tile-provider-options.md`, unverified against Stadia's own limits page which behind auth-wall in my fetch).
  - Style URL pattern: `https://tiles.stadiamaps.com/styles/{styleId}.json?api_key={KEY}`
  - Style IDs: `alidade_smooth`, `alidade_smooth_dark`, `osm_bright`, `stamen_toner`.
- **Protomaps (hosted PMTiles on CDN)** — free tier available; user hosts a slim PMTiles archive on Cloudflare R2 / GitHub Pages. This is a "self-serve" fallback if MapTiler quota bites. Not needed in Wave 1.

**Recommendation:** ship Wave 1 with MapTiler only. Wire a "tile provider" enum (`TileProvider.mapTiler`) into `mapStyleAssetProvider` refactored to `mapStyleUrlProvider`, so a future Stadia fallback needs to change one line. Do NOT actually implement Stadia until we see a real quota problem.

## 2. Overpass API

### Endpoints (HIGH confidence primary; MEDIUM on mirrors)

| Endpoint | Owner | Notes |
|----------|-------|-------|
| `https://overpass-api.de/api/interpreter` | FOSSGIS (primary) | v0.7.62.11, rate-limit 2 concurrent slots per IP |
| `https://overpass.private.coffee/api/interpreter` | Private.coffee | Explicitly listed as public mirror by their operator; ask before bulk |
| `https://maps.mail.ru/osm/tools/overpass/api/interpreter` | VK Maps (Russia) | Documented mirror, no request limits per operator |
| `https://overpass.kumi.systems/api/interpreter` | Kumi Systems | Widely cited in community + user memory. I could NOT fetch this URL to confirm status — treat as MEDIUM confidence. Wave 2 spike: curl-probe this before wiring it as fallback. |

**Fallback chain recommendation (Wave 2):**
1. Primary: `overpass-api.de` (FOSSGIS)
2. On 429 / 504 / connection error, retry after backoff.
3. On second failure, fall through to `overpass.kumi.systems`.
4. On third failure, surface user-visible error + queue for later retry (see "offline pending state" below).

### Rate limits (HIGH confidence)

- **Fair-use guideline:** "less than 10,000 queries/day and less than 1 GB/day" on the FOSSGIS instance. A Trailblazer user finishing 3–10 trips/day fires 3–10 Overpass queries; this is nowhere near the limit.
- **Per-IP concurrency:** 2 slots on FOSSGIS (`https://overpass-api.de/api/status` shows this in real time). Trailblazer is single-user single-device so this is fine.
- **User-Agent header MANDATORY:** the Overpass docs explicitly require identifying `User-Agent` OR `Referer`. Send e.g. `User-Agent: Trailblazer/0.1 (github.com/…)`.
- **Rate-limit response:** community-documented as HTTP 429 (Too Many Requests) when slots exhausted, HTTP 504 or "too many requests" body on overload. Docs don't state this explicitly (LOW confidence on exact codes — treat both 429 and 5xx as "retry with backoff").

### Query for `highway=* ways in bbox` (HIGH confidence)

```
[out:json][timeout:25];
way[highway]({south},{west},{north},{east});
out geom qt;
```

- `[out:json]` — JSON output, not XML (smaller + easier to parse in Dart).
- `[timeout:25]` — server-side timeout in seconds; 25 is safe; 60+ is asking for trouble.
- `way[highway](...)` — bbox filter with all ways carrying any `highway=*` tag.
- `out geom` — inlines full lat/lon geometry per way (no separate node fetch needed).
- `qt` — quadtile sort order (very cheap on server, faster serialization).

**Filter-at-query vs filter-client-side trade-off:**
- Query is 200 bytes either way — sending a broad `way[highway]` is fine.
- Filtering the Kfz-vs-Feldweg-vs-service split **on the client** in Dart is preferable — the server-side regex `[highway~"^(motorway|primary|…|residential)$"]` adds server CPU cost but zero network savings on a bbox this size, and it means one canonical filter list in Dart shared between runtime + fixture-PBF paths.
- **Recommendation:** send the broad query, apply the Kfz allowlist (14 classes from CONTEXT) in Dart.

**Alternative query for named-highways-only** (drops unnamed service roads, cuts payload ~30%):
```
[out:json][timeout:25];
way[highway][name]({south},{west},{north},{east});
out geom qt;
```
Not recommended — Trailblazer's map-matcher needs unnamed residential streets too.

### Response format (HIGH confidence)

Each `way` element:
```json
{
  "type": "way",
  "id": 4256789,
  "geometry": [
    {"lat": 52.5000988, "lon": 13.3810251},
    {"lat": 52.4999420, "lon": 13.3809153}
  ],
  "nodes": [123, 456, 789],
  "tags": {
    "highway": "residential",
    "name": "Möckernstraße",
    "oneway": "yes",
    "maxspeed": "30"
  }
}
```

Note: `geometry` is a top-level array of `{lat, lon}` objects — NOT GeoJSON coordinates order (which is `[lon, lat]`). Wave 2 code must translate to internal WKB-compatible `(lng, lat)` ordering matching `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart:488-505`.

### Expected payload size (MEDIUM confidence — extrapolated from community benchmarks)

For a 5×5 km bbox (25 km²):
- Dense urban (Berlin Kreuzberg): ~1500–3500 ways, ~40–120 KB gzip'd JSON, ~200–600 KB uncompressed.
- Suburban (Berlin outskirts): ~400–1000 ways, ~15–40 KB gzip'd.
- Rural (Grebenhain): ~150–400 ways, ~5–15 KB gzip'd.

A typical short trip's bbox is 2–10 km² — well under 100 KB gzip'd. A long autobahn cross-country trip bbox padded to 200 km × 20 km might hit 300–800 KB and should be split into tiles (see below).

### Tile-key strategy (MEDIUM confidence — architectural judgment call)

The choice of cache key affects hit-rate and cache size. Three options considered:

| Strategy | Pros | Cons | Verdict |
|----------|------|------|---------|
| **Slippy z12 tile (WMTS xyz)** | Trivial coord math; global consistency; predictable overlap | Fixed grid means trip bbox = several tiles even for a short trip. Tile size varies wildly by latitude. | ✓ Recommended |
| **Fixed lat/lng grid (0.05° cells ≈ 5 km at DE)** | Same as slippy but latitude-uniform | Custom math; no cross-tool tooling | Fine but nothing beats slippy |
| **Per admin region (Kreis / Gemeinde)** | Aligns with coverage aggregation | Region polygons vary in size 3 orders of magnitude — bad cache uniformity | ✗ |

**Recommendation:** slippy tiles at **z=12** (each tile ≈ 10 km × 7 km at DE latitude). Trip-bbox → set of z12 tiles it intersects → cache lookup per tile → fetch missing tiles → union. This is the well-trodden pattern used by Mapbox Vector Tiles and every mobile mapping app.

**Coalescing:**
- If a trip touches N z12 tiles, fire **one** Overpass query with the smallest bbox covering all missing tiles (server prefers few big queries over many small ones — the server-side per-query fixed cost dominates for small bboxes).
- Alternative: split into N per-tile queries, run in parallel with concurrency=2 (matching the FOSSGIS slot count). Simpler cache write, slightly slower on cold cache. **Recommendation:** single-query-with-union for trips up to ~4 z12 tiles; per-tile fetch for larger trips. Wave 2 can start with "always single query" and add splitting only if a real trip exceeds ~1 MB payload.

### TTL recommendation (MEDIUM confidence)

- **30 days.** Rationale: OSM edits happen daily but rarely change existing road geometry — most edits are POIs, addresses, tags. Roads a user drove yesterday will still be there next month with the same geometry.
- **Cache-bust on manual "Refresh map data" Settings button** (aligns with Wave 3's admin-polygon refresh button).
- Do NOT try to use ETag / If-Modified-Since with Overpass — it doesn't support them.

### Backoff + fallback policy (HIGH confidence design)

```
Attempt 1: primary endpoint, timeout 30s
  Success → cache + return
  429/503/504 → sleep 2s, retry
  5xx → sleep 5s, retry
  timeout → immediately fallback endpoint
Attempt 2: primary endpoint (retry)
  Success → cache + return
  Any error → fallback endpoint
Attempt 3: fallback endpoint (kumi.systems)
  Success → cache + return
  Any error → mark as pending (see below), surface user-visible error
```

### Offline `pending_road_data` state design (MEDIUM confidence recommendation)

Trips that finish while offline should NOT block the app. Add a lightweight queue:

- New Drift table `pending_road_fetches (trip_id, bbox_minlat, bbox_minlon, bbox_maxlat, bbox_maxlon, attempts, last_attempt_at, created_at)`.
- On trip finish: enqueue immediately, then attempt fetch in a background task. On success: matcher runs → coverage recompute → row deleted.
- On app resume: check queue, retry pending fetches (respect exponential backoff: 5 min → 30 min → 2 h → 12 h → 24 h → abandon after 5 attempts).
- **This IS part of Wave 2 — do not defer.** Without it, "user finishes trip in tunnel / plane / rural notspot" means silently lost data.

## 3. Geofabrik admin polygons

### The data source problem (HIGH confidence)

**Geofabrik does NOT publish a ready-made admin-boundary shapefile for Germany.** The Germany page (`https://download.geofabrik.de/europe/germany.html`) explicitly says "germany-latest-free.shp.zip is not available for this region; try one of the sub-regions". This is the same trap the memory file mentioned by name ("Geofabrik-derived") but doesn't spell out.

**Real options for the bundled admin polygons:**

| Source | Levels available | Format | License | Verdict |
|--------|------------------|--------|---------|---------|
| **Overpass one-shot download (via `tool/osm_pipeline` script)** | 2, 4, 5, 6, 7, 8, 9, 10 — every OSM admin_level | GeoJSON via `out geom` → jq/dart transform | ODbL | ✓ **Recommended.** Existing `tool/osm_pipeline` already parses OSM data — add one small `bin/fetch_admin_polygons.dart` that calls Overpass once for Germany, filters to levels 2/4/6/8, writes `assets/admin_de.geojson`. |
| **Geofabrik full PBF (germany-latest.osm.pbf)** | All | PBF, 4.5 GB | ODbL | ✗ Too big for CI; existing pipeline already handles this but adds friction. |
| **GADM v4** | Country (0) → State (1) → Kreis (2) → Verbandsgemeinde (3) | GeoJSON / Shapefile / GeoPackage | Non-commercial only — check terms | ✗ License unclear for commercial-adjacent use |
| **Natural Earth** | Country + admin-1 only | Shapefile | Public domain | ✗ Not granular enough (no Gemeinde) |
| **NUTS (Eurostat)** | Country → Bundesland → Regierungsbezirk | GeoJSON | Reuse allowed | Only 3 levels, misses Gemeinde/Kreis granularity |

**Query for the one-shot download (Wave 3 build step):**
```
[out:json][timeout:600];
area["ISO3166-1"="DE"][admin_level=2]->.de;
(
  relation["boundary"="administrative"]["admin_level"~"^(2|4|6|8)$"](area.de);
);
out geom;
```

This runs once (takes 30–90 s server-side, produces ~40–80 MB JSON), and the output feeds a Dart transformer that:
1. Assembles relations into single-polygon GeoJSON `Feature`s with `properties: {osm_id, admin_level, name, name:de}`.
2. Applies Douglas-Peucker simplification (target: <10 m tolerance at level 2, <50 m at level 8 — visual boundaries only, matcher never uses them).
3. Writes `assets/admin_de_l2.geojson.gz`, `admin_de_l4.geojson.gz`, `admin_de_l6.geojson.gz`, `admin_de_l8.geojson.gz`.

**Consequence for CONTEXT.md's "Geofabrik-derived" phrasing:** it's terminologically wrong but architecturally the same intent — a one-shot download that feeds a bundled asset. Plan 04-16 should be titled "OSM-derived admin polygons via `tool/osm_pipeline/bin/fetch_admin_polygons.dart`".

### Single GeoJSON vs split per level (HIGH confidence design)

- **Split per level.** Reasons: (a) L2 is 1 polygon and always loaded (country outline); L8 is ~11,000 Gemeinden and only needed when zoomed in; (b) partial-loading saves cold-start memory; (c) refresh cadence differs (L2 never changes; L8 changes yearly).

### Size estimates (MEDIUM confidence)

Ballpark for Germany after Douglas-Peucker simplification:

| Level | Polygon count | Raw GeoJSON | Simplified + gzip | Notes |
|-------|--------------|-------------|-------------------|-------|
| 2 (country) | 1 | 800 KB | 40 KB | Very smooth |
| 4 (Bundesland) | 16 | 12 MB | 250 KB | Coastline detail dominates |
| 6 (Regierungsbezirk) | ~40 | 15 MB | 400 KB | Not every state uses L6 |
| 8 (Gemeinde) | ~11,000 | 300 MB | 6–12 MB | Bulk of the payload |

**Total bundled asset budget:** ~8–15 MB gzip'd. Compare to the abandoned 200 MB → 2.5 GB spiral — this is a rounding error. If simplification tolerance is aggressive at L8 (200 m tolerance, still visually fine on a phone screen), we can push under 5 MB.

### Runtime spatial lookup strategy (MEDIUM confidence)

For the focus-area pill ("Grebenhain · 26 %"), we need `pointToRegion(lat, lng) → Region` in <5 ms:

| Strategy | Memory | Query time | Verdict |
|----------|--------|-----------|---------|
| **Brute force + bbox prefilter** | Just the polygons (~20 MB decompressed) | ~15–30 ms worst case at L8 | Simple but too slow on hot path |
| **Precomputed spatial hash grid (0.01° cells)** | +5 MB in-memory index | ~1–3 ms | ✓ **Recommended.** Build at first-use, cache in memory. |
| **R-Tree in-memory (via `dart:collection` or a package)** | +10 MB | ~1 ms | Fine but adds a dependency; grid is simpler |
| **In-SQLite R-Tree** | Zero RAM | ~2–5 ms | Requires Drift table for polygons — overkill |

**Recommendation:** hash grid built lazily on first spatial query. Keep polygons in memory as raw GeoJSON `Feature` structures decoded via `dart:convert` on cold-start. Total memory footprint ~25 MB for the L8 dataset — comfortable on any phone.

### Refresh mechanism (HIGH confidence design)

- Settings > "Refresh region data" button → downloads new GeoJSON asset bundle from a GitHub-Pages-hosted URL (`https://<user>.github.io/trailblazer-data/admin_de_v{n}.tar.gz`), replaces the bundled version in app documents dir.
- Version stamp in `AppPrefs` (already exists as v1 table): `admin_bundle_version` string.
- On app startup, compare app-shipped bundle version with docs-dir version; use the newer.
- CI job (out of Phase 4 scope, mention in 04-18 close-out): monthly job builds a fresh bundle, tags a GitHub release, updates the GH Pages URL.

## 4. Nominatim

### Endpoint + policy (HIGH confidence)

- **Endpoint:** `https://nominatim.openstreetmap.org/reverse?lat={lat}&lon={lon}&format=jsonv2&addressdetails=1&zoom={10..18}`
- **Max rate:** **1 request/second** absolute maximum, per the OSMF usage policy.
- **User-Agent MANDATORY** (identifying the app + contact email/URL). Requests without it may be blocked without warning.
- **No auto-complete, no scraping, no bulk grid.** Trailblazer's use (occasional reverse-lookup for the focus-area pill) is squarely within acceptable use.
- **Response:** returns `address` object with `country`, `state`, `county`, `city`, `town`, `village`, `municipality`, `suburb`, `road`, etc.

### CRITICAL: Is 04-17 deletable? (HIGH confidence — YES, likely deletable)

The bundled admin GeoJSON from §3 carries `name` (and `name:de`) per polygon — because that's what OSM tags them with, and the Overpass `out geom` output preserves every tag on relations. So:

- **Focus-area pill "Grebenhain · 26 %"**: purely from bundled data. No Nominatim needed.
- **Trip start/end labels ("From: Grebenhain, To: Berlin")**: also from bundled data — reverse the point through the hash grid → look up polygon name.
- **When would Nominatim actually be needed?** Only for sub-Gemeinde granularity (street name, house number, POI at a coordinate). That's not a Phase 4 SC — it's a Phase 8+ concern (if it ever surfaces).

**Recommendation:** DELETE plan 04-17 from the wave structure. The 8-plan / 4-wave shrinks to 7 plans / 4 waves:
- Wave 3 becomes single-plan: 04-16 (admin polygons + spatial lookup + name resolution all in one).
- If Nominatim becomes needed later (never say never), it lives in a future feature phase, not Phase 4.

**Flag for planner:** confirm this deletion with the user before committing. It's a defensible call but reverses one of the "locked" wave-3 items in the CONTEXT preamble.

## 5. Drift migration + cache schema

### Migration v2 → v3 pattern (HIGH confidence)

Following the existing v1→v2 pattern in `lib/core/db/app_database.dart:35-47`:

```dart
@override
int get schemaVersion => 3;

@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (m) async {
    await m.createAll();
  },
  onUpgrade: (m, from, to) async {
    if (from < 2) {
      // ... existing v1→v2 columns
    }
    if (from < 3) {
      await m.createTable(overpassWayCache);
      await m.createTable(pendingRoadFetches);
    }
  },
  beforeOpen: (details) async {
    await customStatement('PRAGMA foreign_keys = ON');
    await customStatement('PRAGMA journal_mode = WAL');
  },
);
```

**Codegen ordering (see project CLAUDE.md):** `build_runner build` + `drift_dev schema generate` MUST run before `flutter analyze`. New table classes get added to the `@DriftDatabase(tables: [...])` list in `app_database.dart:18-26`.

**Schema JSON export:** `dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/drift_schema_v3.json`. Commit this file — it's the source of truth (`test/generated_migrations/` is gitignored).

**Migration test:** add `test/core/db/migration_v2_to_v3_test.dart` mirroring the existing `migration_v1_to_v2_test.dart` — seed a v2 DB, run migration, assert new tables exist.

### Recommended `overpass_way_cache` shape (MEDIUM confidence design)

```dart
class OverpassWayCache extends Table {
  IntColumn get id => integer().autoIncrement()();
  // Cache key: slippy z12 tile.
  IntColumn get tileZ => integer()();
  IntColumn get tileX => integer()();
  IntColumn get tileY => integer()();
  // When this tile was fetched (for TTL enforcement).
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();
  // How many way rows are inside this tile (debugging + LRU heuristic).
  IntColumn get wayCount => integer()();
  // Compressed raw JSON payload from Overpass (gzip'd).
  BlobColumn get payloadGzip => blob()();
  // Byte size of the compressed payload (LRU eviction driver).
  IntColumn get payloadBytes => integer()();

  @override
  Set<Column> get primaryKey => {tileZ, tileX, tileY};
}
```

**Rationale:**
- Storing the **raw compressed JSON** rather than a parsed `ways` table means (a) we don't duplicate the `tool/osm_pipeline` schema; (b) decode-on-demand is fast enough; (c) cache is dead-simple to invalidate (just delete rows).
- Separate `overpass_ways_parsed` table would only pay off if we run many queries per fetch. Real usage: fetch once → parse once → feed matcher once → done.

**Alternative — parse-and-store approach:** if Phase 5's matcher needs random-access `findWaysNear(lat, lng, r)` from persisted data (not just for the current trip), then a parsed table with an R-Tree becomes necessary. Recommendation: DEFER that decision to Phase 5 planning — Wave 2 stores raw blobs, Phase 5 can add parsed tables + index if it needs them.

### Size cap + LRU eviction (MEDIUM confidence)

- **Budget: 50 MB compressed cache.** At ~30 KB/tile average urban and ~5 KB/tile rural, that's 1500–10000 z12 tiles cached — orders of magnitude more than any personal-use pattern needs.
- **Eviction policy:** on write, if `SUM(payloadBytes) > 50 * 1024 * 1024`, delete oldest `fetchedAt` rows until under 40 MB. Simple, effective, no separate GC pass.
- **TTL sweep:** on app cold-start (background isolate), `DELETE FROM overpass_way_cache WHERE fetchedAt < now() - 30 days`.

### `pending_road_fetches` shape

```dart
class PendingRoadFetches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tripId => integer()
      .references(Trips, #id, onDelete: KeyAction.cascade)();
  RealColumn get bboxMinLat => real()();
  RealColumn get bboxMinLon => real()();
  RealColumn get bboxMaxLat => real()();
  RealColumn get bboxMaxLon => real()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
```

Cascade delete on trip deletion — if the user deletes a trip that never got matched, drop the pending fetch too.

### WKB encode/decode reuse from `tool/osm_pipeline` (HIGH confidence)

The runtime app path stores **raw JSON blobs** (per §above), so WKB is NOT needed at runtime. The `_encodeLineStringWkb` / `decodeLineStringWkb` helpers in `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart:488-543` stay in the pipeline sub-package and are consumed only by the fixture-PBF `WayCandidateSource` for Phase 5 tests.

**However:** the `WayCandidate` domain model (§6 below) uses a plain `List<LatLng>` for geometry. The Overpass adapter converts `[{lat, lon}, ...]` → `List<LatLng>` directly; no WKB involved on the runtime side. Clean seam.

## 6. WayCandidateSource interface

### Draft Dart interface (HIGH confidence design)

```dart
// lib/features/matching/domain/way_candidate.dart
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Immutable snapshot of a single OSM way, in the shape the Phase 5 HMM
/// matcher consumes. Mirrors the columns produced by
/// `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart` for the ways table
/// so a fixture-PBF-backed source can produce identical data to the
/// runtime Overpass-backed source.
class WayCandidate {
  const WayCandidate({
    required this.wayId,
    required this.geometry,
    required this.highwayClass,
    this.name,
    this.ref,
    this.oneway = OnewayDirection.no,
    this.maxspeedKmh,
  });

  /// OSM way ID — stable across sources.
  final int wayId;

  /// Ordered polyline of the way, WGS84 (lat, lng).
  final List<LatLng> geometry;

  /// `highway=*` tag value: motorway | trunk | primary | ...
  final String highwayClass;

  /// `name` tag, if present.
  final String? name;

  /// `ref` tag (e.g. "A5", "B27"), if present.
  final String? ref;

  /// Normalized directionality — always populated even when tag missing.
  final OnewayDirection oneway;

  /// `maxspeed` parsed to km/h. Null when tag is missing or unparseable
  /// (e.g. "signals", "walk").
  final int? maxspeedKmh;
}

enum OnewayDirection { no, forward, backward }
```

```dart
// lib/features/matching/data/way_candidate_source.dart
abstract class WayCandidateSource {
  /// Return all Kfz-drivable ways whose bbox overlaps the given bbox.
  /// Implementations must:
  ///   * Apply the 14-class Kfz allowlist (see PhaseKfzClasses).
  ///   * Return empty list on network error only if `throwOnError` is false.
  ///   * Deduplicate by wayId across cache-tile boundaries.
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  });
}
```

Two implementations:
- `OverpassWayCandidateSource` — Wave 2, runtime.
- `FixturePbfWayCandidateSource` — Phase 5 tests, backed by a small `test/fixtures/berlin_small.osm.pbf` produced by `tool/osm_pipeline`.

### Test-impl location (HIGH confidence)

**Recommend:** `test/helpers/fixture_way_candidate_source.dart` (following the existing pattern: `test/helpers/fake_tile_server.dart`, `test/helpers/fake_background_geolocation_facade.dart`). Do NOT put it in `tool/osm_pipeline` — that sub-package should not be a runtime test dependency of the main app.

The fixture PBF itself can live in `test/fixtures/` (gitignored — regenerated on first test run by a small CI-friendly script) OR checked in if it's under 5 MB. Recommend the latter — makes CI cache-cold-friendly and reproducible.

## 7. Testing strategy Wave 2

### HTTP mocking pattern (HIGH confidence)

Use `package:http` 1.x with `Client` injection + `MockClient`:

```dart
// pubspec.yaml
dependencies:
  http: ^1.2.0

// lib/features/matching/data/overpass_client.dart
class OverpassClient {
  OverpassClient({http.Client? client, this.endpoint = _primary})
      : _client = client ?? http.Client();
  final http.Client _client;
  // ...
}

// test/features/matching/overpass_client_test.dart
import 'package:http/testing.dart';

test('parses ways from bbox response', () async {
  final mock = MockClient((req) async {
    expect(req.url.path, contains('/api/interpreter'));
    return http.Response(_fixtureJson('berlin_kreuzberg_5x5km.json'), 200);
  });
  final client = OverpassClient(client: mock);
  final ways = await client.fetchWaysInBbox(/* ... */);
  expect(ways, hasLength(greaterThan(500)));
});
```

Do NOT use `mocktail` for HTTP — `MockClient` is purpose-built and easier. `mocktail` remains the tool for repository/service mocks.

### Overpass fixture files (HIGH confidence)

Bundle three fixtures in `test/fixtures/overpass/`:

| File | Purpose | Size |
|------|---------|------|
| `urban_kreuzberg_5x5km.json` | Dense urban response — many ways, many tags | ~200 KB uncompressed |
| `rural_grebenhain_5x5km.json` | Sparse rural — few ways, mostly unnamed | ~15 KB |
| `overload_429.txt` | Verbatim HTTP 429 body from FOSSGIS | <1 KB |
| `timeout_504.txt` | Verbatim HTTP 504 body (server timeout) | <1 KB |

Fixtures generated by running the real Overpass query once, saving output. Store as gzipped in-repo, unzip in test setup.

### Cache integration test outline (HIGH confidence)

```dart
group('OverpassWayCandidateSource with Drift cache', () {
  late AppDatabase db;
  late MockClient httpMock;
  late OverpassWayCandidateSource source;
  var callCount = 0;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    callCount = 0;
    httpMock = MockClient((req) async {
      callCount++;
      return http.Response(_fixture('urban.json'), 200);
    });
    source = OverpassWayCandidateSource(
      db: db,
      client: httpMock,
      now: () => DateTime(2026, 7, 8),
    );
  });

  test('first fetch hits network', () async {
    await source.fetchWaysInBbox(/* bbox */);
    expect(callCount, 1);
  });

  test('second fetch same bbox hits cache', () async {
    await source.fetchWaysInBbox(/* bbox */);
    await source.fetchWaysInBbox(/* bbox */);
    expect(callCount, 1);
  });

  test('cache miss on TTL expiry', () async {
    await source.fetchWaysInBbox(/* bbox */);
    source = source.copyWith(now: () => DateTime(2026, 8, 15)); // +38 days
    await source.fetchWaysInBbox(/* bbox */);
    expect(callCount, 2);
  });

  test('429 response triggers fallback endpoint', () async { /* ... */ });
  test('pending queue enqueues on total failure', () async { /* ... */ });
});
```

## 8. Phase 5 consequences (nudge)

### What Phase 5 imports from Phase 4 (HIGH confidence)

- `WayCandidate` model (§6).
- `WayCandidateSource` interface (§6).
- Riverpod provider: `wayCandidateSourceProvider` (Provider<WayCandidateSource>).
- Utility: `KfzHighwayClasses` const list (the 14 tags from CONTEXT).

### Providers to publish from Phase 4 (HIGH confidence design)

```dart
// lib/features/matching/data/matching_providers.dart
final overpassEndpointProvider = Provider<Uri>((_) =>
    Uri.parse('https://overpass-api.de/api/interpreter'));

final overpassFallbackEndpointProvider = Provider<Uri>((_) =>
    Uri.parse('https://overpass.kumi.systems/api/interpreter'));

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final wayCandidateSourceProvider = Provider<WayCandidateSource>((ref) {
  return OverpassWayCandidateSource(
    db: ref.watch(appDatabaseProvider),
    client: ref.watch(httpClientProvider),
    endpoint: ref.watch(overpassEndpointProvider),
    fallbackEndpoint: ref.watch(overpassFallbackEndpointProvider),
  );
});

final adminRegionLookupProvider = FutureProvider<AdminRegionLookup>((ref) async {
  return AdminRegionLookup.loadFromAssets();
});
```

### Isolate / async-fetch coordination (MEDIUM confidence — a real risk)

Phase 5's matcher runs in an isolate (per its plan). The Overpass fetch is a network call — it can't run in the isolate that has the SQLite handle to `AppDatabase` because Drift isolates need dedicated ports. Two options:

**Option A:** Fetch on main isolate → serialize `List<WayCandidate>` → send to matcher isolate → matcher does pure computation → returns match results. **Recommended.** Simpler, one fetch per trip.

**Option B:** Matcher isolate calls back to main via `SendPort` when it needs more ways. More flexible but adds message-passing complexity.

**Recommendation:** Wave 2 wires Option A. Phase 5 planning re-evaluates only if the matcher genuinely needs streaming.

### Coverage recompute after cache write (HIGH confidence)

Phase 8's coverage cache is invalidated whenever new `driven_intervals` land (existing pattern from earlier phases via `invalidationGen`). The Overpass fetch → match → intervals-write flow reuses that mechanism unchanged. No new coordination needed in Phase 4.

## 9. Risks + spike candidates

### High-priority risks

1. **MapTiler style catalog uncertainty.** Docs I could fetch only reference `streets-v4` as example. Exact IDs like `dataviz`, `basic-v2` are widely used in community examples but not authoritatively listed on the docs pages I could access.
   - **Spike (Wave 1, 15 min):** open MapTiler dashboard with a real free-tier key, list available style IDs, confirm URL pattern with one live curl.

2. **Kumi Systems mirror status unverified.** `overpass.kumi.systems` is community-cited but I could not confirm the URL is live in 2026-07.
   - **Spike (Wave 2, 5 min):** `curl -sI https://overpass.kumi.systems/api/status` — if 200, wire as fallback. If down, use `overpass.private.coffee` instead (docs-verified alive).

3. **MapTiler + Liquid Glass composition on Android.** The current pipeline uses a bundled PMTiles archive served via loopback. MapTiler serves live HTTPS tiles. Android's WebView / MapLibre-native compositor stacking with `liquid_glass_renderer` was tuned once for that setup. Risk: fresh live-network tile loads change frame timings and trigger a Liquid Glass regression.
   - **Spike (Wave 1, 30 min):** MapTiler URL swap + real-device Android smoke test with the glass FAB visible on top of a fresh cold-cache map. If any flicker or `Picture.toImageSync` crash, capture stack trace before committing 04-11.

4. **Overpass single-query max payload.** A cross-country autobahn trip's bbox at 500 km × 20 km could exceed Overpass server memory (`maxsize` default 512 MB but per-user practical limit lower). Response could be 5–20 MB uncompressed.
   - **Spike (Wave 2, 30 min):** run a real query for the largest realistic trip bbox (Berlin → Munich), measure response size + parse time. Determines whether the tile-split logic in §2 is mandatory or optional for v1.

5. **Attribution UI regression.** Current app pushes MapLibre's built-in attribution off-screen. MapTiler + free-tier legally requires it visible plus MapTiler logo.
   - **Not really a spike — a definite todo in 04-12.** Restoring MapLibre's default attribution button on bottom-left is 3 lines. The Liquid Glass compatibility of that button (which uses native rendering) needs a visual check.

### Medium risks

6. **API key committed by accident.** `--dart-define` values leak into build logs and stack traces if not careful.
   - **Mitigation:** documented empty-key sentinel in 04-11; CI grep for `MAPTILER_KEY=[a-zA-Z]` in committed files (pre-commit hook).

7. **Bundle asset size on Android APK.** 15 MB of gzipped admin GeoJSON increases APK by 15 MB. Play Store split-APK limits are 150 MB compressed — comfortable margin, but iOS App Store cellular-download limit is 200 MB. Still safe.

8. **Overpass adds trip-finish latency.** A trip finishes; matcher can't run until Overpass responds (2–15 s typical). Phase 3's "trip finished" UX must tolerate an async pending state.
   - **Design note for Wave 2:** already covered by `pending_road_fetches` queue — trip finish is instant, matching is background.

### Deletable? Plan 04-17 (Nominatim)

See §4 — recommend dropping 04-17 entirely. Wave 3 shrinks from 2 plans to 1 plan.

## Sources

### Primary (HIGH confidence)
- MapTiler pricing: https://www.maptiler.com/cloud/pricing/ (100k/month, 5k sessions)
- MapTiler Maps API: https://docs.maptiler.com/cloud/api/maps/ (style URL format)
- MapTiler copyright: https://www.maptiler.com/copyright/ (attribution requirements)
- OpenMapTiles schema: https://openmaptiles.org/schema/ (16 layers)
- OSM Wiki Overpass API: https://wiki.openstreetmap.org/wiki/Overpass_API (endpoints, 10k/day guideline)
- Overpass QL guide: https://wiki.openstreetmap.org/wiki/Overpass_API/Overpass_QL (JSON output, `out geom`)
- Overpass API by Example: https://wiki.openstreetmap.org/wiki/Overpass_API/Overpass_API_by_Example (admin_level regex query)
- Overpass status endpoint: https://overpass-api.de/api/status (2-slot concurrency)
- Overpass JSON output format: https://dev.overpass-api.de/output_formats.html (way element structure)
- Nominatim reverse endpoint: https://nominatim.org/release-docs/develop/api/Reverse/ (jsonv2 + addressdetails)
- Nominatim usage policy: https://operations.osmfoundation.org/policies/nominatim/ (1 req/sec)
- Geofabrik Germany page: https://download.geofabrik.de/europe/germany.html (SHP not available)
- Drift migration API: https://drift.simonbinder.eu/docs/advanced-features/migrations/ (createTable pattern)
- Live Overpass query executed: `https://overpass-api.de/api/interpreter?data=[out:json]...` returned real Kreuzberg way payload — confirmed `geometry` array structure.
- Codebase files consulted:
  - `lib/core/db/app_database.dart:32-54` (existing v2 migration pattern)
  - `lib/features/map/data/tile_server.dart` (loopback shim, to be deleted)
  - `lib/features/map/presentation/providers/map_style_provider.dart` (existing style-asset provider to refactor)
  - `lib/features/map/presentation/widgets/map_widget.dart:184-187` (attribution off-screen hack to reverse)
  - `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart:488-543` (WKB helpers — stay in pipeline, not runtime)
  - `test/core/db/migration_v1_to_v2_test.dart` (migration test template for v2→v3)
  - `test/helpers/fake_tile_server.dart`, `fake_background_geolocation_facade.dart` (test-double naming convention)
  - `pubspec.yaml` (deps to remove: `pmtiles`, `shelf`, `shelf_router`; deps to add: `http`)

### Secondary (MEDIUM confidence)
- MapTiler style ID catalog (dashboard-listed, no docs page found): `streets-v2`, `basic-v2`, `bright-v2`, `outdoor-v2`, `dataviz`, `dataviz-dark`
- Payload size estimates: extrapolated from Overpass Turbo community benchmarks and one live query, not measured for all bboxes
- Overpass rate-limit response code (429 vs 5xx): docs silent, community-cited
- Kumi Systems mirror endpoint URL: user memory + community reference, not fetch-verifiable in this session
- GADM Germany granularity (down to Verbandsgemeinde): user memory
- Stadia Maps 200k/month quota: from user memory, not confirmed on docs

### Tertiary (LOW confidence — flag for validation)
- Exact HTTP status on MapTiler quota exceed (402 vs 403 vs blank tiles): unverified
- Whether `overpass.kumi.systems` is currently reachable: pending live curl in Wave 2
- Douglas-Peucker tolerance vs visual acceptability at L8: estimated, not tested
- Overpass single-query max payload for cross-Germany bbox: risk item, not measured

## Metadata

**Confidence breakdown:**
- MapTiler stack (API URLs, quota, schema): HIGH — official docs + pricing page cross-referenced
- Overpass stack (endpoints, query, format): HIGH — official docs + one live query executed
- Overpass rate-limit behavior on failure: MEDIUM — docs describe fair-use, not enforcement HTTP codes
- Geofabrik admin polygons: MEDIUM — the "Geofabrik-derived" phrasing from CONTEXT is inaccurate; Overpass one-shot is the real path
- Nominatim + deletion of 04-17: HIGH on API, MEDIUM on the deletion recommendation (planner should get user sign-off)
- Drift v2→v3 pattern: HIGH — mirrors existing v1→v2 in the codebase
- WayCandidateSource design: MEDIUM — architectural recommendation; final shape decided during Wave 2 planning
- Testing strategy: HIGH — `MockClient` + fixture files is the established Flutter idiom
- Phase 5 consequences: MEDIUM — depends on Phase 5's isolate coordination choice
- Risks / spikes: MEDIUM — spike list is prescriptive but each spike must actually run

**Research date:** 2026-07-08
**Valid until:** 2026-09-08 (30-day window on API docs; sooner if MapTiler pricing changes)
