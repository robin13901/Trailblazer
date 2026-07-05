---
phase: 04-osm-pipeline
plan: 04
subsystem: pipeline-geometry
tags: [osm, admin, multipolygon, wkb, sqlite, dart, pipeline]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: 04-CONTEXT admin geometry decision (both osm.sqlite + pmtiles)
  - phase: 04-osm-pipeline
    provides: 04-RESEARCH §6 target schema; §12 pitfalls #1/#4/#5/#10
  - phase: 04-osm-pipeline
    provides: 04-02 PbfReader.stream() + tiny.osm.pbf fixture
  - phase: 04-osm-pipeline
    provides: 04-03 ScratchDb + sqlite3 dep + Stage B CLI wire
provides:
  - "isAdminRelation(OsmRelation) predicate — accepts type=boundary OR type=multipolygon + boundary=administrative + admin_level ∈ {2,4,6,8,9,10}"
  - "kCityStateNames = {Berlin, Hamburg, Bremen} — dual-write trigger set"
  - "MultipolygonAssembler.assemble() — fragment stitching, winding correction, self-intersection detection, inner→outer bucketing"
  - "encodeMultiPolygon(MultiPolygon) → Uint8List — OGC WKB v1 (little-endian, no SRID), deterministic byte-for-byte"
  - "extractAdminRegions() — 3-pass streaming Stage C, writes admin_regions_raw rows + logs skipped rings"
  - "AdminScratchWriter interface + InMemoryAdminScratchWriter + ScratchDbAdminWriter"
  - "admin_regions_raw scratch table (region_id, osm_relation_id, admin_level, name, geometry_wkb, bbox_*) via kAdminScratchSchema — separate file from 04-03's scratch_schema.dart"
  - "Stage C wired into bin/osm_pipeline.dart between Stage B and D/E stubs"
affects: [04-05, 04-06, 04-07, 04-08, 05-osm-db, 08-focus-area]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "AdminScratchWriter abstract interface — decouples stage from 04-03's ScratchDb type; in-memory writer for hermetic tests, sqlite3 writer for prod"
    - "Dependency-free geometry primitives (Point / Polygon / MultiPolygon) — no meta @immutable, no dart_jts, no spatially"
    - "OGC WKB flat encoder — pre-computed buffer size, single ByteData allocation, deterministic output"
    - "3-pass streaming Stage: PBF re-read for relations → member ways → member nodes. Simple; 04-06 may fold passes"
    - "City-state dual-write is data-driven (name lookup vs relation id) so it survives OSM ID churn"

key-files:
  created:
    - "tool/osm_pipeline/lib/admin/admin_relation_filter.dart"
    - "tool/osm_pipeline/lib/admin/geometry.dart"
    - "tool/osm_pipeline/lib/admin/multipolygon_assembler.dart"
    - "tool/osm_pipeline/lib/admin/wkb_writer.dart"
    - "tool/osm_pipeline/lib/admin/admin_pipeline.dart"
    - "tool/osm_pipeline/lib/scratch/admin_scratch_schema.dart"
    - "tool/osm_pipeline/lib/scratch/scratch_db_admin_ext.dart"
    - "tool/osm_pipeline/test/admin/admin_relation_filter_test.dart"
    - "tool/osm_pipeline/test/admin/multipolygon_assembler_test.dart"
    - "tool/osm_pipeline/test/admin/wkb_writer_test.dart"
    - "tool/osm_pipeline/test/admin/admin_pipeline_test.dart"
    - "tool/osm_pipeline/test/admin/scratch_db_admin_ext_test.dart"
    - "tool/osm_pipeline/test/admin/city_state_dual_write_test.dart"
  modified:
    - "tool/osm_pipeline/bin/osm_pipeline.dart (Stage C wired between B and D/E stubs)"

key-decisions:
  - "Admin filter accepts type=boundary OR type=multipolygon — DE Landkreise are empirically tagged with multipolygon; rejecting them would drop real boundaries (04-RESEARCH §12 fallback note)"
  - "City-state dual-write is name-driven (kCityStateNames = {Berlin, Hamburg, Bremen}), not relation-id-driven — stable across OSM revisions"
  - "AdminScratchWriter abstract interface + in-memory + real sqlite3 impls — decouples 04-04 from 04-03's ScratchDb type at test time; prod path uses ScratchDb.raw handle without touching 04-03 files"
  - "admin_scratch_schema.dart lives in its own file, NOT merged into scratch_schema.dart — preserves parallel-wave 04-03/04-04 lane discipline"
  - "Point.equalsCoord() helper instead of == override — avoids meta.@immutable dep + avoid_equals_and_hash_code_on_mutable_classes lint hoop"
  - "WKB flat variant only (no EWKB/SRID prefix) — we live in EPSG:4326 exclusively"
  - "O(N²) self-intersection check — acceptable for admin rings; sweep-line replacement deferred to a follow-up if degenerate 100k-vertex rings appear"
  - "Three-pass streaming Stage C — clarity over throughput; 04-06 orchestrator may fold passes with 04-03's stream"

patterns-established:
  - "Stage-C-shaped orchestrator: `extractAdminRegions({pbf, writer, skippedLog})` returns a summary record — 04-05/06 stages follow the same shape"
  - "AdminExtractionSummary record: relationsSeen / relationsAccepted / regionsWritten / dualWrites / rejected — one-line CLI report"
  - "Cross-lane writer coordination: abstract interface + in-memory testing double + real-db adapter that touches ONLY the collaborating lane's public accessor"

# Metrics
duration: ~20min
completed: 2026-07-05
---

# Phase 4 Plan 04: Admin Boundary Extraction Summary

**Admin boundaries at OSM levels 2/4/6/8/9/10 extract cleanly through a pure-Dart three-pass pipeline: filter → assemble → WKB. Berlin/Hamburg/Bremen dual-write at levels 4 AND 6 (pitfall #10). Self-intersecting rings and missing member ways are logged and skipped, never thrown. 42 new admin-lane tests (127 pipeline total) green; CLI Stage C wired end-to-end.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-07-05T17:24:19Z
- **Completed:** 2026-07-05T17:44:00Z (approx.)
- **Tasks:** 3
- **Files created:** 13 (7 source + 6 test)
- **Files modified:** 1 (`bin/osm_pipeline.dart` — Stage C wire, surgical addition)
- **Tests added:** 42 (127 pipeline total, up from 98 after 04-03)

## Accomplishments

- Built the admin-boundary extraction stage as a self-contained sub-package `tool/osm_pipeline/lib/admin/` (5 files, ~700 LOC combined) with an accompanying scratch-side contract (`lib/scratch/admin_scratch_schema.dart` + `lib/scratch/scratch_db_admin_ext.dart`). All new files; no changes to 04-03's `scratch_db.dart` / `scratch_schema.dart` (parallel-wave lane discipline preserved).
- Landed `isAdminRelation()` accepting `type=boundary` OR `type=multipolygon` with `boundary=administrative` and `admin_level` in `{2,4,6,8,9,10}`. The `type=multipolygon` acceptance closes 04-RESEARCH §12's empirical fallback: many DE Landkreise use `type=multipolygon` in the wild, and rejecting them would drop real admin boundaries.
- Shipped a pure-Dart `MultipolygonAssembler.assemble()` implementing the full ring lifecycle:
  1. Partition members by role (`outer` / `inner` / empty defaults to `outer`).
  2. Resolve refs; missing ways or nodes log to `skipped.log` and drop the ring (pitfall #4).
  3. Stitch open fragment ways at shared endpoints into closed rings.
  4. Detect self-intersection via O(N²) segment crossing check; log + drop (pitfall #5).
  5. Correct ring winding: outer CCW, inner CW.
  6. Bucket inner rings into their smallest containing outer via point-in-ring + extent tiebreak; orphan inners are logged and dropped.
- OGC WKB flat-variant encoder (`encodeMultiPolygon`): little-endian byte order, no SRID/EWKB prefix, pre-computed exact buffer size, deterministic byte-for-byte output for identical inputs. Reference decoder in the tests round-trips every geometry shape (single polygon, disjoint multi-polygon, polygon with a hole).
- `extractAdminRegions()` runs three sequential streaming passes over the PBF (Pass A: admin relations + member way ids; Pass B: member ways + their node ids; Pass C: those nodes only). Pass D assembles + writes. Nameless relations and geometry-empty assemblies are rejected + logged. City-states (Berlin/Hamburg/Bremen) at `admin_level=4` are dual-written at `admin_level=6` (pitfall #10).
- CLI Stage C wired between Stage B (highway filter) and the D/E stubs in `bin/osm_pipeline.dart` — surgical addition, no other code paths touched. Manual smoke against the tiny fixture reports "1/1 admin relations accepted, 1 rows written (0 city-state dual-writes), 0 rejected".
- `dart analyze` clean inside `tool/osm_pipeline/`; all 127 pipeline tests green.

## Task Commits

Each task committed atomically; each file staged individually per Wave-3 lane discipline.

1. **Task 1: Admin relation filter + scratch schema + writer contract** — `1e735e9` (feat)
   - `lib/admin/admin_relation_filter.dart`
   - `lib/scratch/admin_scratch_schema.dart`
   - `lib/scratch/scratch_db_admin_ext.dart` (InMemoryAdminScratchWriter only in this commit)
   - `test/admin/admin_relation_filter_test.dart` (15 tests)

2. **Task 2: Multipolygon assembler + WKB writer** — `61f4e61` (feat)
   - `lib/admin/geometry.dart` — Point / Polygon / MultiPolygon + ring math helpers
   - `lib/admin/multipolygon_assembler.dart` — fragment stitching + assembly
   - `lib/admin/wkb_writer.dart` — OGC WKB encoder
   - `test/admin/multipolygon_assembler_test.dart` (10 tests: 7 assembler + 3 geometry helpers)
   - `test/admin/wkb_writer_test.dart` (5 tests)

3. **Task 3: admin_pipeline orchestrator + Stage C CLI wire + real-sqlite tests** — `12f76db` (feat)
   - `lib/admin/admin_pipeline.dart` — extractAdminRegions() 3-pass streaming
   - `lib/scratch/scratch_db_admin_ext.dart` — added ScratchDbAdminWriter (real sqlite3 path)
   - `bin/osm_pipeline.dart` — Stage C wire (surgical addition between Stage B and D/E stubs)
   - `test/admin/admin_pipeline_test.dart` (5 tests, tiny-fixture smoke)
   - `test/admin/scratch_db_admin_ext_test.dart` (4 tests, real sqlite3 round-trip)
   - `test/admin/city_state_dual_write_test.dart` (5 tests, pitfall #10 branch coverage)

**Plan metadata commit:** to follow after this summary lands.

## Files Created/Modified

**Created (13):**

- `tool/osm_pipeline/lib/admin/admin_relation_filter.dart` — `isAdminRelation()`, `kTargetAdminLevels`, `kCityStateNames`
- `tool/osm_pipeline/lib/admin/geometry.dart` — Point / Polygon / MultiPolygon value types; shoelace-area, point-in-ring, O(N²) self-intersection detection, in-place reverse, bbox()
- `tool/osm_pipeline/lib/admin/multipolygon_assembler.dart` — `MultipolygonAssembler.assemble()` static entrypoint + private fragment stitcher
- `tool/osm_pipeline/lib/admin/wkb_writer.dart` — `encodeMultiPolygon(mp) → Uint8List` OGC WKB flat variant
- `tool/osm_pipeline/lib/admin/admin_pipeline.dart` — `extractAdminRegions()` 3-pass streaming Stage C, dual-write logic, `AdminExtractionSummary`
- `tool/osm_pipeline/lib/scratch/admin_scratch_schema.dart` — `kAdminScratchSchema` CREATE statements (admin_regions_raw + level index)
- `tool/osm_pipeline/lib/scratch/scratch_db_admin_ext.dart` — `AdminScratchWriter` interface, `InMemoryAdminScratchWriter`, `AdminRegionRow`, `ScratchDbAdminWriter` (over `ScratchDb.raw`)
- `tool/osm_pipeline/test/admin/admin_relation_filter_test.dart` — 15 filter tests
- `tool/osm_pipeline/test/admin/multipolygon_assembler_test.dart` — 10 tests (assembler + geometry helpers)
- `tool/osm_pipeline/test/admin/wkb_writer_test.dart` — 5 tests
- `tool/osm_pipeline/test/admin/admin_pipeline_test.dart` — 5 tests (tiny-fixture end-to-end)
- `tool/osm_pipeline/test/admin/scratch_db_admin_ext_test.dart` — 4 tests (real sqlite3 round-trip)
- `tool/osm_pipeline/test/admin/city_state_dual_write_test.dart` — 5 tests (pitfall #10 branch)

**Modified (1):**

- `tool/osm_pipeline/bin/osm_pipeline.dart` — inserted Stage C between Stage B (highway filter) and the D/E stubs. Added imports for `admin_pipeline.dart` + `scratch_db_admin_ext.dart`. Uses `ScratchDbAdminWriter(scratch)` and disposes it in a try/finally.

## Decisions Made

Key highlights:

- **Filter widens to `type in {boundary, multipolygon}` with `boundary=administrative`.** OSM tagging is empirically inconsistent in DE; many Landkreise carry `type=multipolygon` despite the wiki recommending `type=boundary`. Rejecting them would drop real admin boundaries with no downstream benefit. Documented in `admin_relation_filter.dart` inline.
- **City-state dual-write is name-driven, not relation-id-driven.** `kCityStateNames = {'Berlin', 'Hamburg', 'Bremen'}`; the extractor writes level-4 city-state relations a SECOND time at level 6. Name lookups survive OSM ID churn; relation-id lookups do not.
- **`AdminScratchWriter` abstract interface + two impls.** `InMemoryAdminScratchWriter` for hermetic tests; `ScratchDbAdminWriter` for prod (thin adapter over 04-03's `ScratchDb.raw`). Zero modification to `scratch_db.dart` / `scratch_schema.dart` — parallel-wave lane discipline preserved.
- **`admin_scratch_schema.dart` in its own file.** Doesn't merge into 04-03's `scratch_schema.dart`. 04-06 orchestrator will apply both schema lists at scratch-open time; the wiring point is a small change 04-06 owns.
- **Point.equalsCoord() helper instead of == override.** `meta` is a transitive dep — importing `@immutable` trips `depend_on_referenced_packages`. Rather than promote `meta` to direct, we use a plain instance method for endpoint-match checks. Callsites: `MultipolygonAssembler._stitchRings` only.
- **WKB flat variant (OGC), no SRID/EWKB prefix.** We live in EPSG:4326 exclusively; SQLite/SpatiaLite can carry the CRS at the table level. Simpler encoder, one fewer field for the reader to skip.
- **O(N²) self-intersection.** Acceptable for admin rings (thousands of vertices — assembly runs in seconds). Sweep-line replacement deferred to a follow-up if `admin_level=10` Ortsteil rings ever exceed 100k vertices (unlikely; documented in 04-04-PLAN.md Deviation Handling).
- **Three-pass streaming Stage C.** Clarity over throughput. 04-06 may fold passes with 04-03's Stage-B stream. Documented in `admin_pipeline.dart` file-level doc.
- **Nameless relations rejected.** `name` is a required column on `admin_regions_raw` — downstream focus-area lookups display `name`. Nameless admin relations occur rarely and add no user-visible value; log + drop.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Admin filter would reject the tiny fixture relation**

- **Found during:** Task 1 first-cut (following the plan sketch literally)
- **Issue:** The plan sketched `if (r.tags['type'] != 'boundary') return false;` — literal interpretation would reject the tiny fixture relation, which is tagged `type=multipolygon` (matching real-world DE Landkreise). The plan's Deviation Handling section explicitly anticipates this: "If a real Landkreis in the Berlin PBF turns out to use `type=multipolygon` and gets rejected, the filter check will need widening in 04-05 or 04-09".
- **Fix:** Widened the filter to accept `type in {boundary, multipolygon}` with `boundary=administrative` from the start. The fixture smoke path passes, and downstream 04-05/04-09 are not blocked. Rationale documented inline; explicit test case covers each of the four (type × boundary) permutations.
- **Files:** `lib/admin/admin_relation_filter.dart`, `test/admin/admin_relation_filter_test.dart`
- **Committed in:** `1e735e9` (Task 1)

**2. [Rule 2 - Missing Critical] AdminScratchWriter interface + parallel-wave coordination**

- **Found during:** Task 1 (reading 04-03's ScratchDb after it landed mid-execution)
- **Issue:** The plan mid-flight noted "if 04-03's `ScratchDb` doesn't expose a way to run arbitrary CREATE statements, escalate to the user". 04-03 landed while I was working; it exposes `ScratchDb.raw` (a public `Database` getter). Rather than write directly against it (which would tightly couple 04-04 to 04-03's public surface), I introduced an `AdminScratchWriter` abstract interface with `InMemoryAdminScratchWriter` (tests) + `ScratchDbAdminWriter` (real prod path using `ScratchDb.raw`). This isolates the extraction stage from the collaborator's concrete type and keeps tests hermetic.
- **Fix:** Ship the interface + two impls together in Task 1. The extraction stage takes `AdminScratchWriter` (never `ScratchDb`); tests never open a real sqlite handle; prod path is a 30-LOC adapter class.
- **Files:** `lib/scratch/scratch_db_admin_ext.dart` (both Task 1 initial ship + Task 3 sqlite adapter addition)
- **Committed in:** `1e735e9` (Task 1 — interface + in-memory), `12f76db` (Task 3 — sqlite adapter)

**3. [Rule 2 - Missing Critical] `avoid_equals_and_hash_code_on_mutable_classes` on `Point`**

- **Found during:** Task 2 first analyze
- **Issue:** First-cut `Point` had `==` / `hashCode` overrides for the fragment stitcher's endpoint-match check. `very_good_analysis` flagged both because `Point` isn't `@immutable`. Promoting `meta` from transitive to direct dep would trip `depend_on_referenced_packages` at the pipeline analyzer level.
- **Fix:** Replaced `==` with an instance method `equalsCoord(Point)`. Two callsites updated. Zero pubspec churn.
- **Files:** `lib/admin/geometry.dart`, `lib/admin/multipolygon_assembler.dart`, `test/admin/multipolygon_assembler_test.dart`
- **Committed in:** `61f4e61` (Task 2)

**4. [Rule 2 - Missing Critical] Analyzer info-level lints across new admin/ + scratch/ files**

- **Found during:** Tasks 2 + 3 first analyze passes
- **Issue:** `very_good_analysis` fired on `require_trailing_commas`, `prefer_const_constructors`, `prefer_int_literals`, `prefer_single_quotes`, `cascade_invocations`, `unnecessary_const`. Pre-push runs `flutter analyze --fatal-infos`, so info-level would block push.
- **Fix:** `dart fix --apply` twice (once per task) resolved most; hand-fixed `cascade_invocations` in `ScratchDbAdminWriter.insertAdminRegion` (used a null-coalesced-assignment inline cascade) and the `dispose()` shape.
- **Files:** `lib/admin/geometry.dart`, `lib/scratch/scratch_db_admin_ext.dart`, all Task 2/3 test files.
- **Committed in:** `61f4e61`, `12f76db`.

---

**Total deviations:** 4 auto-fixed (2 bug/spec-widening, 2 lint hygiene). No architectural changes; no scope creep.

## Wave-3 Parallel-Execution Notes

- **04-03 landed mid-execution.** Its ScratchDb exposes `Database get raw` — sufficient for 04-04 to build `ScratchDbAdminWriter` without touching any 04-03-owned file.
- **STATE.md conflict resolved.** After Task 2 commit, 04-03's SUMMARY commit had already updated STATE.md forward. My stale working copy still held the pre-04-03 version. Discarded via `git checkout .planning/STATE.md`; no data lost — 04-03's decisions remain committed.
- **04-03's flutter-analyze findings NOT touched.** 6 info-level warnings in 04-03's `lib/filter/way_pipeline.dart` + `test/filter/*_test.dart` are visible at repo root but out of 04-04's lane. Those are 04-03's to sweep.
- **Every commit staged files individually.** No `git add .`, no `git add -A`.
- **`bin/osm_pipeline.dart` edit was surgical.** Added imports for admin_pipeline + scratch_db_admin_ext; inserted Stage C between Stage B and the D/E stubs; wrapped writer in try/finally for `dispose()`. No touching of Stage B code (04-03 lane).

## Authentication Gates

None — no external services touched.

## User Setup Required

None — no external tooling. `sqlite3` package prebuilt binaries carried over from 04-03. `tippecanoe` (Stage D/04-07) prereq unchanged.

## Next Phase Readiness

**Ready:**

- Plan 04-05 (segmented intersection) can join `admin_regions_raw.geometry_wkb` against Kfz ways written by 04-03. Both stages now populate the same scratch DB; 04-05 wires the join.
- Plan 04-06 (osm.sqlite promotion) reads `admin_regions_raw` and promotes rows to `admin_regions` + `admin_regions_rtree` in the final DB. Interface shape and column order match 04-RESEARCH §6 verbatim.
- Plan 04-07 (pmtiles authoring) reads `admin_regions_raw.geometry_wkb`, converts to GeoJSON per admin_level, feeds `tippecanoe`.
- Plan 04-08 (metadata sanity) can check `SELECT COUNT(*) FROM admin_regions_raw` against a per-level expected floor.
- Full-Germany run (04-09/04-10) is prerequisite-clean: the assembler + WKB encoder handle multipolygon inner rings, missing refs, self-intersections, and city-state dual-writes.

**Blockers / concerns:**

- **Passes B+C re-open the PBF** per stage. Full-Germany PBFs are ~4 GB; three sequential reads on a spinning disk would be painful. On the target SSD dev box, still fine. 04-06 orchestrator may fold passes with 04-03's Stage-B stream to eliminate reopens.
- **`skipped.log` is opened by admin_pipeline; 04-03 also owns a `skipped.log` path.** 04-06 orchestrator picks the shared log location. Presently the CLI does not thread a skipped-log path through Stage C — tests exercise it, prod runs without. 04-06 concern to close.
- **Berlin/Hamburg/Bremen tiny fixture coverage.** Dual-write branch is exercised at unit level (5 tests) but the tiny fixture relation is `Testgemeinde` (level 8), so end-to-end dual-write doesn't run against the fixture. Not blocking; branch is covered by targeted tests + the CLI Stage C path is proven.

---
*Phase: 04-osm-pipeline*
*Completed: 2026-07-05*
