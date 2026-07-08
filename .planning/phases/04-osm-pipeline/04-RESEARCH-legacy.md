# Phase 4: OSM Pipeline — Research

**Researched:** 2026-07-05
**Author:** Claude (opus-4.8, inline after gsd-phase-researcher agent hit two consecutive API errors)
**Reads:** `04-CONTEXT.md`
**Consumed by:** `gsd-planner` → `04-01-PLAN.md`..`04-NN-PLAN.md`

Answers the twelve open questions raised by `04-CONTEXT.md` and flags the OSM-02 vs CONTEXT.md `service` divergence. Every "Claude's Discretion" item in CONTEXT is closed with a concrete recommendation; each recommendation carries a one-line rationale so the planner can accept or push back rather than re-derive it.

---

## 0. Open reconciliation before planning starts

### 0.1 OSM-02 vs CONTEXT Kfz `service` divergence — **flag, do not decide silently**

`REQUIREMENTS.md:OSM-02` lists `highway=service` inside the Kfz set. `04-CONTEXT.md` under "Highway filter" locks in a 14-tag Kfz allowlist that **excludes** `service`.

The two documents disagree. Both were written by us; either is defensible:

- Excluding `service` (CONTEXT): matches drivable-experience intent — parking-lot spurs, driveways, gas-station forecourts do not read as "roads I drive" to the driver. Halves the risk of blowing the 200 MB budget on urban service-way sprawl.
- Including `service` (REQUIREMENTS): matches the raw text; makes the requirements table one-to-one with the schema.

**Recommendation:** Keep CONTEXT's exclusion. Update `REQUIREMENTS.md:OSM-02` to strike `service` from the Kfz list and note "excluded per Phase 4 CONTEXT — see decision log." The planner's first plan should include this requirements edit as a task and log the decision in `STATE.md`. Do not ship the pipeline until the two docs agree.

---

## 1. PBF parsing approach in Dart

**Recommendation: pure-Dart streaming parse via `osm_pbf_parser` (or roll our own PBF reader from the OSM PBF spec if the package is stale), NOT shell-out to `osmium`/`imposm`.**

Trade-off matrix:

| Option | License | Install burden (Windows dev box) | Reproducibility | Memory profile (Germany PBF ≈ 4 GB) |
|---|---|---|---|---|
| **Pure-Dart streaming PBF reader** | Ours | `dart pub get` only | High — one language, one lockfile | Bounded — process blocks one at a time |
| Shell out to `osmium` C++ tool | BSD | Windows binary via chocolatey OR WSL — extra setup | Medium — new host dependency to pin | Very good (osmium is best in class) |
| Shell out to `tilemaker` | FTWPL | Similar to osmium | Medium | Good |
| Shell out to `imposm3` | Apache 2 | Go binary — trivial | Medium | Good |
| JVM `planetiler` | Apache 2 | Requires JDK 21+ on dev box | Medium | Excellent |

**Why pure-Dart wins here despite osmium being technically faster:**

- Phase 4 is a **single-developer, dev-machine deliverable** (CONTEXT: "single-developer, single-machine"). The Berlin-bbox smoke path (CONTEXT: "primary dev iteration loop") wants zero external prerequisites.
- The Windows dev box already has the Dart SDK for the app. Adding osmium means chocolatey/WSL/PATH management — real friction.
- We are not tile-serving; we produce two artifacts once per PBF update. Even a 30 min full-Germany run is acceptable if the Berlin-bbox path is < 60 s.
- PBF is a well-specified format: `blob header` → `zlib-compressed protobuf block` → `PrimitiveGroup` records. A minimal streaming reader in Dart is ~600 LOC and battle-testable via a Berlin-bbox fixture.

**Concrete package to evaluate first: `osm_pbf_parser` on pub.dev.** If maintenance/quality is inadequate, we vendor a minimal reader inside `tool/osm_pipeline/pbf/` — the format spec is stable (2015 vintage) and the surface we need is small (read node/way/relation with tags; skip changesets and dense-node deltas we don't care about).

**Fallback trigger:** if the pure-Dart parse of full-Germany PBF cannot complete in < 2 hours OR blows a 4 GB heap, drop to shelling out to `osmium export` for the raw filter stage and keep Dart for downstream stages. Planner should carry this as an explicit exit criterion.

---

## 2. PMTiles authoring

**Recommendation: shell out to `tippecanoe` for the pmtiles authoring stage — do NOT hand-roll pmtiles v3 writing in Dart.**

Why the pmtiles authoring stage breaks the "pure-Dart" preference:

- PMTiles v3 is a tightly optimised binary format (Hilbert-curve tile ordering, RLE-packed directory tree, offset+length indexing). Correct + performant Dart implementation from scratch is weeks of work with no re-use value elsewhere.
- Vector tile authoring is 10× harder than PMTiles authoring — tippecanoe already solves geometry simplification, feature dropping at low zoom, tile boundary clipping, MVT protobuf encoding. Re-implementing that in Dart is out of scope for a v1.
- `tippecanoe` writes `.pmtiles` directly since v2.30 (2023). No mbtiles intermediate needed.
- License: BSD 2-Clause — compatible with our LGPL-adjacent map stack.

**Pipeline shape then becomes:**

```
Dart pipeline
  ├─ Stage A: PBF parse + filter                 (pure Dart)
  ├─ Stage B: emit GeoJSONSeq per pmtiles layer  (pure Dart, temp file)
  ├─ Stage C: exec `tippecanoe -o germany-base.pmtiles ...`  (subprocess)
  └─ Stage D: emit osm.sqlite (drift or raw sqlite3)  (pure Dart)
```

**tippecanoe install:**

- macOS/Linux dev boxes: `brew install tippecanoe` / distro package.
- Windows: no first-party binary. Build under WSL2, or use the felt/tippecanoe docker image (`felt/tippecanoe:latest`). **This is real friction for our Windows dev box.**

**Windows-specific mitigation:** commit a `tool/osm_pipeline/tippecanoe/README.md` documenting the WSL2 install path; the Dart CLI shells out to `wsl tippecanoe ...` when running on Windows. Planner should add this to the pipeline README as a prerequisite check.

**Alternative if tippecanoe friction proves fatal:** `planetiler` (JVM). It produces pmtiles directly, is single-jar deployment, matches Protomaps' own basemap authoring. But that reintroduces the JDK dependency we just declined for Stage A. Prefer sticking with tippecanoe.

**Rejected: pure-Dart pmtiles writer.** No mature package exists on pub.dev; the spec is not stable-target for a first-time Dart implementation under phase-scope time budget.

---

## 3. PMTiles schema decision

**Recommendation: Custom Trailblazer schema — subset of Protomaps v4 semantics, restricted to our 4 layers, mapped to our specific `kind` values.**

Options evaluated:

| Option | Fits 200 MB @ z=11? | MapLibre GL fidelity | Style rewrite complexity | Downstream cost |
|---|---|---|---|---|
| **Custom Trailblazer schema (subset of Protomaps v4)** | Yes — we drop everything not in the 4 required layers | Full | Low — 2 style JSONs, our own layer names | Owned |
| Full Protomaps v4 (buildings, landuse, landcover, pois, transit, boundaries, earth, places, roads, water) | Marginal — full Germany at z=11 with pois pushes toward 200 MB | Full | Low — reuse Protomaps' MapLibre style | Owned but bloated |
| Custom-off-brand schema (invent field names) | Yes | Full | Medium — bespoke | Ownership tax with no reuse benefit |

**Concrete schema:**

Four layers, all `min_zoom=0` unless noted:

- `roads` — LineStrings, fields: `kind` (motorway|trunk|primary|secondary|tertiary|minor|track|path), `name`, `ref`, `oneway` (bool). `kind` collapses `*_link` into the parent (motorway_link → motorway). `min_zoom` per feature per Protomaps convention: motorway z=5, trunk z=6, primary z=7, secondary z=9, tertiary z=10, minor z=11, track/path z=11.
- `admin_boundaries` — LineStrings for the boundary lines + Polygons for the region fills, fields: `admin_level` (2|4|6|8|9|10), `kind` ("country"|"state"|"county"|"municipality"|"district"|"suburb"), `name`. z=0 for 2/4; z=6 for 6; z=9 for 8/9/10.
- `water` — Polygons (lakes) + LineStrings (rivers), fields: `kind` ("lake"|"river"|"stream"), `name` (rivers z>=8). Filter by size at low zoom.
- `labels` — Points, fields: `kind` ("place_country"|"place_state"|"place_city"|"place_town"|"place_village"|"road_shield"), `name`, `ref` (for shields), `population` (for place ranking).

**Why the Protomaps v4 semantics (from https://docs.protomaps.com/basemaps/layers) matter:** their layer taxonomy and `kind` naming is a proven, MapLibre-tested vocabulary. Even though we're not shipping their tiles, using the same `kind` values makes it trivial for a future developer to lift a Protomaps sample style and adapt it. This is the "subset of Protomaps v4" choice from CONTEXT.

**Style JSON rewrite (per CONTEXT: "Rewrite Phase 2 style JSONs"):** `assets/map_style_light.json` and `assets/map_style_dark.json` are rewritten from scratch to point at our 4 layers with matching `source-layer` names. A single plan task.

**Rejected: full Protomaps v4.** Its buildings + pois layers alone would eat half the budget with zero coverage-experience benefit. We render "where the car drives on a base of admin + water + labels" — nothing else earns bytes.

---

## 4. Feldweg/Fußweg concrete tag set

**Recommendation:** Include only tracks/paths that are plausibly drivable. Concrete filter:

```
highway=track                                              → include (all)
highway=path        AND motor_vehicle IN (yes,permissive)  → include
highway=service     AND service IN (driveway,alley)        → include  (see §0.1)
highway=footway                                            → EXCLUDE (walking-only by definition in DE)
highway=cycleway                                           → EXCLUDE
highway=pedestrian                                         → EXCLUDE
highway=bridleway                                          → EXCLUDE
```

Feldweg/Fußweg rows are **stored** but tagged `is_counting=0` in `osm.sqlite`. They participate in matching so the user can see themselves driving on a Wirtschaftsweg painted in dashed style, but they do NOT count in Phase 8's coverage %.

**Rationale (backed by German OSM tagging convention, see https://wiki.openstreetmap.org/wiki/DE:Tag:highway%3Dtrack):**

- `highway=track` in DE is explicitly a *Wirtschaftsweg* — Feld/Wald/Wasserwirtschaft (agricultural/forestry/hydro). Driveable by tractor and, per DE-Landesrecht typically, by private car unless signed otherwise. Include unconditionally.
- `highway=path` is generic; DE convention adds `motor_vehicle=yes|permissive` when it's actually drivable. Filter accordingly. Bare `highway=path` with no motor_vehicle tag is treated as walking-only.
- `highway=footway`, `cycleway`, `pedestrian`, `bridleway` are semantically non-drivable in DE per the OSM wiki. Storing them would inflate the DB with zero legitimate driven-experience use.
- `highway=service` with `service=driveway|alley` catches the "driveable spur that is not a Wirtschaftsweg" case (petrol station, farm access). This is the only sliver of `highway=service` we readmit despite excluding the class from the Kfz set (see §0.1).

The set is intentionally small. The Feldweg feature is a "nice-to-see" line on the map, not a coverage metric — restraint here directly helps the 200 MB budget.

**Retained tags on Feldweg rows:** `highway`, `name`, `surface` (yes, we retain `surface` for Feldwegs only — the tracktype/surface visual distinction matters for Feldweg rendering even though we skipped it on Kfz ways per CONTEXT).

---

## 5. Directionality representation

**Recommendation: Option (c) — retain the raw `oneway` tag AND store a normalized `is_directional` boolean plus a `traversal_direction` enum on each way row.**

Full schema for the directionality columns on the `ways` table:

```
oneway_tag         TEXT     -- raw OSM value, verbatim: 'yes' | 'no' | '-1' | '' (null-string for missing)
is_directional     INTEGER  -- 0 or 1, derived
traversal_dir      INTEGER  -- 0 = bidirectional, 1 = forward-only along nodes, 2 = backward-only (reversed)
```

Derivation rules (locked in the pipeline, not left to matcher):

- `oneway=yes` → `is_directional=1, traversal_dir=1`
- `oneway=-1` → `is_directional=1, traversal_dir=2`  (nodes are reversed physically OR matcher reverses at query time — pick one; recommend: **physically reverse** node order in the geometry so `traversal_dir=1` is always the storage convention, and drop `traversal_dir=2` entirely)
- `oneway=no` OR missing on Kfz ways (motorway/trunk/primary auto-imply oneway=yes) → apply per-highway-class default:
  - `motorway`, `motorway_link`, `trunk_link` → `is_directional=1`  (OSM implicit-oneway rule)
  - all others → `is_directional=0`

**Revised recommendation after locking the physical-reversal choice:**

```
oneway_tag         TEXT     -- raw, kept for debugging
is_directional     INTEGER  -- 0 (both ways) or 1 (forward-only along stored node order)
```

Two columns is enough. Node order in the geometry always represents "forward direction of travel" for `is_directional=1` ways. `oneway=-1` ways are physically reversed at parse time.

**Why this over Option (a) raw-tag-only:** the matcher (Phase 5, `findWaysNear` p95 < 30 ms) does not want to string-parse `oneway` on every candidate. A pre-computed integer boolean is 10× cheaper.

**Why this over Option (b) precomputed directional segments:** doubles the row count of bidirectional ways for no downstream win — HMM emission probabilities handle bidirectional ways natively via forward/backward log-probs on the same edge.

---

## 6. Admin geometry storage

**Recommendation: Option (c) — polygons in BOTH `osm.sqlite` AND `germany-base.pmtiles`.**

Rationale:

- **pmtiles side** — needed for MapLibre GL to render the admin_boundaries layer on the map (fill + outline). Cannot be skipped; that's what the layer is for.
- **osm.sqlite side** — needed for two runtime operations that pmtiles cannot serve:
  1. Phase 8 focus-area pill: "given lat/lng, which Landkreis/Gemeinde am I in?" — this is a point-in-polygon lookup that the matcher does on every trip point (or coarsely, on a rolling window). Cannot use pmtiles for this because pmtiles is not a spatial query engine, only a tile serializer.
  2. `way_admin` join population (OSM-04, SC3): requires the actual polygon geometry available in Dart at pipeline-build time so the segmented-intersection algorithm (§7) can run. Once written we keep it — cheap re-use for runtime queries.

**Storage schema (osm.sqlite side):**

```sql
CREATE TABLE admin_regions (
  region_id      INTEGER PRIMARY KEY,   -- our sequential ID
  osm_relation_id INTEGER,              -- traceability
  admin_level    INTEGER NOT NULL,      -- 2|4|6|8|9|10
  name           TEXT NOT NULL,
  geometry_wkb   BLOB NOT NULL,         -- Multi-Polygon, WKB
  bbox_minlat    REAL, bbox_minlng REAL, bbox_maxlat REAL, bbox_maxlng REAL
);
CREATE INDEX idx_admin_level ON admin_regions(admin_level);

CREATE VIRTUAL TABLE admin_regions_rtree USING rtree(
  id, min_lat, max_lat, min_lng, max_lng
);
```

**Size budget check:** Germany admin polygons at all six levels, simplified to zoom 11 tolerance, encoded as WKB, historically compresses to ~20-30 MB. Within budget.

**Rejected: Option (a) polygons in osm.sqlite only** — needs a separate render pipeline to get outlines on the map. Redundant work.
**Rejected: Option (b) polygons in pmtiles only + slim metadata in DB** — leaves the pipeline stage's own segmented-intersection algorithm without geometry to intersect against. Would require re-reading pmtiles at pipeline time, which is absurd.

---

## 7. Segmented intersection algorithm

**Recommendation: iterative Sutherland-Hodgman variant against admin polygon boundaries, one Kfz way at a time, one admin level at a time. Implement pure-Dart on top of the pipeline's own vector-2 primitives — no `geometry` package dependency.**

Concrete algorithm per Kfz way per admin level (2, 4, 6, 8, 9, 10 — six passes):

```
for each way W:
  candidates = admin_regions_rtree.query(bbox(W))       # coarse filter
  for each admin_region R in candidates at this level:
    if geometry(R) intersects geometry(W):
      subsegments = clip_linestring_to_polygon(W, R)    # Weiler-Atherton or JTS-style
      for each subseg in subsegments:
        way_admin.insert(way_id=W.id, region_id=R.id, level=L, geom=subseg)
```

**Why pure-Dart over binding to a C++ library (like `libgeos` via FFI):**

- The intersection here is 1D-linestring against 2D-polygon boundary — a special case that is ~100 LOC in Dart. Full JTS/GEOS is overkill.
- FFI to GEOS on the Windows dev box means shipping/building a native DLL — same friction argument as osmium in §1.
- No pub.dev package exposes exactly this operation well; `dart_jts` is a partial JTS port but has stability question marks.

**Correctness pitfalls the algorithm must handle explicitly:**

- Way passes through a region and back out again → yields two separate `way_admin` rows for the same (way, region) pair. That's correct — coverage math sums per row, so a way that enters/exits/re-enters contributes its true length.
- Way lies exactly along an admin border → assign to the region on the left of the line (deterministic tie-break; document it).
- Way touches a region at a single vertex → epsilon-clip; ignore intersections shorter than 1 m.
- Multipolygon admin regions (islands, exclaves) → treat each outer ring independently, subtract inners.

**Expected row count for Germany:** ~40 M Kfz ways × ~1.3 average admin levels crossed = ~52 M `way_admin` rows. At ~40 B/row → 2 GB uncompressed. **This blows the 200 MB budget.**

**Mitigation:** the `way_admin` table stores `(way_id, region_id, level)` only — no geometry, no length. Length is computed from the way geometry on demand OR stored as a `length_m REAL` column if Phase 8 coverage math needs it. Segmented sub-linestring geometries do NOT get their own storage; the split points are reconstructible from way + region polygon at runtime (or precomputed once per way per level as `(start_node_idx, end_node_idx, fraction_start, fraction_end)` — 32 B per row, → 1.6 GB, still too big).

**Revised strategy: store `way_admin` as `(way_id, region_id_at_level_2, region_id_at_level_4, ..., region_id_at_level_10)`** — six admin-level columns per way, but ONLY when the way lies wholly in one region at that level. Cross-border ways get separate rows per sub-segment with `fraction_start/fraction_end` columns.

Expected row count under this scheme: ~40 M ways, ~95% wholly-contained → ~38 M single rows + ~2 M split rows × ~2 sub-segments = ~42 M rows × ~50 B → ~2.1 GB. **Still too big.**

**Final strategy (correct one):** `way_admin` stores only cross-border ways with per-sub-segment fractions. Wholly-contained ways carry their six `admin_region_id_L2/L4/L6/L8/L9/L10` **as columns on the `ways` table itself**. This is denormalization for size — the pattern OSMDB pipelines like planetiler use.

Row-count under the final scheme:
- `ways` table: ~40 M rows × (existing columns + 6 × INTEGER) = adds ~1 GB. Also too big.

**Deeper mitigation: aggressive Kfz way count reduction.** Full Germany has ~4 M drivable Kfz ways after our filter, NOT 40 M. (40 M is the total OSM node count; way count is 10× smaller.) At 4 M ways × ~50 B admin cols → 200 MB. Tight but plausible.

**Planner note:** the actual row count is an empirical question. Do NOT lock a schema before running the Berlin-bbox smoke and scaling. The plan should include an early "measure Berlin-bbox row count and extrapolate" task before committing schema. If the estimate blows 200 MB, drop admin level 9 and 10 columns (Stadtteil, Ortsteil) from `ways` and require a runtime spatial lookup for those two levels.

---

## 8. R-Tree over per-segment rows

**Recommendation: SQLite R*Tree virtual table (`CREATE VIRTUAL TABLE ways_rtree USING rtree_i32(...)`) indexed on per-segment 2-point-bbox rows.** One row per (way_id, segment_idx) pair.

Access pattern (Phase 5, `findWaysNear(lat, lng, radius)`):

```sql
SELECT way_id, segment_idx
FROM ways_rtree
WHERE min_lat <= :max_query_lat AND max_lat >= :min_query_lat
  AND min_lng <= :max_query_lng AND max_lng >= :min_query_lng;
```

**Granularity trade-off (per CONTEXT decision — R-Tree over per-segment rows, already accepted):**

- **Per-segment:** ~30 M segments for 4 M Kfz ways × ~7 nodes/way. Index size ~30 M × 40 B = 1.2 GB → **again over budget**.
- **Per-way:** ~4 M rows × 40 B = 160 MB. Tight fit but plausible.

**Planner action item:** measure both on Berlin bbox and extrapolate. If per-segment is genuinely too big, negotiate with the Phase 5 P5 SC2 `findWaysNear` p95 < 30 ms budget — a per-way R-Tree with 10 km autobahn bboxes will flood candidates, but rejection filtering in Dart is O(candidates) so a 100-candidate flood costs ~1 ms. Might survive.

**Recommendation:** default to per-segment. If Berlin extrapolation shows > 150 MB, downgrade to per-way + implement a two-stage query (R-Tree returns way candidates, in-Dart segment-level filter narrows).

**R-Tree module gotcha:** SQLite's rtree module uses REAL coordinates. For sub-metre precision at latitude 51°N, REAL is fine. Do NOT use `rtree_i32` with lat/lng scaled to integers — the scaling headache is not worth the marginal size savings.

---

## 9. Version stamp encoding

**Recommendation: split the stamp across two loci.**

**osm.sqlite side:**

```sql
PRAGMA user_version = <pipeline_schema_version>;   -- integer, bump on breaking schema change

CREATE TABLE metadata (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT INTO metadata VALUES
  ('pbf_date',                  '2026-06-15'),          -- ISO date extracted from PBF header
  ('pbf_source',                'germany-latest.osm.pbf'),
  ('pbf_sha256',                '<sha256 of source PBF>'),
  ('bbox',                      '5.87,47.27,15.04,55.06'),     -- minlng,minlat,maxlng,maxlat OR '*' for full
  ('pipeline_schema_version',   '1'),                          -- matches PRAGMA user_version
  ('pipeline_git_sha',          '<git rev at build time>'),
  ('generated_at',              '2026-07-05T14:32:18Z');       -- ISO 8601 UTC
```

**germany-base.pmtiles side:** PMTiles v3 has a first-class JSON metadata block written into the header. Populate it with the same keys plus:

```json
{
  "name": "trailblazer-germany-base",
  "version": "1",
  "pbf_date": "2026-06-15",
  "pipeline_schema_version": "1",
  "generated_at": "2026-07-05T14:32:18Z",
  "vector_layers": [ ... ]
}
```

**Why both:**

- Phase 5 integrity check (P5 SC1) reads `osm.sqlite` PRAGMA + metadata to reject a stale DB — one SQL statement, no external dependency.
- Phase 10 extract-swap logic reads the pmtiles metadata to compare the offered download's `pbf_date` to the installed one — pmtiles metadata is directly readable by the pmtiles client library the app already loads.
- The two must match — a plan task validates them at pipeline exit.

**Bumping the schema version:** `pipeline_schema_version` is bumped in `tool/osm_pipeline/lib/schema.dart` as a `const`. Bumping it triggers Phase 5's "you need to redownload" flow.

---

## 10. Memory-vs-streaming strategy

**Recommendation: hybrid — streaming PBF parse writes to on-disk scratch SQLite tables, then a second pass reads the scratch DB to author outputs.**

Concrete pipeline stages:

```
Stage A (streaming, RAM-bounded to ~1 GB):
  PBF blocks streamed → parse in isolate pool (Dart parallel workers, N = min(4, cpu_count))
  Nodes go to scratch table `nodes_raw(id, lat, lng)` — no tags stored (nodes-with-tags rare, handled separately)
  Ways with matching highway filter → `ways_raw(id, tags_json, node_ids_json)`
  Relations with admin boundary type → `relations_raw(id, tags_json, members_json)`

Stage B (in-memory per admin relation, RAM-bounded to ~500 MB):
  For each admin relation, materialize its member ways → build multipolygon → simplify → write to admin_regions_raw

Stage C (streaming from scratch DB):
  Walk ways_raw joined against nodes_raw → produce Kfz way geometries → run segmented-intersection against admin_regions_raw → write final osm.sqlite tables

Stage D (streaming):
  Re-walk final tables → emit per-layer GeoJSON files to disk → invoke tippecanoe subprocess

Stage E:
  Delete scratch DB, delete GeoJSON temp files.
```

**RAM budget:** hard cap 4 GB for the whole pipeline (matches consumer laptop dev box). If parsing full-Germany peaks over that, the Dart isolate pool size drops from 4 → 2 → 1.

**Scratch DB size for full Germany:** ~15 GB on disk (worst case). Requires SSD headroom check in the CLI pre-flight; abort with clear error if `df` shows < 30 GB free.

**Isolate boundary:** Stage A only. Stages B/C/D run on the main isolate. Isolates would help stage C (parallel segmented-intersection per admin level) but the sqlite writes serialize anyway; not worth the coordination complexity in v1.

**SQLite pragmas for scratch DB:**

```sql
PRAGMA journal_mode = OFF;    -- scratch dies on success, no crash safety needed
PRAGMA synchronous = OFF;
PRAGMA cache_size = -524288;  -- 512 MB page cache
PRAGMA temp_store = MEMORY;
PRAGMA page_size = 65536;
```

**SQLite pragmas for output `osm.sqlite`:**

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA page_size = 4096;      -- default; matcher read pattern is small random reads
```

Rationale for divergent pragmas: scratch is write-mostly and disposable; output is read-mostly and durable.

---

## 11. CI / reproducibility

**Recommendation:**

- Ship `tool/osm_pipeline/test/` with unit tests for the pure-Dart pieces: PBF block reader, highway filter, directionality normalization, segmented-intersection algorithm, way_admin schema layout. `flutter test tool/osm_pipeline` or a dedicated `dart test tool/osm_pipeline` runs them.
- **Do NOT commit a full PBF fixture.** Berlin-bbox extracted PBF is ~60 MB — too big for git. Commit a tiny hand-crafted fixture PBF (~1 KB) covering the algorithmic edge cases: one Kfz way crossing one admin boundary, one Feldweg, one multipolygon admin. Adapt the format from https://wiki.openstreetmap.org/wiki/PBF_Format.
- Berlin-bbox smoke test is a manual dev-only task — document in `tool/osm_pipeline/README.md` with expected wall-clock (~60 s target) and expected output sizes (osm.sqlite ~15 MB, pmtiles ~10 MB for Berlin).
- CI pipeline runs the unit tests + a Berlin-bbox integration test IF the Berlin PBF is available (env var pointer). No hard CI failure if PBF absent — allows CI to work without external asset dependency.
- Add a `tool/osm_pipeline/smoke.sh` (bash + PowerShell twin) that downloads Berlin PBF from Geofabrik if missing and runs the pipeline. One-command reproducibility for a new developer.

**Reproducibility contract:**

- Given the same input PBF, the pipeline produces byte-identical `osm.sqlite` (modulo the `generated_at` metadata row).
- Given the same input PBF, the pipeline produces `germany-base.pmtiles` with identical vector features but potentially non-identical tile-boundary geometry serialization (tippecanoe internal ordering is not fully deterministic). Metadata match is enough.

**Expected timings:**
- Berlin bbox: 30-60 s end-to-end
- Full Germany: 30-90 min end-to-end depending on machine (SSD assumed)

---

## 12. Known pitfalls

Concrete list for the planner to codify into per-task acceptance criteria:

1. **Admin multipolygon relations** — a Landkreis is a `type=multipolygon` relation with `outer` and `inner` member ways. Enclaves (Bremen, Berlin's Kladower Forst) require correct inner-ring subtraction. Test fixture must include one.
2. **Ways crossing tile boundaries** — tippecanoe handles clipping. But at feature emission time we must not artificially split a way across our own tile grid; emit whole ways and let tippecanoe clip.
3. **OSM coastline** — Germany's coastline is a `natural=coastline` collection of ways, not polygons. Our `water` layer polygons for the sea come from a separate coastline-processed dataset (Daylight / OSMCoastline) OR we skip sea rendering for v1. **Recommendation: skip sea rendering for v1.** Germany's inland lakes and rivers are enough. Add coastline via Natural Earth 10m in a deferred phase.
4. **Deleted-node references** — a way can reference a node ID whose node record was deleted in a later PBF diff but not garbage-collected. Pipeline sees a way member without a matching node row. Skip the way, log to `skipped.log`.
5. **Self-intersecting geometries** — admin multipolygons occasionally have coincident outer rings due to bad edits. Detect via ring orientation check; skip and log.
6. **Duplicate OSM way IDs across versioned data** — should not occur in a single PBF but occurs in historical dumps. Assert uniqueness at insert time; skip duplicates.
7. **`oneway=-1` reversal** — our decision to physically reverse node order (§5) means we must record the reversal in `skipped.log`? No — it's a legitimate transformation, not a skip. But we DO need to make sure the geometry's directional sense in the pmtiles output matches (for future one-way arrow rendering). Emit `direction=forward` verbatim after normalization.
8. **Non-Latin `name:*` tags** — Germany data has `name`, `name:de`, `name:en`, `name:pl`, etc. Retain only `name` (which is `name:de` by DE convention) in v1. Deferred for i18n.
9. **`highway=road`** — CONTEXT lists this in the Kfz allowlist. It means "highway of unknown classification" — usually a mapping-error placeholder. Include but log the count; if it's > 0.1% of Kfz ways for a given extract, prompt at pipeline exit ("consider fixing upstream").
10. **Berlin's admin_level=4 anomaly** — Berlin/Hamburg/Bremen are Bundesland *and* Gemeinde in one entity. Their admin_level=4 relation is also their level=6 municipality. Handle by writing them twice in `admin_regions` under both levels — do not deduplicate.

---

## Planner hand-off checklist

Before the planner locks the schema and task breakdown:

- [ ] Reconcile OSM-02 vs CONTEXT `service` in a first-plan task; update `REQUIREMENTS.md` and log in `STATE.md`. (See §0.1)
- [ ] Confirm tippecanoe availability on the dev box; if Windows-only, add WSL prereq task. (See §2)
- [ ] Plan a Berlin-bbox smoke as the *very first* end-to-end plan; use its measured row counts to validate the §7/§8 size budgets before locking schema.
- [ ] Emit the `pipeline_schema_version` constant in code from day 1; Phase 5 will read it.
- [ ] Every plan lists which OSM-0X requirement(s) it closes in the frontmatter, and success criteria map back to SC1–SC5 in ROADMAP.
- [ ] Include a task to rewrite `assets/map_style_light.json` and `assets/map_style_dark.json` — Phase 2 style JSONs will not render against the new schema without it.

## RESEARCH COMPLETE
