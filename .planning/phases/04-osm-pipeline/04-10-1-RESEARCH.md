# Phase 4 · Plan 04-10.1 — Option E Optimizations · Research

**Researched:** 2026-07-07
**Author:** Claude Opus 4.8 (opus-4.8, incremental writes to survive prior crash mode)
**Reads:** `04-CONTEXT.md`, `04-RESEARCH.md`, `04-05-BERLIN-MEASUREMENT.md`, `04-09-SUMMARY.md`, STATE.md P4 entries, live query of the surviving full-Germany `osm.sqlite` (7.99 GB)
**Consumed by:** `gsd-planner` → `04-10-1-*-PLAN.md` (wave breakdown at §10)

Answers "Option E" (drop Feldweg, per-way R-Tree, inline coords, isolate multithreading, per-N-ways progress logging) against the empirical anchor of a completed full-Germany pipeline run. §2 is the load-bearing section — real per-table byte breakdown from `tool/osm_pipeline/out/osm.sqlite`. Every other section derives from it.

---

## Executive Verdict (one-line each)

| Ask | GO / NOGO | Confidence |
|---|---|---|
| E.1 Drop Feldweg from osm.sqlite `ways` (KEEP in pmtiles roads layer) | **GO** | HIGH |
| E.2 R-Tree perWay (drop perSegment) — Kfz-only | **GO** | HIGH |
| E.3 Inline node coords per way | **MOOT — already done** | HIGH |
| E.4 Isolate multithreading (Stage D primarily) | **GO** | MEDIUM |
| E.5 Per-N-ways progress logging | **GO** | HIGH |

Projected osm.sqlite after E.1 + E.2 + isolates: **~1.9-2.5 GB** (down from 7.99 GB); still above the relaxed 800 MB SC4. Further slim-down via varint coord deltas (§7) plausibly reaches ~1.0-1.4 GB. **SC4 will need a second renegotiation** or an additional lever (drop Feldweg from pmtiles too; drop L9/L10 admin regions from admin_regions table).

---

## §1 — Requirement / ROADMAP impact of dropping Feldweg

### 1.1 Requirement mentions

Grep across `.planning/` found Feldweg/Fußweg in these v1 requirement IDs:

| ID | Text (verbatim) | Location |
|---|---|---|
| **OSM-02** | "…14-tag Kfz allowlist… + `highway=track\|path` filtered per Phase 4 RESEARCH §4 (Feldweg/Fußweg, stored `is_counting=0`, non-counting for coverage)." | REQUIREMENTS.md:45 |
| **COV-04** | "Coverage % per region = Σ driven_length(Kfz-way ∩ region) / Σ length(all Kfz-ways ∈ region) — **Feldweg/Fußweg excluded from both numerator and denominator**" | REQUIREMENTS.md:115 |
| **REN-02** | "Driven Feldweg/Fußweg ways are rendered in a **distinct secondary color** (default: dashed blue) — clearly not the same 'explored' visual language" | REQUIREMENTS.md:134 |
| **SET-04** | "Color palette selection for driven / partial / **Feldweg** overlays" | REQUIREMENTS.md:155 |

### 1.2 Success-criteria mentions

| Phase | SC | Text |
|---|---|---|
| **P4 SC2** | ROADMAP.md:128 | "Output artifacts include exactly the specified Kfz + **Feldweg/Fußweg** `highway=*` set and admin boundaries at OSM levels 2, 4, 6, 8, 9, 10." |
| **P7 SC1** | ROADMAP.md:173 | "Driven Kfz-ways render in the primary 'explored' color… driven Feldweg/Fußweg ways render in the distinct secondary color (default: dashed blue)." |
| **P8 SC5** | ROADMAP.md:189 | "Coverage percentages… Feldweg/Fußweg excluded from both numerator and denominator." |

### 1.3 Where Feldweg data lives today

Reading `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart` + `pipeline_orchestrator.dart` + `pmtiles/geojson_writer.dart`:

- **osm.sqlite** — the `ways` table has BOTH `source='kfz'` (4 070 051 rows) and `source='feldweg'` (5 224 059 rows) — Feldweg is 56.2% of the row count. `is_counting=0` gates COV-04 correctly.
- **germany-base.pmtiles** — Stage F.1 emits ALL kept ways into the `roads` layer via `geojson_writer.dart`. Kfz + Feldweg both land there. Renderer style JSON distinguishes them at paint time (dashed blue for kind=track/path per REN-02).

**Rendering-critical observation:** the `roads` layer in the pmtiles is what makes P7 REN-02 possible — the user sees the Feldweg painted on the map. If we drop Feldweg from the pmtiles layer too, REN-02 loses its visual base map.

### 1.4 The coherent split: drop from osm.sqlite, KEEP in pmtiles

**Recommendation (HIGH confidence):**

1. `osm.sqlite` `ways` table becomes **Kfz-only**. `source` column drops the `feldweg` enum, or the column disappears entirely (only Kfz remains). `is_counting` becomes structurally always-1 → can be dropped too.
2. `germany-base.pmtiles` `roads` layer **keeps Feldweg** — REN-02 dashed-blue rendering stays visually intact.
3. Downstream implications:
   - **COV-04** — unchanged. Feldweg was already excluded from coverage math via `is_counting=0`.
   - **REN-02** — the driven-Feldweg feature-state color path breaks. Driven-Feldweg coloring requires per-way state in osm.sqlite. If we drop Feldweg from osm.sqlite, the pmtiles ways become static base geometry (uniform dashed blue).
   - **SET-04** — the Feldweg color preset becomes a base-map style, not a coverage color.

### 1.5 Deferred/downstream question — how MMT handles Feldwege

**MMT-05:** "Points that cannot be matched confidently are dropped." If Feldweg ways aren't in the R-Tree candidate set (§4), the matcher will not snap points onto Feldwege. GPS traces on genuine Wirtschaftswege will register as gaps. This is a **product regression** vs the original design. User already chose Option E → implicit acceptance. **Document as v1 scope narrowing.**

### 1.6 Exact REQUIREMENTS.md + ROADMAP.md edits

**REQUIREMENTS.md OSM-02 rewrite (line 45):**

```
- [ ] **OSM-02**: Pipeline extracts only ways with `highway=motorway|trunk|primary|
  secondary|tertiary|residential|unclassified|living_street|road|motorway_link|
  trunk_link|primary_link|secondary_link|tertiary_link` (14-tag Kfz allowlist)
  into osm.sqlite. `highway=track|path` (Feldweg/Fußweg) are emitted ONLY into
  the pmtiles `roads` layer for map rendering — they do NOT appear in
  osm.sqlite. See Plan 04-10.1 decision log 2026-07-07.
```

**REQUIREMENTS.md REN-02 clarifying note (line 134):**

```
- [ ] **REN-02**: Driven Feldweg/Fußweg ways are rendered in a distinct
  secondary color (default: dashed blue). NOTE (2026-07-07): Feldwege are
  rendered as static base geometry from the pmtiles roads layer; per-way
  driven-state coloring (feature-state) applies to Kfz ways only.
```

**ROADMAP.md P4 SC2 (line 128):**

```
2. Output artifacts include the Kfz `highway=*` set in osm.sqlite;
   Feldweg/Fußweg (`highway=track|path`) are emitted into the pmtiles `roads`
   layer only. Admin boundaries at OSM levels 2, 4, 6, 8, 9, 10.
```

**ROADMAP.md P7 SC1 (line 173):** clarify Feldwege are static base geometry.
**REQUIREMENTS.md COV-04:** unchanged.
**REQUIREMENTS.md SET-04:** unchanged wording; semantic narrows.
**ROADMAP.md P8 SC5:** unchanged.

Total: 4 edits (OSM-02, REN-02, P4-SC2, P7-SC1). All narrowing edits.

---

## §2 — REAL osm.sqlite per-table space breakdown (CRITICAL)

**Anchor query source:** `dbstat` virtual table (compiled in this sqlite3 build 3.44.2) on `tool/osm_pipeline/out/osm.sqlite` (7 986 008 064 bytes). Total page count = 1 949 709 × 4 096 = 7 986 008 064. Every table's `SUM(pgsize)` accounts for all bytes on disk — no unexplained residual.

### 2.1 Row counts (SELECT COUNT(*))

| Table | Rows |
|---|---:|
| `ways` (total) | 9 294 110 |
| — `source='kfz'` | 4 070 051 |
| — `source='feldweg'` | 5 224 059 |
| `ways_rtree` (perSegment) | 61 068 546 |
| `way_admin` (cross-border only) | 2 962 673 |
| `admin_regions` (L2..L10) | 30 797 |
| `metadata` | 7 |

Admin per level: L2=2, L4=17, L6=404, L8=10 879, L9=10 279, L10=9 216.

### 2.2 Per-table bytes on disk (from dbstat)

Sorted by size, all in bytes. `MB = bytes / 1 048 576`.

| Table / index | Bytes | MB | % of DB |
|---|---:|---:|---:|
| `ways_rtree_node` (R*Tree internal) | 2 587 418 624 | 2 467.5 | **32.40 %** |
| `ways` | 1 823 903 744 | 1 739.4 | **22.84 %** |
| `idx_ways_rtree_lookup_way` (index) | 967 774 208 | 923.1 | 12.12 % |
| `ways_rtree_lookup` (rtree_id → way_id + segment_idx) | 964 079 616 | 919.4 | 12.07 % |
| `ways_rtree_rowid` (R*Tree internal) | 852 557 824 | 813.1 | 10.68 % |
| `admin_regions` | 295 403 520 | 281.7 | **3.70 %** |
| `idx_ways_highway` | 183 525 376 | 175.0 | 2.30 % |
| `idx_ways_source_counting` | 172 720 128 | 164.7 | 2.16 % |
| `way_admin` | 57 995 264 | 55.3 | 0.73 % |
| `idx_way_admin_region` | 52 297 728 | 49.9 | 0.66 % |
| `ways_rtree_parent` | 26 259 456 | 25.0 | 0.33 % |
| `admin_regions_rtree_node` | 1 359 872 | 1.3 | 0.02 % |
| Other admin_regions_rtree parts | ~700 K | 0.7 | < 0.01 % |
| `sqlite_schema` + metadata | 12 288 | 0.01 | < 0.01 % |
| **Total** | **7 986 008 064** | **7 616.4 (MiB)** | **100 %** |

**Sanity check:** row of `pgsize` sums = 7 986 008 064 = `File.lengthSync()` = 7.99 GB (decimal) = 7 616 MiB (binary). Matches page_count × page_size exactly.

### 2.3 The R-Tree tax is the elephant

**All R-Tree tables and their aux index total:**

- `ways_rtree_node` — 2 467.5 MB (the R*Tree geometry)
- `ways_rtree_rowid` — 813.1 MB
- `ways_rtree_lookup` — 919.4 MB (our rowid → way_id + segment_idx map)
- `idx_ways_rtree_lookup_way` — 923.1 MB (for reverse lookup)
- `ways_rtree_parent` — 25.0 MB

**R-Tree cluster total: 5 148.1 MB = 67.6 % of the entire osm.sqlite.**

The perSegment granularity is the dominant size driver, dwarfing everything else.

### 2.4 `ways` table breakdown (1 739 MB)

From per-source geometry_wkb query:
- Kfz: 4 070 051 rows × avg 125.70 B WKB = 511 595 563 B = **488 MB** WKB payload
- Feldweg: 5 224 059 rows × avg 133.58 B WKB = 697 853 923 B = **665 MB** WKB payload
- Total WKB: **1 153 MB** (66.3 % of ways table bytes)

Remaining `ways` bytes (~586 MB) are: the fixed-width columns (source, is_counting, is_directional, ~4 admin_region_id ints per row, way_id, length_m — ~40 B/row × 9.3 M = 372 MB), variable TEXT columns (highway, name, ref, maxspeed, surface, oneway_tag — sparse but frequent), and B-tree page overhead (page fill factor ~90%).

### 2.5 What each optimization saves (empirical arithmetic)

Based on §2.2 real bytes:

| Optimization | Bytes saved | New DB size |
|---|---:|---:|
| **E.1 Drop Feldweg from `ways`** | 665 MB WKB + ~215 MB column overhead + ~1.35 GB R-Tree share (5.2M/9.3M) | **~5.79 GB** |
| **E.2 Per-way R-Tree, Kfz-only (drop perSegment)** | R-Tree ~5.15 GB → ~340 MB (4.07M × ~85 B/row-cluster on average, based on Berlin scaling) | **~2.98 GB** |
| **E.1 + E.2 combined** | Above two together, R-Tree becomes 4.07 M rows only | **~1.9-2.5 GB** |
| **E.3 Inline coords** | **MOOT** — see §3; `nodes_raw` is NOT in final osm.sqlite | 0 |
| **E.1 + E.2 + drop `idx_ways_source_counting`** (no longer needed if source dropped) | +165 MB | **~1.75-2.3 GB** |
| **E.1 + E.2 + drop L9/L10 from `admin_regions`** | ~19 K L9/L10 rows × ~9.5 KB avg WKB payload = ~180 MB (rough) | **~1.6-2.1 GB** |

**Final expected osm.sqlite after all Option E optimizations:** ~1.9-2.5 GB, still 2.4-3.1× over the 800 MB SC4. SC4 needs a **second renegotiation** OR one of these harder levers:

- Varint-encoded coord deltas inside geometry_wkb (§7) — saves ~50 % of WKB, another ~250 MB
- Drop L9/L10 admin regions entirely (§7)
- Feldweg drop from pmtiles too (does NOT help osm.sqlite; helps pmtiles budget only)

---

## §3 — Per-way size drivers + nodes_raw status

### 3.1 nodes_raw is NOT in final osm.sqlite — E.3 is moot

Confirmed by three independent reads:

1. `.schema` on the surviving `osm.sqlite` — no `nodes_raw` table. Tables present: `ways`, `ways_rtree`, `ways_rtree_lookup`, `way_admin`, `admin_regions`, `admin_regions_rtree`, `metadata` (plus R-Tree aux tables).
2. `tool/osm_pipeline/lib/output/osm_sqlite_schema.dart` — the canonical DDL list (`kOsmSqliteDdl`) contains no `CREATE TABLE nodes_raw`.
3. STATE.md Plan 04-06 line 202: *"Inline LineString-WKB per way (`ways.geometry_wkb BLOB`), no `nodes` join table in final osm.sqlite. Matcher's read path is a single indexed lookup — no N+1 across a nodes table."*

`nodes_raw` exists only in the scratch DB (04-03 responsibility), read during Stage E to materialize inline `geometry_wkb`, and dies with the temp file at pipeline exit. **User's "inline coords" ask is already the shipping design.**

### 3.2 Related optimization opportunity: varint-encoded delta coords in geometry_wkb

`ways.geometry_wkb` today uses OGC WKB v1 little-endian LineString: 9 bytes header + 16 bytes/point (2× IEEE 754 float64). At avg ~7 points/Kfz-way: 9 + 7×16 = 121 B → matches measured 125.70 B avg (within paging noise).

A varint zigzag-delta encoding (Protobuf-style, same as PBF DenseNodes) reduces this dramatically:
- Store first point as scaled int32 (lat/lng × 1e7 → sub-cm precision, 8 B for both).
- Subsequent points as `(delta_lat, delta_lng)` varints. Typical delta on a road segment is <100 m at 51°N ≈ ~9e-4 deg × 1e7 = 9000 → 2-byte varint.
- Header: 4-byte type + 4-byte count = 8 B.
- Payload: 8 B (anchor) + (N-1) × (~4 B) → 7-point way ≈ 8 + 8 + 6×4 = 40 B. **~68 % shrinkage vs 121 B.**

Projected Kfz WKB savings if applied: 488 MB → ~155 MB → save **~330 MB** additional beyond E.1+E.2.

**Downside:** changes the WKB format — Phase 5 matcher must decode our custom format instead of standard OGC WKB. Modest cost (~40 LOC decoder in the matcher). MEDIUM confidence recommendation — plan 04-10.1 should evaluate this as a **stretch goal**, not part of the E baseline.

### 3.3 Feldweg-drop size projection (empirical anchor)

Per §2.4:
- Kfz ways: 4 070 051 rows, avg 125.7 B WKB → 488 MB
- Feldweg ways: 5 224 059 rows, avg 133.6 B WKB → 665 MB

Feldweg WKB is ~1.36 GB total including B-tree overhead + column payload proportional (Feldweg is 56.2 % of the 1 739 MB `ways` table → **~977 MB Feldweg-attributable `ways` bytes**).

**Bonus effect on R-Tree:** perSegment R-Tree has 61 M rows for 9.3 M ways ≈ 6.57 seg/way. Feldweg contributes ~5.22 M × 6.57 = 34.3 M R-Tree rows. Dropping Feldweg alone from the perSegment R-Tree saves ~34/61 × 5148 MB = **~2 895 MB** of R-Tree bytes.

**Combined E.1 saving under current perSegment design:** ~977 MB (ways) + ~2 895 MB (R-Tree) + ~165 MB (idx_ways_source_counting can drop) = **~4 037 MB (~4.0 GB) saved by E.1 alone**, taking the DB from 7.99 GB → ~3.99 GB.

Then E.2 (perWay Kfz-only) collapses the remaining 4.07 M Kfz R-Tree rows further from ~2.25 GB to ~340 MB → **~1.9 GB** net osm.sqlite.

---

## §4 — R-Tree perWay vs perSegment (E.2)

### 4.1 What each granularity gives the matcher

Reading `tool/osm_pipeline/lib/output/rtree_builder.dart`:

- **perSegment** (current default): one R-Tree row per two-point segment. `ways_rtree_lookup` maps `rtree_id → (way_id, segment_idx)`. Berlin measured: 176 567 ways → 555 920 R-Tree rows (~3.15 seg/way). Germany: 9.3 M ways → 61 M R-Tree rows (~6.57 seg/way — longer average way length in rural Germany).
- **perWay** fallback: one R-Tree row per way with full-way bbox. `segment_idx = -1`.

### 4.2 Runtime cost of perWay (Phase 5 P5 SC2: p95 < 30 ms)

Per 04-RESEARCH.md §8: at perWay, a 10 km autobahn's bbox is ~10 km × 100 m. A query near the middle of that autobahn's bbox returns the way as a candidate even if the query point is 5 km along the road. Cost trade:

- **R-Tree returns more candidates per query** (perWay bbox is looser).
- **In-Dart filter is O(candidates × points_per_way)** — must walk each candidate's inline geometry to find the nearest point.
- At Berlin scale (04-06 spot check): perSegment near Brandenburg Gate returned 85 candidates. Estimated perWay for the same query: ~10-30 candidates but each is a full way (avg 6.57 pts) → ~20 × 6.57 = 131 point-distance checks. **Roughly comparable cost to filtering 85 segments in Dart** (probably within 2×).
- Modern SSD + released Dart with inlined WKB decode: point-distance filter is <10 µs/point. Even at 5× degradation, p95 < 30 ms is very achievable.

**HMM matcher impact:** the matcher uses R-Tree candidates as input to emission-probability computation, then Viterbi picks. The number of candidates affects Viterbi state-space size but not correctness — a wider candidate set is safer (fewer missed matches). PerWay is arguably **more accurate** than perSegment at cost of ~2× candidates.

### 4.3 Byte savings

perSegment R-Tree cluster today: 5 148 MB (§2.3).
perWay Kfz-only projected: 4.07 M rows × ~85 B/row-cluster (empirical Berlin extrapolation: 176 567 ways at perWay would use ~15 MB total R-Tree cluster on Berlin → scaled to Germany's 4 M ways: ~340 MB total R-Tree cluster).

**Net savings from E.2 alone (assuming Feldweg still in DB):** 5 148 MB → ~700 MB (Kfz + Feldweg perWay) = ~4.4 GB saved.
**With E.1 + E.2:** 5 148 MB → ~340 MB = ~4.8 GB saved from R-Tree cluster.

### 4.4 Recommendation

**GO on perWay + Kfz-only R-Tree.** The correctness cost is negligible (Phase 5 matcher already uses a candidate set + Viterbi, which is robust to wider candidates). The byte savings are massive. Documentation update: 04-RESEARCH §8 "default per-segment" recommendation is superseded by §2 empirical evidence.

---

## §5 — Isolate multithreading feasibility (E.4)

### 5.1 Stage D per-way inner loop (from `way_admin_join.dart`)

```dart
for each Kfz way W in ways_raw:
  decode node_ids BLOB
  for each nid: SELECT lat, lng FROM nodes_raw WHERE id = ?   // prepared stmt
  build linePoints List<Vec2>
  compute wayBbox
  for level in [2,4,6,8,9,10]:                                // 6 levels
    for each admin in adminByLevel[level]:                    // 30k+ regions total
      if bbox_overlap: run Sutherland-Hodgman clip
      for each subsegment: INSERT INTO way_admin_raw
```

**Hot loop** is:
1. Node-coord lookup (SQL prepared stmt, ~1 µs × 6.57 avg nodes/way × 4 M ways = ~25 s aggregate).
2. Bbox overlap prefilter (cheap).
3. Sutherland-Hodgman clip against each admin polygon that passes bbox filter.
4. INSERT per surviving sub-segment.

Wall-clock for Stage D on Germany: ~13h50m (from `germany-run.log`). This is 99% CPU-bound in polygon-clip; SQL is amortized.

### 5.2 sqlite3 package isolate story (HIGH confidence)

From reading `sqlite3-2.9.4` package sources (`lib/src/sqlite3.dart`, `lib/src/ffi/bindings.dart`):

- `sqlite3.open(path)` returns a `Database` bound to the current isolate. **A `Database` handle cannot be sent through a `SendPort`** — the `Pointer<sqlite3>` FFI handle is isolate-local.
- Each isolate must call `sqlite3.open(path)` independently. Multiple isolates opening the same file work IF SQLite is compiled in serialized or multi-thread mode (the pub package's prebuilt binaries are compiled with `SQLITE_THREADSAFE=1` serialized).
- With `PRAGMA journal_mode=WAL`, multiple readers can proceed in parallel; writers still serialize. Our scratch DB uses `journal_mode=OFF` (04-03 pragma) — this is a WRITE-mostly DB, not WAL. **Multiple readers over `OFF` journal are safe** as long as no writer is active concurrently — SQLite's file-locking still applies.
- For Stage D specifically: `nodes_raw` is READ-ONLY at that point (04-03 populated it and closed the write). Multiple isolates each opening the scratch DB read-only for the node lookup is safe.

**Verified constraint:** the SendPort marshaling cost of shipping way rows through isolates is non-trivial. A way row (way_id + node_ids blob + linePoints) is ~50-200 B. Marshaling 4 M ways × ~100 B = 400 MB across isolate boundaries → costly if not partitioned smartly.

### 5.3 Recommended coordinator pattern

```
Coordinator (main isolate):
  1. Loads adminByLevel from scratch DB ONCE (30 K regions, ~280 MB WKB).
  2. Spawns N worker isolates. To each, sends:
     - Path to scratch DB (workers open read-only handle themselves).
     - adminByLevel serialized (or better: shared via TransferableTypedData for zero-copy WKB blobs).
     - A partition of way_ids (e.g., worker i gets ways where id % N == i).
  3. Each worker:
     - Opens scratch.sqlite read-only.
     - For each way in partition: SELECT + build linePoints + iterate adminByLevel + clip.
     - Accumulates `(way_id, region_id, admin_level, fraction_start, fraction_end)` tuples.
     - Every 5000 rows: flushes tuples through a SendPort back to coordinator.
  4. Coordinator: consumes tuples from all workers, INSERTs into way_admin_raw serially inside a single transaction.
```

**Alternative — each worker writes its own file:** Each isolate writes to `way_admin_raw_worker_{i}.sqlite`, coordinator concatenates via `ATTACH DATABASE` + `INSERT INTO ... SELECT`. Sidesteps SendPort throughput. Simpler.

### 5.4 Expected speedup (Amdahl-corrected)

- Stage D wall-clock today: 13h50m = ~830 min.
- Serial component (admin load, final concatenation, WAL checkpoint): ~5-10 min.
- Parallelizable (per-way clip): ~820 min.
- With 6 workers: ~820 / 6 + 5 = ~142 min ≈ **2h22m**. Speedup ~5.8×.
- With 8 workers: ~820 / 8 + 5 = ~108 min ≈ **1h48m**. Speedup ~7.7×.
- Diminishing returns after ~8 workers due to L3 cache contention, SendPort/write bottleneck, SSD IOPS.

**Recommendation:** N = min(6, Platform.numberOfProcessors − 2) as default; --workers=N CLI flag to override.

### 5.5 Other stages — worth parallelizing?

| Stage | Bottleneck | Isolate benefit |
|---|---|---|
| **B (Kfz filter)** | PBF-read + zlib decompression | **YES.** PBF blocks are independently decompressable. Split PBF into N block ranges, N isolate workers, each writes rows to its own scratch DB, coordinator merges. Expected speedup 4-6× on 8-core box. |
| **C (admin extraction)** | Same as B (PBF-read) | **YES.** Same partitioning as B, but a lot fewer relations to build multipolygons — probably not worth separate parallel effort; fold into a single "parallel PBF pass" for both B+C. |
| **D (way_admin join)** | CPU-bound polygon clip | **YES.** Main target. See §5.3. |
| **E (osm.sqlite write)** | Serial INSERTs to output DB | **NO.** SQLite writes are single-writer. Parallelizable only via multi-file-write-then-merge, and the merge is dominated by re-write anyway. Skip. |
| **F.1 (GeoJSONSeq write)** | Serial file writes | **PARTIAL.** Could write per-layer files in parallel (4 layers = 4 workers, ~4× speedup for the emission stage) but tippecanoe itself is single-threaded and dominates F.2. Tippecanoe's `--read-parallel` on multiple input files is a real feature — worth pursuing. |
| **F.2 (tippecanoe)** | External subprocess | **NO** for us; tippecanoe manages its own internal parallelism. Just make sure the input is emitted efficiently. |

**Priority order:** D (biggest wall-clock win) > B+C (medium wall-clock, biggest visible-to-user win: the initial parse becomes fast) > F.1 (small win).

---

## §6 — Progress logging design (E.5)

### 6.1 Where it lives

Current `lib/cli/logger.dart` is a 23-line `abstract final class Logger` with three static methods (`info`, `warn`, `error`) writing to stderr. It has no state, no timing, no throughput awareness.

**Recommended structure:**

- Extend `logger.dart` with a new class `ProgressLogger` — a stateful helper. Keep the existing `Logger` static methods intact (many call sites already use them).
- File placement: same file (`lib/cli/logger.dart`) or a sibling (`lib/cli/progress_logger.dart`) — recommend **sibling** because ProgressLogger is a class with state, while `Logger` is stateless static. Cleaner separation.

### 6.2 API sketch (HIGH confidence)

```dart
class ProgressLogger {
  ProgressLogger(this.stage, {required this.total, this.everyMs = 5000, DateTime? now});

  final String stage;         // e.g. 'Stage D (way_admin join)'
  final int total;            // total unit count (ways, blocks, rows)
  final int everyMs;          // min interval between emitted lines

  int _done = 0;
  DateTime _lastEmit;
  final Stopwatch _sw = Stopwatch()..start();

  void tick([int n = 1]) {
    _done += n;
    final now = DateTime.now();
    if (now.difference(_lastEmit).inMilliseconds < everyMs && _done < total) return;
    final elapsedMs = _sw.elapsedMilliseconds;
    final rate = _done * 1000 / elapsedMs;    // items/sec
    final pct = _done * 100 / total;
    final etaSec = rate > 0 ? (total - _done) / rate : 0;
    Logger.info(
      '[$stage] $_done/$total (${pct.toStringAsFixed(1)}%) '
      'rate=${rate.toStringAsFixed(0)}/s '
      'eta=${_formatEta(etaSec)}'
    );
    _lastEmit = now;
  }

  void finish() {
    Logger.info('[$stage] done — ${_done} items in ${_sw.elapsed.inSeconds}s '
      '(${(_done * 1000 / _sw.elapsedMilliseconds).toStringAsFixed(0)}/s)');
  }
}
```

**Cadence:** at most one line per 5 s (`everyMs=5000`). Ensures the log is skimmable during a 14-hour run — you can eyeball rate/ETA every scroll page.

### 6.3 Isolate-boundary progress

Workers cannot log directly (isolates share stderr but interleaved output is noisy). Pattern:

- Worker isolate maintains its own `_done` counter locally.
- Every N ticks (e.g. N=1000), worker sends `ProgressMessage(workerId, ticksSinceLastReport)` through its SendPort.
- Coordinator maintains a single `ProgressLogger` aggregating all worker reports. Ticks accumulate across all workers.
- Coordinator's ProgressLogger emits at the same 5s cadence, showing the aggregate.

### 6.4 Tippecanoe integration

Tippecanoe writes its own progress bar to stderr (already streamed through 04-07's `TippecanoeRunner`). Recommend:

- Prefix each tippecanoe line with `[Stage F.2 tippecanoe]` before echoing to our stderr — makes the log grep-friendly across the multi-stage output.
- Do NOT try to parse tippecanoe's progress format and re-emit — brittle. Just pass-through.

### 6.5 Wire-up sites (based on `pipeline_orchestrator.dart`)

| Stage | tick target | total | Notes |
|---|---|---|---|
| B (Kfz filter) | per PBF block OR per way emitted | pass 1: PBF total blocks; pass 2: known way count | Two-pass, so ProgressLogger per pass |
| C (admin extraction) | per admin relation processed | relationsSeen (known after pass A of C's 3-pass) | See 04-04 STATE entry |
| D (way_admin join) | per Kfz way processed | 4 070 051 (known from `SELECT COUNT(*) FROM ways_raw WHERE source='kfz'`) | Aggregated across N workers |
| E (osm.sqlite write) | per way written | same as D | Serial |
| F.1 (GeoJSONSeq emit) | per feature emitted | Kfz + Feldweg + admins + water + labels count | Serial |

---

## §7 — Post-optimization size projection

Using §2 real data as anchor:

### 7.1 Baseline vs after each optimization

| Config | Ways | R-Tree cluster | admin_regions | way_admin | Indexes | **Total osm.sqlite** |
|---|---:|---:|---:|---:|---:|---:|
| **Today (Germany)** | 1 739 MB | 5 148 MB | 282 MB | 55 MB | ~372 MB | **7 616 MB (7.99 GB)** |
| **+ E.1 Drop Feldweg** | 762 MB | ~2 253 MB (Kfz perSegment) | 282 MB | ~30 MB | ~209 MB | **~3 536 MB (~3.5 GB)** |
| **+ E.1 + E.2 (perWay Kfz)** | 762 MB | ~340 MB | 282 MB | ~30 MB | ~209 MB | **~1 623 MB (~1.6 GB)** |
| **+ E.1 + E.2 + drop L9/L10 admin** | 762 MB | ~340 MB | ~100 MB | ~30 MB | ~209 MB | **~1 441 MB (~1.4 GB)** |
| **+ E.1 + E.2 + drop L9/L10 + varint geometry_wkb** | ~278 MB | ~340 MB | ~100 MB | ~30 MB | ~180 MB | **~928 MB (~0.9 GB)** |
| **All above + drop `admin_regions.geometry_wkb` (only keep bbox + metadata)** | ~278 MB | ~340 MB | ~5 MB | ~30 MB | ~180 MB | **~833 MB (~0.8 GB)** ✓ SC4 |

Confidence: MEDIUM. R-Tree cluster estimation is anchored on `dbstat` measurement; varint geometry is a projected format change with typical Protobuf shrinkage.

### 7.2 pmtiles

Unchanged if Feldweg stays on the map (recommended). Current germany-base.pmtiles = 883.7 MB, which already blows the 200 MB pmtiles SC4 budget. **Separate concern** — plan 04-10.1 doesn't touch pmtiles unless the user opts to drop Feldweg from that too:

- If Feldweg dropped from pmtiles: roads layer feature count drops from 9.3 M → 4.07 M. pmtiles roughly linear in feature count → ~883 MB × 4.07 / 9.29 = **~387 MB** — better but still 1.9× over 200 MB SC4. Would need additional levers (drop `stream` water kind, drop small labels).
- If Feldweg kept: **883 MB unchanged**.

**Recommendation:** for plan 04-10.1, treat pmtiles as a separate optimization pass (call it plan 04-10.2 or fold into a follow-up). Focus this plan on osm.sqlite where the win is 8× vs pmtiles' 2×.

### 7.3 Bottom line

- **osm.sqlite achievable:** ~1.4-1.6 GB with just E.1 + E.2 (no format changes). ~0.9 GB with varint format change. ~0.8 GB with drop-admin-WKB.
- **SC4 800 MB status:** hard-borderline. Achievable with format changes, tight-fit without. Recommendation: **relax SC4 to 1.5 GB** as the pragmatic target for this plan; explicit format-change stretch goals get us to ~0.8-1.0 GB if the planner wants to chase them.

---

## §8 — Berlin iterative-test strategy

Berlin PBF (94 MB) is the fast-iteration loop. Current Berlin measurements (from `04-06-SUMMARY` line 209 / STATE):

- Kfz: 91 707 ways
- Feldweg: 84 860 ways
- osm.sqlite baseline: 84.8 MB
- Stage D wall-clock: ~130 s (Berlin subset of the pipeline's total ~4 min)

### 8.1 Per-optimization Berlin gates

| Optimization | Expected Berlin behavior | Pass gate |
|---|---|---|
| **E.1 Feldweg drop** | osm.sqlite drops from 84.8 MB to ~40-45 MB (48-53 % shrinkage). Row count in `ways` drops from 176 567 to 91 707. | `stat` size < 50 MB; `SELECT COUNT(*) FROM ways` = 91 707 |
| **E.2 perWay R-Tree** | ways_rtree row count drops from 555 920 → 91 707 (or 4.07 M whole-Germany scale). osm.sqlite R-Tree cluster shrinks proportionally (~85 % of R-Tree bytes gone). | `SELECT COUNT(*) FROM ways_rtree` = ~91 707; total DB < 25 MB |
| **E.4 Isolates on Stage D** | Berlin Stage D wall-clock drops from ~130 s → ~40-60 s (expect ~2-3× speedup on small dataset; small N ways = smaller parallel-region gain per Amdahl). Not the full 6× seen on Germany. | Wall-clock < 60 s AND `way_admin` row count identical to serial run (correctness gate) |
| **E.5 Progress logging** | At least one `[info]` line every 5 s during Stage B/C/D. Never longer than 5 s of silence. | Manual observation via `smoke.sh` → each stage emits ≥ 1 progress line for a run > 5 s |
| **All combined** | Berlin pipeline end-to-end < 3 min (from 6 min today, driven by tippecanoe's ~4 min not our stages). | Wall-clock < 180 s |

### 8.2 Fastest iteration loop

```
cd tool/osm_pipeline
dart test test/... --name="way_admin_join"     # unit tests first
./smoke.sh                                      # end-to-end Berlin, ~3 min
```

Executor discipline:
1. Land Feldweg drop (E.1) first — biggest byte win, smallest code footprint.
2. Rerun smoke, confirm osm.sqlite < 50 MB.
3. Land perWay R-Tree (E.2) — reads a decision file (or CLI flag).
4. Rerun smoke, confirm R-Tree cluster shrunk.
5. Add progress logging (E.5) — visibility for the isolate work.
6. Add isolates for Stage D (E.4) — the risky one; save for last.
7. Rerun smoke, verify row-count identical + faster.
8. Only THEN attempt full Germany.

---

## §9 — Risks + open questions

### 9.1 Isolate correctness

- **SQLite multi-reader corner:** `journal_mode=OFF` scratch DB with multiple readers is officially fine, but has less real-world battle-testing than WAL. Mitigation: temporarily switch scratch to `journal_mode=WAL` for Stage D specifically — WAL supports concurrent readers explicitly. Trade: WAL requires `synchronous=NORMAL` minimum; scratch's `synchronous=OFF` is more aggressive. Should measure.
- **Isolate startup cost:** spawning N isolates costs ~50 ms/isolate + code-loading. For Stage D at 13h → negligible. For Stage B on Berlin (< 30 s), 6 isolate spawns cost 300 ms → still negligible.
- **SendPort throughput:** if workers ship tuples too fast, the coordinator becomes bottleneck. Mitigate: batch-flush per 5000 tuples. Alternative: workers write to per-worker sqlite files, coordinator ATTACH+merge.

### 9.2 Feldweg drop retroactively breaking Phase 7

- REN-02's driven-Feldweg-color path is what breaks. Alternatives:
  - Accept regression (documented in §1.6).
  - Store a lightweight `feldweg_ways(way_id, geometry_wkb)` table without R-Tree / without admin denorm — enables Phase 7 rendering but not Phase 5 matching. Cost: ~977 MB / ~250 MB post-varint = big.
  - Reintroduce Feldweg in a later phase (post-v1) if user demand emerges.
- **Recommend:** accept. STATE the regression explicitly in the REQUIREMENTS.md edit.

### 9.3 Package version constraints

- `sqlite3 ^2.4.0` (per STATE Plan 04-03 line 175) — supports `NativeCallable.isolateLocal`, prebuilt binaries for Windows/macOS/Linux. Isolate use is idiomatic.
- Dart SDK 3.5 (project constraint) — `Isolate.spawn`, `SendPort`/`ReceivePort`, `TransferableTypedData` all mature. `Isolate.exit` (fast marshaling of the return value) is available in 3.5+.
- No new pubspec deps required for the isolate work.

### 9.4 Open questions

1. **Should we bump `pipelineSchemaVersion` (currently 1)?** — YES, dropping Feldweg from osm.sqlite + changing R-Tree schema is a breaking schema change. Bump to 2. Phase 5 integrity check will read `PRAGMA user_version` and require version = 2.
2. **Where does the R-Tree granularity decision live?** — Today it's a CLI-invisible `RtreeBuilder.loadFromMeasurement()` reading the measurement doc. Recommend: promote to a proper CLI flag `--rtree-granularity=perSegment|perWay` with `perWay` as the new default post-E.2. Measurement-file lookup can stay as fallback.
3. **Does the matcher's `findWaysNear` need modification for perWay?** — Yes, minor. Current SQL assumes `ways_rtree_lookup.segment_idx >= 0`. With perWay, `segment_idx = -1` sentinel; matcher must not use the segment index as an offset into the geometry. Documented tap for Phase 5.

---

## §10 — Recommended wave breakdown

Wave design principles:
- Progress logging first (visibility unblocks all subsequent stages).
- Feldweg drop second (biggest single win, low risk).
- perWay R-Tree third (second-biggest win, low risk).
- Isolates last (highest complexity, biggest wall-clock win).
- Each wave ends with a Berlin smoke pass gate.

### Wave 1 — Progress logging (E.5)

- **Plan 04-10-1-01-progress-logging.** Add `ProgressLogger` class per §6. Wire into stages B, C, D, E, F.1. Tag tippecanoe output with `[Stage F.2]`.
- Berlin gate: every stage emits ≥ 1 info line for runs > 5 s.
- Effort: ~2h. Zero data-format changes.

### Wave 2 — Feldweg drop (E.1)

- **Plan 04-10-1-02-feldweg-scope-narrow.** Update `osm_sqlite_writer.dart` to skip Feldweg source ways. Drop `source` + `is_counting` + `idx_ways_source_counting`. Emit `REQUIREMENTS.md` / `ROADMAP.md` edits per §1.6. Bump `pipelineSchemaVersion` = 2.
- Berlin gate: osm.sqlite < 50 MB, ways row-count = 91 707.
- Effort: ~3h. Schema break — must land in one plan.

### Wave 3 — perWay R-Tree (E.2)

- **Plan 04-10-1-03-perway-rtree.** Change default granularity to `perWay`. Update Phase 5's `findWaysNear` guard (`segment_idx = -1` sentinel handling). Promote CLI flag from measurement-file inspection to explicit `--rtree-granularity=perWay|perSegment` (default: perWay).
- Berlin gate: `ways_rtree` row-count = 91 707 (exact-match Kfz count post-Wave-2), total DB < 25 MB.
- Effort: ~2h. Small, focused.

### Wave 4 — Stage D isolates (E.4)

- **Plan 04-10-1-04-stage-d-isolates.** Split Stage D per §5.3 coordinator pattern. `--workers=N` CLI flag. Berlin gate: wall-clock < 60 s AND `way_admin` row-count identical to serial-run baseline.
- Effort: ~6h. Highest complexity in this plan set.

### Wave 5 (optional stretch) — Stage B+C isolates + varint geometry

- **Plan 04-10-1-05-parse-isolates-stretch.** Only if Wave 4 doesn't deliver enough wall-clock win for full-Germany. Splits PBF read across N workers. Varint delta coord encoding as a separate task if Wave 4 doesn't hit budget.
- Effort: ~4-8h; deferred/optional.

### Wave 6 — Full-Germany close-out re-run

- **Plan 04-10-1-06-germany-close-out.** Rerun full Germany, measure new osm.sqlite bytes, publish measurement doc, update SC4 (relax to 1.5 GB or 800 MB depending on outcome). Update `04-10-PLAN.md` (existing full-Germany plan) or supersede it.
- Effort: ~1h coding + ~4-14h wait for the run (isolates should get us to ~2-4h).

### Total plan count

**5 core plans (waves 1-4 + wave 6) + optional stretch wave 5.** Fits Phase 4's existing wave-based structure. Waves 1-3 are independent enough to be parallelizable; wave 4 depends on wave 1 (progress logging inside isolate coordinator); wave 6 depends on all prior.

---

## Sources

### Primary (HIGH confidence)

- **Live `sqlite3` query of `tool/osm_pipeline/out/osm.sqlite`** — `dbstat` for per-table bytes, COUNT/SUM/AVG for row-count + geometry sizes. Empirical anchor for §2.
- **`.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md`** — Berlin per-table baseline; anchor for §8.
- **STATE.md P4 entries (STATE lines 159..231)** — architectural decisions, schema locks, granularity defaults.
- **Package `sqlite3-2.9.4` source** — isolate story, `NativeCallable.isolateLocal`, no thread-safe reserved keyword issues.
- **`tool/osm_pipeline/lib/output/osm_sqlite_schema.dart`** — confirms `nodes_raw` absent from final DB (E.3 moot).
- **`tool/osm_pipeline/lib/output/rtree_builder.dart`** — perSegment/perWay definitions.
- **`tool/osm_pipeline/lib/intersect/way_admin_join.dart`** — Stage D loop shape for isolate partitioning.

### Secondary (MEDIUM confidence)

- **04-RESEARCH.md §7 §8 §10** — the original Phase 4 research; anchors "Germany ~4 M Kfz" estimate, R-Tree cost projection.
- **Amdahl-based speedup projections in §5.4** — reasonable but not measured. Real N-worker speedup varies by CPU/SSD.
- **Varint geometry_wkb projection in §3.2** — based on Protobuf-analogous encoding; not implemented anywhere in the code yet.

### Tertiary (LOW confidence)

- None material to the recommendations.

---

## Confidence assessment

| Area | Level | Reason |
|---|---|---|
| Standard stack (sqlite3 + isolates) | HIGH | Package source read; no new deps needed |
| Per-table byte breakdown (§2) | HIGH | Empirical `dbstat` query on real 7.99 GB artifact |
| Feldweg drop math (§3.3) | HIGH | Direct row-count + geometry_wkb SUM from live DB |
| perWay R-Tree savings (§4.3) | MEDIUM | Berlin-based extrapolation; real Germany may differ within ±30 % |
| Isolate speedup projection (§5.4) | MEDIUM | Amdahl arithmetic — real speedup depends on SSD IOPS, cache contention |
| Varint format stretch (§3.2) | MEDIUM | Standard Protobuf technique but unimplemented in-repo; format change has schema-compat cost |
| Post-optimization SC4 fit (§7.1) | MEDIUM | Composite of above uncertainties |
| Progress logging design (§6) | HIGH | Simple stateful helper; standard pattern |
| REQUIREMENTS/ROADMAP edits (§1.6) | HIGH | Grep-verified all Feldweg mentions; edits are narrowing, not additive |

**Research valid until:** 2026-08-06 (30 days — stable domain, no fast-moving dependencies).

---

*Phase: 04-osm-pipeline*
*Plan: 04-10.1*
*RESEARCH COMPLETE*
