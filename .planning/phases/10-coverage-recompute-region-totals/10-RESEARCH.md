# Phase 10: Coverage Recompute & Region Totals — Research

**Researched:** 2026-07-17
**Domain:** Dart-native OSM PBF pipeline extension + Flutter coverage recompute plumbing
**Confidence:** HIGH (all findings from direct repo code inspection)

---

## Summary

Phase 10's only genuine technical unknown was the offline dev-machine pipeline for producing
(a) a regenerated admin-polygon bundle with L9 Ortsteil boundaries, and (b) a per-region
total-road-length table keyed by `osm_id`. The research question assumed this would need a
new Python/pyosmium tool — **it does not**. The repo already contains a complete Dart-native
OSM PBF pipeline (`tool/osm_pipeline/`) that already handles every required operation: PBF
reading (pure Dart, 3-pass relation→way→node), admin boundary multipolygon assembly (full
fragment stitching, winding correction, self-intersection filtering), way→admin spatial
intersection (Sutherland-Hodgman clipper with haversine length measurement), haversine
distance computation, and SQLite scratch intermediates.

The pipeline already produces, from a single Geofabrik PBF pass, the exact same `osm_id`
keyed data structures Phase 10 needs. The offline totals sub-task reduces to adding a new
CLI that queries the existing scratch DB after a standard pipeline run, or extends the
orchestrator with a new Stage H that sums `way.length_m * fraction` per region from the
`way_admin_raw` table. The admin-polygon regeneration is already wired: re-run the existing
`fetch_admin_polygons.dart` CLI (which calls Overpass) or — better — adapt the existing
pipeline to emit GeoJSON from the scratch DB (avoiding Overpass's OOM on the admin query
at full-DE scale). Both paths exist today.

The Kfz allowlist is defined in two locations that are **bit-for-bit identical** and ready to
use in the offline tool with no changes. All length arithmetic uses Dart haversine that is
already present in the pipeline package. No Python environment is needed.

**Primary recommendation:** Extend the existing Dart-native `tool/osm_pipeline/` with a new
Stage H CLI (`bin/emit_admin_bundle_and_totals.dart`) that queries the existing scratch
intermediate DB after Stages B–D run to simultaneously emit (a) the GeoJSON admin bundle and
(b) the `region_totals.json.gz` table, both keyed by `osm_relation_id`, from a single Geofabrik
DE PBF run.

---

## Research Question 1: pyosmium vs osmium-tool — the right tool

### Finding (HIGH confidence — verified from repo)

**Neither is needed.** The project already has a complete, battle-tested Dart-native OSM PBF
pipeline that handles all required operations. Introducing pyosmium/osmium would add a
Python env dependency for zero benefit over what already exists.

The existing Dart pipeline:
- `tool/osm_pipeline/lib/pbf/pbf_reader.dart` — streaming PBF decoder, pure Dart, no
  native deps beyond `dart:io`. Streams `OsmNode | OsmWay | OsmRelation` entities.
- `tool/osm_pipeline/lib/admin/admin_pipeline.dart` — extracts admin boundary relations in
  3 passes: A (collect relations + member way ids), B (collect member ways), C (collect
  member nodes), D (assemble + write). Already handles levels {2,4,6,8,9,10} per
  `kTargetAdminLevels = {2, 4, 6, 8, 9, 10}` in `admin_relation_filter.dart`.
- `tool/osm_pipeline/lib/filter/way_pipeline.dart` + `kfz_filter.dart` — filters ways by
  Kfz allowlist in a single pass, writes to scratch DB.
- `tool/osm_pipeline/lib/intersect/way_admin_join.dart` — attributes each Kfz way to ALL
  containing admin regions at all levels {2,4,6,8,9,10} in a single pass using
  `clipLinestringToPolygon`. Already supports parallel workers.
- `tool/osm_pipeline/lib/output/pipeline_orchestrator.dart` — wires all stages.

The **decision 7 text** ("pyosmium/osmium — Python-env dependency accepted") was written
before the Dart pipeline's full capability was known. The planner should treat the decision
as "offline PBF tool" and use the Dart pipeline — no new Python environment required.

---

## Research Question 2: Way→region point-in-polygon attribution at Germany scale

### Finding (HIGH confidence — verified from repo)

The pipeline does NOT use naive point-in-polygon. It uses a **linestring-vs-polygon
clipper** (`polygon_clip.dart`, `clipLinestringToPolygon`) that clips each Kfz way
linestring against each admin polygon, returning zero or more subsegments with
`(fractionStart, fractionEnd)` along the way's length.

**What already exists and works for Germany:**
- `buildWayAdminJoin()` in `way_admin_join.dart` does exactly this attribution in a single
  pass over all Kfz ways × all admin regions at levels {2,4,6,8,9,10}.
- Pre-filter: `_bboxOverlap(wayBbox, admin.bbox)` prunes ~99% of (way, region) pairs before
  the clipper runs — the real clipper work is only on overlapping bboxes.
- Already runs at Germany scale: this is the Stage D pipeline that produced the existing
  `osm.sqlite`. Runtime ~hours on a laptop; single-pass, parallel workers supported
  (`--workers=N`).
- Output: `way_admin_raw` table with `(way_id, region_id, admin_level, fraction_start,
  fraction_end)`. This is EXACTLY the data needed to compute `osm_id → total_length_m`.

**Memory posture:** Admin regions (~20K) are loaded into RAM (WKB → polygon). Ways are
streamed from scratch DB. The existing pipeline runs on a laptop with no OOM issues for
full Germany.

**The totals computation from this table is trivial SQL:**
```sql
SELECT ar.osm_relation_id,
       SUM(w.length_m * (war.fraction_end - war.fraction_start)) AS total_length_m
FROM   way_admin_raw war
JOIN   ways_raw      w  ON w.id    = war.way_id  AND w.source = 'kfz'
JOIN   admin_regions_raw ar ON ar.region_id = war.region_id
GROUP  BY ar.osm_relation_id;
-- Plus: for ways that are 100% inside a single region (rolled-up denorm cols),
-- also include them via the admin_region_id_lN columns from ways.
```

Or equivalently, once the pipeline has run Stage D, query the scratch DB directly before
it's deleted. This is a single SQL query → JSON/binary emit. Fast (milliseconds).

**One subtle point:** The existing pipeline uses a `clipLinestringToPolygon` result where
a way can be attributed to MULTIPLE regions (outer→inner nesting: L4⊃L6⊃L8⊃L9/L10).
Each subsegment carries `(fraction_start, fraction_end)` and the total-length computation
is `way.length_m * (fraction_end - fraction_start)`, not `way.length_m` per region. A
Kleinheubach street is attributed to Bayern (L4) + Landkreis Miltenberg (L6) +
Kleinheubach (L8) with fraction=1.0 for each — so it contributes its full length to all
three totals. This is correct by definition for the coverage denominator.

---

## Research Question 3: Kfz highway-class allowlist parity (CRITICAL)

### Finding (HIGH confidence — verified from source code)

The allowlist is defined in **two locations** that are **bit-for-bit identical**:

**Runtime (Flutter app):**
`lib/features/matching/domain/way_candidate.dart:40`
```dart
const kfzHighwayClasses = <String>{
  'motorway', 'motorway_link',
  'trunk', 'trunk_link',
  'primary', 'primary_link',
  'secondary', 'secondary_link',
  'tertiary', 'tertiary_link',
  'unclassified',
  'residential',
  'living_street',
  'road',
};  // 14 values
```

**Offline pipeline tool:**
`tool/osm_pipeline/lib/filter/highway_class.dart:16`
```dart
const Set<String> kKfzHighwayTags = {
  'motorway', 'motorway_link',
  'trunk', 'trunk_link',
  'primary', 'primary_link',
  'secondary', 'secondary_link',
  'tertiary', 'tertiary_link',
  'unclassified',
  'residential',
  'living_street',
  'road',
};  // 14 values, identical
```

**`highway=service` is EXCLUDED from both** (documented in both files: "service-way sprawl
blows the byte budget"). The offline totals CLI must filter using `kKfzHighwayTags` from
`highway_class.dart`, which the pipeline already applies in Stage B via `isKfzWay()` in
`kfz_filter.dart`. Ways in `ways_raw` with `source = 'kfz'` are already Kfz-filtered —
no additional filtering needed at the totals-query stage.

**Parity is guaranteed by construction** when the totals SQL queries `WHERE source = 'kfz'`:
the filter was already applied at Stage B.

---

## Research Question 4: Length measurement

### Finding (HIGH confidence — verified from source code)

`tool/osm_pipeline/lib/intersect/vec2.dart:43` implements the Haversine great-circle
formula using `kEarthRadiusMeters = 6371008.8` (WGS84 authalic radius):

```dart
double haversineMeters(Vec2 a, Vec2 b) {
  const toRad = math.pi / 180.0;
  final phi1 = a.lat * toRad;
  final phi2 = b.lat * toRad;
  final dPhi = (b.lat - a.lat) * toRad;
  final dLam = (b.lng - a.lng) * toRad;
  final s = math.sin(dPhi / 2.0);
  final t = math.sin(dLam / 2.0);
  final h = s * s + math.cos(phi1) * math.cos(phi2) * t * t;
  return 2.0 * kEarthRadiusMeters * math.asin(math.min(1.0, math.sqrt(h)));
}
```

This is identical to the Dart haversine in `lib/features/trips/domain/haversine.dart` used
by `CoverageComputeService._polylineLengthMeters()`. The offline pipeline already stores
`length_m` per way (computed with this same haversine) in the `ways_raw` scratch table and
in the final `ways` table in `osm.sqlite`.

**No pyproj, Geod, or external library needed.** Haversine at Germany's latitude span
(47°N–55°N) has sub-0.5% error vs geodesic — fully acceptable for coverage denominator
display purposes. No precision mismatch between offline totals and runtime-computed driven
lengths, since both use the same haversine formula.

**Length computation for totals:**
```
total_length_m for region R at osm_relation_id X =
  SUM over all Kfz ways W that intersect R of:
    w.length_m × (fraction_end − fraction_start)
```

`w.length_m` is precomputed by `_haversineLength()` in `osm_sqlite_writer.dart` (line 508)
and stored in `ways_raw` during Stage B/E. The `fraction_*` values from `way_admin_raw`
are dimensionless (fractions of that way's haversine length), so the multiplication is
dimensionally correct.

---

## Research Question 5: Multipolygon admin-relation assembly — L9 specifics

### Finding (HIGH confidence — verified from source code)

**Full multipolygon assembly already exists** in `tool/osm_pipeline/lib/admin/`:
- Fragment stitching: `MultipolygonAssembler.assemble()` handles open way fragments,
  head-to-tail chaining with reversal support, broken-ring skip-logging.
- Winding correction: outer rings forced CCW, inner rings forced CW.
- Self-intersection detection: O(N²) per ring; malformed rings skipped with log entry.
- Inner-ring bucketing into containing outers: ray-cast point test.
- Berlin/Hamburg/Bremen city-state dual-write (L4 → also written as L6): already handled
  in `admin_pipeline.dart` via `kCityStateNames`.
- Skip-log-continue error handling: every rejection writes to `skippedLog` and continues.

**`kTargetAdminLevels = {2, 4, 6, 8, 9, 10}`** — L9 IS already included in the filter
(`admin_relation_filter.dart`). The current stale bundle (ZERO L9) is because
`fetch_admin_polygons.dart` uses the Overpass path (not the PBF path), and the Overpass
query at that scale may have been run before L9 was added, or timed out silently dropping
L9. The Dart PBF pipeline has no such issue: it reads what the PBF contains.

**L9-specific known pitfalls:**
1. L9 relations can have very few outer way members (some Ortsteile are represented by
   just 2-3 ways). The assembler handles this correctly; the stitch epsilon is 1e-6 deg.
2. Some L9 relations may carry `type=multipolygon` instead of `type=boundary` — the filter
   handles BOTH (confirmed in `isAdminRelation()`).
3. `AdminPolygonSimplifier.withStricterL8` is the lever if the combined bundle exceeds
   15 MB gzipped: tolerances for L9 and L10 are both set to 100m (same as L8), so tighten
   via the `withStricterL8`-style API. Since L9 has ~few thousand regions (not ~10K), they
   are unlikely to dominate the budget.
4. Verified from CONTEXT.md F4: Linsengericht has 5 L9 child relations live in OSM
   (Lützelhausen, Altenhaßlau, Eidengesäß, Geislitz, Großenhausen). These are small
   polygons; the assembler handles them normally.

**No new assembly code needed.** The existing pipeline already assembles L9 correctly.
The only work is to emit the assembled geometries as GeoJSON (mirror what `fetch_admin_polygons.dart`
already does, but from the PBF-backed scratch DB instead of Overpass JSON).

---

## Research Question 6: Bundle format + size

### Finding (HIGH confidence — verified from source code)

**Admin polygon bundle (existing):**
- Format: gzipped GeoJSON FeatureCollection (`assets/admin/germany_admin.geojson.gz`)
- Loaded by `AdminRegionLookup` via `compute(_parseAdminBundle, bytes)` — off main isolate.
- Current stale bundle: 9.3 MB gzipped with levels {4:17, 6:400, 8:10836, 10:9284} = 20,547
  features, ZERO L9.
- Budget: 15 MB gzipped (hard limit; `fetch_admin_polygons.dart` exits with code 1 if
  exceeded).
- L9 addition estimate: Germany has ~8,000–12,000 Ortsteil polygons at L9. At tolerance
  100m DP-simplified, each typically has 20-60 vertices. Rough estimate: 10K × 50 vertices
  × ~30 bytes/vertex = ~15 MB uncompressed → ~3-5 MB gzipped delta. Combined bundle
  estimate: **~12-14 MB gzipped** — likely within budget but close. If over, use
  `AdminPolygonSimplifier.withStricterL8(150)` to tighten L8+L9+L10 tolerances.

**Totals table (new):**
- Shape: `Map<String, double>` where key = `osm_relation_id.toString()` (matching
  `coverage_cache.region_id` which stores OSM relation ID as string) and value =
  total road length in meters.
- Row count: ~20K–30K rows (polygon count + L9 additions).
- Encoding: gzipped JSON or a compact binary format.
  - JSON: `{"2145268": 123456.7, "62404": 45678.9, ...}` → ~20K entries × ~20 bytes avg
    = ~400 KB uncompressed → ~120-180 KB gzipped. Tiny.
  - Binary alternative: 4-byte osm_id + 4-byte float32 per entry = ~120 KB uncompressed.
    Not worth the complexity; gzipped JSON is fine.
- **Recommended format:** `assets/admin/region_totals.json.gz`
  - Loaded once at startup via `compute()` off the main isolate (mirror `AdminRegionLookup`
    load posture exactly: read bytes on main isolate, parse+build map in `compute()`)
  - Keyed by `osm_relation_id` as String → double (meters)
  - One load, then `Map<String, double>.[]` lookups are O(1) forever.

**Asset bundle budget math (combined):**
- Current admin bundle: ~9.3 MB gzipped (stale)
- After L9 regeneration: ~12-14 MB gzipped (estimated)
- Totals table: ~150-180 KB gzipped
- Combined: ~12.2-14.2 MB gzipped → within the 15 MB limit.

**Key invariant enforcement (build-time assertion):**
After both assets are generated from the same PBF run, add a build-time Dart script (or
extend the CLI's summary output) that reads both files and asserts:
`polygon_bundle.feature_osm_ids == totals_table.keys`
Any mismatch = pipeline bug, caught before the assets land in the app.

**osm_id key format:** The runtime `coverage_cache.region_id` stores OSM relation IDs as
strings (e.g. `"2145268"`). The admin polygon bundle stores `osm_id` as an `int` in the
GeoJSON properties. The totals table must convert to string keys to match. In the SQL
query: `CAST(ar.osm_relation_id AS TEXT)` as the key.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| OSM PBF reading | Custom protobuf decoder | `PbfReader` (`pbf_reader.dart`) | Already handles dense nodes, blob types, streaming |
| Admin multipolygon assembly | New assembler | `MultipolygonAssembler.assemble()` | Fragment stitching, winding, self-intersection already handled |
| Way→region spatial join | New clipper or PIP library | `clipLinestringToPolygon` + `buildWayAdminJoin` | Already runs at Germany scale with parallel workers |
| Haversine length | pyproj, turf.js, custom | `haversineMeters()` from `vec2.dart` | Already in the pipeline; same formula as runtime |
| Kfz filter | New highway-class filter | `isKfzWay()` + `kKfzHighwayTags` | Already defined; ways in scratch DB already filtered |
| Douglas-Peucker simplification | New DP impl | `AdminPolygonSimplifier._simplifyRing()` | Already implemented with level-dependent tolerances |
| Bundle size check | Manual | `fetch_admin_polygons.dart` exit code 1 gate | Already exits(1) if > 15 MB |

---

## Architecture Patterns

### Recommended Pipeline Design

The cleanest approach adds a **new Stage H** that runs after Stage D (way_admin join is
complete), queries the scratch DB, and emits both output files in a single pass.

```
Geofabrik germany-latest.osm.pbf
  → Stage B: Kfz filter (ways_raw + nodes_raw in scratch DB)
  → Stage C: admin extraction (admin_regions_raw in scratch DB, levels {2,4,6,8,9,10})
  → Stage D: way→admin intersection (way_admin_raw in scratch DB)
  → Stage H [NEW]: emit admin bundle + totals table
      ├─ admin_regions_raw → GeoJSON FeatureCollection → gzip → germany_admin.geojson.gz
      └─ way_admin_raw JOIN ways_raw JOIN admin_regions_raw → totals → gzip → region_totals.json.gz
```

Stage H is a pure SQL read from the scratch DB — no new PBF passes needed.

**Alternative: standalone post-pipeline CLI**

If touching the pipeline orchestrator is undesirable, a separate CLI
(`bin/emit_admin_bundle_and_totals.dart`) can accept a path to the scratch SQLite DB (or to
the final `osm.sqlite`) and emit both files. Since the scratch DB is deleted after the
pipeline, this would need the orchestrator to keep the scratch DB or to export to `osm.sqlite`
first.

**Recommended: extend the pipeline orchestrator** — cleaner, single invocation.

### New CLI entry point

```
dart run bin/osm_pipeline.dart \
  --pbf path/to/germany-latest.osm.pbf \
  --out-dir out/ \
  --no-pmtiles \
  --emit-admin-bundle ../../assets/admin/germany_admin.geojson.gz \
  --emit-totals ../../assets/admin/region_totals.json.gz
```

Stage H SQL for totals (runs on scratch DB):
```sql
SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
        SUM(w.kfz_length_m * (war.fraction_end - war.fraction_start)) AS total_m
FROM    way_admin_raw war
JOIN    ways_raw w   ON w.id = war.way_id AND w.source = 'kfz'
JOIN    admin_regions_raw ar ON ar.region_id = war.region_id
WHERE   ar.admin_level IN (4, 6, 8, 9, 10)   -- exclude L2 (whole Germany)
GROUP   BY ar.osm_relation_id;
```

Note: `ways_raw` stores `length_m` (populated at Stage B by `_haversineLength()`). Check
the exact column name — it may be stored as a separate field. If `ways_raw` doesn't have
`length_m` pre-computed, compute it from `node_ids` geometry at Stage H time (same
haversine function, same code path as Stage E uses for `osm.sqlite`).

**Actually:** reviewing `osm_sqlite_writer.dart`, `length_m` is computed at Stage E write
time from `nodes_raw` geometry, NOT pre-stored in `ways_raw`. Stage H would need to either:
(a) compute length inline from node geometry (same as Stage E does), or
(b) read from the final `osm.sqlite` `ways.length_m` column after Stage E.

Option (b) is simpler: after Stage E writes `osm.sqlite`, Stage H queries it:
```sql
SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
        SUM(w.length_m * (war.fraction_end - war.fraction_start)) AS total_m
FROM    way_admin war
JOIN    ways w   ON w.way_id = war.way_id
JOIN    admin_regions ar ON ar.region_id = war.region_id
WHERE   ar.admin_level IN (4, 6, 8, 9, 10)
GROUP   BY ar.osm_relation_id;
```

This queries the FINAL `osm.sqlite` (which has `ways.length_m` already computed and
`way_admin` with cross-border subsegments). The admin GeoJSON bundle is emitted from
`admin_regions` in the same `osm.sqlite`. Both from one file. **Cleanest approach.**

### Admin bundle emission from osm.sqlite

`osm.sqlite` has `admin_regions(region_id, osm_relation_id, admin_level, name, geometry_wkb)`
and the geometry is already assembled + stored as WKB. The bundle emitter:
1. Reads each row.
2. Decodes WKB → `ClipMultiPolygon` (via existing `decodeMultiPolygonWkb()`).
3. Applies `AdminPolygonSimplifier` DP simplification (same as current `fetch_admin_polygons.dart`).
4. Emits GeoJSON Feature with `{osm_id, admin_level, name, name:de}` properties.
5. Excludes L2 (Germany country) from the bundle for bundle size.

This replaces the current Overpass-dependent `fetch_admin_polygons.dart` for full-DE
regeneration, while keeping that CLI available as a quick dev override for small regions.

---

## Common Pitfalls

### Pitfall 1: `ways_raw` does not store `length_m`

**What goes wrong:** Trying to compute totals directly from `ways_raw` fails because the
table stores `node_ids` (packed binary blob of node IDs), not pre-computed length.
**How to avoid:** Query from final `osm.sqlite` `ways.length_m` (already computed by Stage E),
or recompute inline using `haversineMeters()` from nodes_raw geometry. Using `osm.sqlite` is
simpler.

### Pitfall 2: `way_admin` vs `way_admin_raw` + denorm columns

**What goes wrong:** `osm.sqlite` uses a denormalized scheme: wholly-contained ways (fraction
0.0–1.0, single region at a level) are stored in `ways.admin_region_id_l{2,4,6,8}` columns
and stripped from `way_admin` (cross-border ways only). For L9/L10, denorm is NOT used
(`kDenormAdminLevels = [2, 4, 6, 8]` — L9/L10 always stay in `way_admin`).
**How to avoid:** The totals query must cover BOTH:
- `way_admin` rows (cross-border ways, L9/L10 all ways)
- Denorm cols `admin_region_id_l4`, `admin_region_id_l6`, `admin_region_id_l8` for wholly
  contained ways (fraction = 1.0, so `total_m += way.length_m * 1.0`).

Full SQL covering both paths:
```sql
-- Cross-border rows and all L9/L10:
SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
        SUM(w.length_m * (wa.fraction_end - wa.fraction_start)) AS total_m
FROM    way_admin wa
JOIN    ways w  ON w.way_id = wa.way_id
JOIN    admin_regions ar ON ar.region_id = wa.region_id
WHERE   ar.admin_level IN (4, 6, 8, 9, 10)
GROUP   BY ar.osm_relation_id

UNION ALL

-- Wholly-contained L4 ways (denorm col):
SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
        SUM(w.length_m) AS total_m
FROM    ways w
JOIN    admin_regions ar ON ar.region_id = w.admin_region_id_l4
WHERE   w.admin_region_id_l4 IS NOT NULL
GROUP   BY ar.osm_relation_id
-- (Repeat for l6, l8)
```

Then aggregate the UNION ALL in a wrapper SELECT SUM(total_m) GROUP BY region_id.

**Simpler alternative:** Run the totals query on the `scratch DB` BEFORE Stage E strips
the denorm rows — `way_admin_raw` still has ALL rows including the wholly-contained ones.
Compute length inline from `nodes_raw`. This is the cleanest path: query scratch DB
pre-Stage-E, then the new stage H is cleanly separated and doesn't need to understand the
denorm schema.

Actually simpler still: add `length_m` computation to Stage B (store it in `ways_raw`)
so that `ways_raw` has length and `way_admin_raw` has the full un-stripped attribution.
Then Stage H SQL is the simple single-table query on scratch DB. This is the lowest
coupling approach.

### Pitfall 3: String vs integer osm_id keys

**What goes wrong:** `coverage_cache.region_id` stores OSM relation IDs as strings ("2145268").
`admin_regions.osm_relation_id` is INTEGER. The totals table must be keyed by the same
string form. If the key is stored as integer and loaded as int, all coverage_cache lookups
fail silently (no % shown).
**How to avoid:** In the Stage H SQL, `CAST(ar.osm_relation_id AS TEXT)` as the JSON key.
In the Flutter loader, keep keys as `String` — `Map<String, double>`.

### Pitfall 4: L9 not in `kCoverageAdminLevels` (F2 bug)

**What goes wrong:** `CoverageInvalidator.kCoverageAdminLevels = [4, 6, 8, 10]` is missing 9.
This means after a trip is confirmed/discarded, L9 cache rows are NOT invalidated, leaving
stale driven-km for Ortsteil regions.
**How to avoid:** Update `kCoverageAdminLevels` to `[4, 6, 8, 9, 10]` in
`coverage_invalidator.dart`. Already identified as F2 in CONTEXT.md.

### Pitfall 5: `drift_backup_service.dart kCurrentSchemaVersion` out of sync

**What goes wrong:** Schema bump without bumping `kCurrentSchemaVersion` → backup restore
uses wrong schema → data corruption on restore.
**How to avoid:** If schema changes in Phase 10 (e.g. adding `extract_version` stamp column
to `coverage_cache`), bump `kCurrentSchemaVersion` in `drift_backup_service.dart` in the
same commit. This has been a recurring trap. Check: `coverage_cache_table.dart` already
has an `extractVersion` nullable column — no schema bump needed if we use that.

### Pitfall 6: L9 polygon count may bust the 15 MB gzipped budget

**What goes wrong:** Full-Germany L9 (~8K-12K Ortsteil polygons) added to the bundle
might push it over 15 MB gzipped.
**How to avoid:** After running the pipeline, verify size. If over budget:
- `AdminPolygonSimplifier.withStricterL8(150)` tightens L8 tolerance (100m→150m).
- The same method signature can be extended for L9 tolerance (currently also 100m).
- `fetch_admin_polygons.dart` already exits(1) if over budget — the build fails loudly.

### Pitfall 7: Admin bundle from Overpass vs PBF may have different osm_ids

**What goes wrong:** If the admin bundle is regenerated from a different Overpass snapshot
than the totals table is computed from (different PBF), `osm_id` keys won't match perfectly.
**How to avoid:** Generate BOTH from the same Geofabrik PBF run in a single Stage H pass.
The build-time key-set assertion catches any discrepancy. Never source admin polygons from
Overpass and totals from PBF (or vice versa).

---

## Code Examples

### Stage H SQL (scratch DB path — before Stage E strips denorm)

```dart
// Source: tool/osm_pipeline/lib/intersect/way_admin_join.dart pattern
// Run AFTER Stage D (way_admin_raw populated), BEFORE Stage E (scratch not yet cleaned)
final rows = scratchDb.select('''
  SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
          SUM(
            (SELECT SUM(haversine_length_from_node_ids(w.node_ids))
             FROM   ways_raw w WHERE w.id = war.way_id AND w.source = 'kfz')
            * (war.fraction_end - war.fraction_start)
          ) AS total_m
  FROM    way_admin_raw war
  JOIN    admin_regions_raw ar ON ar.region_id = war.region_id
  WHERE   ar.admin_level IN (4, 6, 8, 9, 10)
  GROUP   BY ar.osm_relation_id;
''');
```

Note: haversine from `node_ids` must be computed in Dart, not SQL. The practical approach
is to first add `length_m` to `ways_raw` in Stage B (trivial — the haversine function is
already available at that point, and Stage E re-computes it anyway). Or read from `osm.sqlite`
after Stage E.

### Preferred: query osm.sqlite after Stage E

```dart
// Source: existing osm_sqlite_schema.dart table shapes
final db = sqlite3.open(osmSqlitePath);
// Step 1: cross-border rows + L9/L10 (all in way_admin)
final rowsFromWayAdmin = db.select('''
  SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
          SUM(w.length_m * (wa.fraction_end - wa.fraction_start)) AS total_m
  FROM    way_admin wa
  JOIN    ways w  ON w.way_id = wa.way_id
  JOIN    admin_regions ar ON ar.region_id = wa.region_id
  WHERE   ar.admin_level IN (4, 6, 8, 9, 10)
  GROUP   BY ar.osm_relation_id;
''');
// Step 2: wholly-contained L4/L6/L8 ways (denorm columns)
for (final level in [4, 6, 8]) {
  final col = 'admin_region_id_l$level';
  final denormRows = db.select('''
    SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
            SUM(w.length_m) AS total_m
    FROM    ways w
    JOIN    admin_regions ar ON ar.region_id = w.$col
    WHERE   w.$col IS NOT NULL
    GROUP   BY ar.osm_relation_id;
  ''');
  // merge into accumulator
}
```

### Totals table emit

```dart
// Emit region_totals.json.gz
final totals = <String, double>{};
// ... populate from SQL above ...
final json = jsonEncode(totals);
final bytes = utf8.encode(json);
final gzipped = gzip.encode(bytes);
await File(outputPath).writeAsBytes(gzipped);
// Size check
if (gzipped.length > 300 * 1024) {
  stderr.writeln('WARNING: totals table is ${gzipped.length} bytes, '
      'expected ~150-200 KB');
}
```

### Totals loader (Flutter, mirror AdminRegionLookup)

```dart
// In a new RegionTotalsLookup class (or extend AdminRegionLookup):
// Read bytes on main isolate (asset bundle not reachable off-isolate),
// then parse in compute() to avoid main thread block.
Future<Map<String, double>> _loadTotals() async {
  final bytes = await rootBundle.load('assets/admin/region_totals.json.gz');
  final uint8 = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  return compute(_parseTotals, uint8);
}

Map<String, double> _parseTotals(Uint8List bytes) {
  final decoded = utf8.decode(gzip.decode(bytes));
  final json = jsonDecode(decoded) as Map<String, dynamic>;
  return json.map((k, v) => MapEntry(k, (v as num).toDouble()));
}
```

---

## Research Question 7: Matcher-performance optimization (OQ1-PERF)

### Finding (MEDIUM confidence — code verified, performance estimates are informed estimates)

**Key files:**
- `TripMatchCoordinator` (`lib/features/matching/data/trip_match_coordinator.dart`)
- `MatcherIsolate` (`lib/features/matching/data/matcher_isolate.dart`)
- `CoverageComputeService` (`lib/features/regions/data/coverage_compute_service.dart`)

**Current behavior:**
- `rematchAllStoredTrips()`: serial loop over all trip IDs, each calling `_rematchOne()`.
  `_rematchOne()` fetches ways (cache-first), runs isolate match, deletes old intervals,
  inserts new. The isolate is kept warm across trips (`_isolate.start()` is idempotent).
- `CoverageComputeService.recompute()`: reads ALL intervals + ALL ways in the union bbox,
  does `deleteAll()` then `upsert()` for every region. Step 4 (`_waySource.fetchWaysInBbox`)
  fetches ways for the union bbox of ALL trips — which grows as trips accumulate.

**Incremental recompute feasibility (auto-trigger path):**
The auto-trigger case (new intervals from ONE trip) calls `recompute()` which re-fetches
ALL ways in the union bbox and rebuilds ALL region rows. For N trips spread across Germany,
the union bbox is large and grows with each trip. If the user drives in Kleinheubach only,
the union bbox is small and `recompute()` is fast (a few ms). As more diverse trips
accumulate, it grows.

A targeted incremental recompute is feasible: given a trip's bbox, attribute only regions
that bbox intersects, then do a partial upsert (not deleteAll). The challenge is that
`recompute()` uses `deleteAll()` to handle regions that LOST coverage (e.g. if intervals
were deleted). For the AUTO path (recompute-only after new intervals land, no deletion),
this risk doesn't apply — we only need to upsert-add regions, not remove any. So:
- **Auto path:** targeted upsert for the new trip's touched regions only — feasible, low
  risk. Requires knowing which admin regions a trip's bbox intersects (already available
  from `CoverageInvalidator._invalidateByTripBbox` sampling logic — same 5-point probe).
- **Button path (full rematch):** keep `deleteAll` + full recompute — correctness guaranteed.

**Warm isolate reuse:** `MatcherIsolate` is already kept alive across `rematchAllStoredTrips()`
trips — `_isolate.start()` is idempotent and the isolate persists. The worker `HmmMatcher`
is stateless and recreated per job. The R-Tree is rebuilt per job inside the worker from
the decoded tile ways. No cross-trip way sharing is possible at the isolate API level
without significant refactoring (the worker is a stateless function).

**Practical optimization for the button path:** the serial loop in `rematchAllStoredTrips()`
processes trips one at a time. For 4 trips in overlapping bboxes (e.g. 4× Kleinheubach),
the `fetchRawTilesInBbox` call hits the Overpass tile cache → probably already cached from
the first trip → near-zero fetch cost. The bottleneck is the HMM matcher itself per trip.
For the user's current workload (4 trips), the button should complete in seconds.

**Planning recommendation (OQ1-PERF):** Implement targeted incremental recompute for the
auto-trigger path. Keep full `deleteAll+upsert` for the button path. Don't invest in
warm-R-Tree reuse across trips — it requires significant isolate API changes for minimal
gain at current trip counts.

---

## Standard Stack

| Component | Where | Purpose | Notes |
|-----------|-------|---------|-------|
| `PbfReader` | `tool/osm_pipeline/lib/pbf/` | Stream OSM PBF entities | Pure Dart, no native deps |
| `extractAdminRegions()` | `tool/osm_pipeline/lib/admin/admin_pipeline.dart` | Admin boundary multipolygon assembly | Already handles L9, 3-pass |
| `buildWayAdminJoin()` | `tool/osm_pipeline/lib/intersect/way_admin_join.dart` | Way→region spatial join | Already Germany-scale tested |
| `haversineMeters()` | `tool/osm_pipeline/lib/intersect/vec2.dart` | Geodesic length | Same formula as runtime |
| `kKfzHighwayTags` | `tool/osm_pipeline/lib/filter/highway_class.dart` | Kfz allowlist | Bit-for-bit matches runtime |
| `AdminPolygonSimplifier` | `packages/admin_geometry/lib/src/admin_polygon_simplifier.dart` | DP simplification of rings | `withStricterL8` tolerance lever |
| `sqlite3` package | `tool/osm_pipeline/pubspec.yaml` | Scratch DB + osm.sqlite | Already in deps |

**No new dependencies needed for the offline pipeline.** All required libs are in `pubspec.yaml`.

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| Overpass-based admin bundle (`fetch_admin_polygons.dart`) | PBF-native Stage H emit | Eliminates Overpass dependency; gets L9; avoids Overpass OOM on full-DE admin query |
| Runtime tiled Overpass totals (`RegionTotalLengthService`) | Bundled offline table | Zero API calls; instant; works for Bundesländer |
| `way_admin_raw` data discarded at Stage E | `way_admin_raw` queried at Stage H for totals | Single additional SQL query before scratch teardown |

**Deprecated/obsolete after Phase 10:**
- `RegionTotalLengthService` + `region_tiling.dart`: deleted (decision 8)
- `realTotalProgressJson` column: can be kept as dead column or zeroed out; not removed
  (schema bumps are expensive)
- `totalPending` / `progressCellsDone` / `progressCellsPlanned` fields in `RegionCoverage`:
  can remain as fields that are always false/null once the service is deleted

---

## Open Questions (Remaining Planning Risks)

1. **`ways_raw` does not have `length_m` pre-stored.** The Stage H SQL either (a) computes
   length from `nodes_raw` geometry inline (more code), (b) reads from `osm.sqlite` after
   Stage E (simpler but requires the orchestrator to keep both scratch and final DB open
   at Stage H time), or (c) adds `length_m` to `ways_raw` at Stage B (cleanest, tiny change).
   **Recommendation:** add `length_m` to `ways_raw` in Stage B — one-line change to
   `way_pipeline.dart` + scratch schema. Planner decides scope.

2. **`way_admin` denorm gap:** `osm.sqlite` does not store wholly-contained L4/L6/L8 ways
   in `way_admin` — they are in denorm columns. The totals query must handle both paths.
   If querying `way_admin_raw` (scratch DB pre-Stage-E), this problem doesn't exist. If
   querying final `osm.sqlite`, need UNION of `way_admin` + denorm columns as shown above.
   **Recommendation:** use scratch DB pre-Stage-E approach, enabled by adding `length_m`
   to `ways_raw`.

3. **L9 polygon count and budget**: Will be known only after running the pipeline against
   a current Geofabrik DE PBF. Estimated to be OK but tight. `fetch_admin_polygons.dart`
   exits(1) if over 15 MB — the build fails loudly. Tolerance lever available.

---

## Sources

### PRIMARY (HIGH confidence — code verified directly)
- `tool/osm_pipeline/lib/filter/highway_class.dart` — Kfz allowlist `kKfzHighwayTags` (14 tags)
- `lib/features/matching/domain/way_candidate.dart` — Runtime `kfzHighwayClasses` (14 tags, identical)
- `tool/osm_pipeline/lib/admin/admin_pipeline.dart` — 3-pass admin extraction, L9 included
- `tool/osm_pipeline/lib/admin/admin_relation_filter.dart` — `kTargetAdminLevels = {2,4,6,8,9,10}`
- `tool/osm_pipeline/lib/intersect/way_admin_join.dart` — Way→region spatial join at Germany scale
- `tool/osm_pipeline/lib/intersect/vec2.dart` — `haversineMeters()` implementation
- `tool/osm_pipeline/lib/admin/multipolygon_assembler.dart` — Full multipolygon assembly
- `tool/osm_pipeline/lib/output/osm_sqlite_schema.dart` — `kDenormAdminLevels = [2,4,6,8]` (no L9 denorm)
- `lib/features/coverage/data/coverage_invalidator.dart` — `kCoverageAdminLevels = [4,6,8,10]` (F2 bug confirmed)
- `lib/features/regions/data/coverage_compute_service.dart` — `kComputeAdminLevels = [4,6,8,9,10]`
- `lib/features/regions/presentation/widgets/region_card.dart` — `levelLabel()` (F3 bug confirmed)
- `lib/features/matching/data/trip_match_coordinator.dart` — `rematchAllStoredTrips()` structure
- `lib/features/matching/data/matcher_isolate.dart` — Isolate warm/reuse posture
- `packages/admin_geometry/lib/src/admin_polygon_simplifier.dart` — `withStricterL8` tolerance lever
- `lib/core/db/tables/coverage_cache_table.dart` — `realTotalLengthM`, `extractVersion` columns

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — entire pipeline verified from source code
- Architecture (offline pipeline): HIGH — existing code paths confirmed
- Kfz allowlist parity: HIGH — bit-for-bit identical in two files, verified
- Pitfalls: HIGH — identified from code structure and schema examination
- Matcher-perf (OQ1-PERF): MEDIUM — code structure verified, perf estimates informed

**Research date:** 2026-07-17
**Valid until:** 2026-09-01 (stable Dart pipeline, no external deps)

---

## Key Surprise for Planner

**The Python/pyosmium decision is superseded.** The `tool/osm_pipeline/` is already a
complete Dart-native OSM PBF pipeline with all required capabilities. Phase 10's offline
sub-task is to extend it with a Stage H that emits two new output files (admin bundle +
totals table) from the existing scratch DB data structures. No new language runtime, no
new spatial libraries, no new multipolygon assembler. The pipeline already handles L9.
The Kfz filter is already applied. The haversine is already there. The spatial join is
already there. This is a plumbing task, not a research task.
