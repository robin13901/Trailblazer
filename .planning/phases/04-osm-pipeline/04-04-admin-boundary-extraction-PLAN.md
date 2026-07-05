---
id: 04-04
phase: 04-osm-pipeline
plan: 04
type: execute
wave: 3
depends_on: [04-02]
files_modified:
  - tool/osm_pipeline/pubspec.yaml
  - tool/osm_pipeline/lib/admin/admin_relation_filter.dart
  - tool/osm_pipeline/lib/admin/multipolygon_assembler.dart
  - tool/osm_pipeline/lib/admin/wkb_writer.dart
  - tool/osm_pipeline/lib/admin/admin_pipeline.dart
  - tool/osm_pipeline/lib/scratch/admin_scratch_schema.dart
  - tool/osm_pipeline/lib/scratch/scratch_db_admin_ext.dart
  - tool/osm_pipeline/test/admin/admin_relation_filter_test.dart
  - tool/osm_pipeline/test/admin/multipolygon_assembler_test.dart
  - tool/osm_pipeline/test/admin/wkb_writer_test.dart
autonomous: true
requirements: [OSM-03]

must_haves:
  truths:
    - "Admin relation filter accepts only type=boundary + boundary=administrative + admin_level IN (2,4,6,8,9,10); every other relation is skipped"
    - "Multipolygon assembler stitches outer + inner member ways into a Multi-Polygon with correct winding (outer CCW, inner CW) and subtraction; self-intersecting rings are skipped and logged (04-RESEARCH §12 pitfall #5)"
    - "Berlin/Hamburg/Bremen (city-states) are written TWICE in admin_regions — once at admin_level=4 and once at admin_level=6 (04-RESEARCH §12 pitfall #10) — the pipeline logs a debug line each time"
    - "WKB (Well-Known Binary, EWKB with SRID=4326 flag off — plain WKB is enough for our uses) serialization is deterministic: ring point order preserved, byte-identical output for identical input polygons"
    - "Multipolygon relations with missing member ways (deleted-node cascade, 04-RESEARCH §12 pitfall #4) skip the ring, log to skipped.log with relation id + missing way id, and continue"
    - "admin_regions_raw scratch table populated with (region_id, osm_relation_id, admin_level, name, geometry_wkb, bbox_minlat/maxlat/minlng/maxlng) — CREATE statement lives in admin_scratch_schema.dart, NOT in scratch_schema.dart (see file-ownership note below)"
  artifacts:
    - path: "tool/osm_pipeline/lib/admin/admin_relation_filter.dart"
      provides: "isAdminRelation(OsmRelation) predicate"
    - path: "tool/osm_pipeline/lib/admin/multipolygon_assembler.dart"
      provides: "assembleMultipolygon(members, waysById, nodesById) → MultiPolygon"
    - path: "tool/osm_pipeline/lib/admin/wkb_writer.dart"
      provides: "encodeMultiPolygon(mp) → Uint8List (well-known binary)"
    - path: "tool/osm_pipeline/lib/scratch/admin_scratch_schema.dart"
      provides: "CREATE statements for admin_regions_raw — separate file to avoid parallel-wave conflict with 04-03"
  key_links:
    - from: "tool/osm_pipeline/lib/admin/admin_pipeline.dart"
      to: "tool/osm_pipeline/lib/scratch/scratch_db_admin_ext.dart"
      via: "extension on ScratchDb adds insertAdminRegion(...) without touching 04-03's scratch_db.dart"
      pattern: "insertAdminRegion"
    - from: "tool/osm_pipeline/lib/admin/multipolygon_assembler.dart"
      to: "tool/osm_pipeline/lib/pbf/entities.dart"
      via: "consumes OsmWay + OsmNode + RelationMember types"
      pattern: "OsmRelation"
---

## File-ownership note (parallel execution safety)

04-03 and 04-04 both run in Wave 3. To avoid a parallel-write conflict on `scratch_schema.dart` and `scratch_db.dart`, this plan owns TWO separate files that its code adds on top:

- **`tool/osm_pipeline/lib/scratch/admin_scratch_schema.dart`** — houses the `admin_regions_raw` CREATE statements + index.
- **`tool/osm_pipeline/lib/scratch/scratch_db_admin_ext.dart`** — Dart extension on `ScratchDb` (from 04-03) adding `insertAdminRegion(...)`. At `ScratchDb.openTempFile()` call time, both `scratch_schema.dart` and `admin_scratch_schema.dart` CREATE statements are applied — the wiring is a small change in `pipeline_orchestrator.dart` (owned by 04-06) which imports and applies both.

Neither file exists yet after 04-03 runs — 04-04 creates them fresh. 04-06 imports both and applies the combined schema when opening the scratch DB.

## Goal

Extract admin boundary relations at OSM levels 2/4/6/8/9/10, assemble their multipolygon geometries, and write them to the scratch DB as WKB — so plan 04-05 can run segmented intersection against them.

## Context

- 04-CONTEXT.md decision: admin polygons stored in BOTH osm.sqlite AND pmtiles. This plan owns the scratch-side write; 04-06 promotes it to the final osm.sqlite; 04-07 emits the pmtiles version.
- 04-RESEARCH §6 fixes the target schema: `admin_regions(region_id, osm_relation_id, admin_level, name, geometry_wkb BLOB, bbox_*)` + `admin_regions_rtree(id, min_lat, max_lat, min_lng, max_lng)`. This plan writes the raw variant to scratch; 04-06 copies it to the final DB.
- 04-RESEARCH §12 pitfalls to codify HERE:
  - #1 admin multipolygon inner rings (Bremen enclave, Berlin's Kladower Forst) — subtract inner from outer, not skip.
  - #5 self-intersecting rings — detect via ring-orientation check + point-crossing count; skip and log.
  - #10 Berlin/Hamburg/Bremen are Bundesland AND Gemeinde in one entity — write them under BOTH admin_level=4 and admin_level=6.
- Runs on the same `PbfReader.stream(pbf)` output as 04-03 — this plan is a separate PARALLEL consumer. The orchestrator (final 04-06 or 04-05) will decide whether both stages share a single stream pass or make two — for now, each stage is a self-contained function.
- No external geometry library. Pure-Dart small algorithms; the surface we need is: ring assembly + WKB serialization + bbox computation. All < 300 LOC total.

## Tasks

<task type="auto">
  <name>Task 1: Admin relation filter + scratch schema addition</name>
  <files>
    tool/osm_pipeline/lib/admin/admin_relation_filter.dart
    tool/osm_pipeline/lib/scratch/admin_scratch_schema.dart
    tool/osm_pipeline/lib/scratch/scratch_db_admin_ext.dart
  </files>
  <intent>Filter for OSM relations that are administrative boundaries at our target levels + add admin-specific scratch schema in files this plan owns exclusively.</intent>
  <action>
    **`admin_relation_filter.dart`**:
    ```dart
    const Set<int> kTargetAdminLevels = {2, 4, 6, 8, 9, 10};

    bool isAdminRelation(OsmRelation r) {
      if (r.tags['type'] != 'boundary') return false;
      if (r.tags['boundary'] != 'administrative') return false;
      final lvl = int.tryParse(r.tags['admin_level'] ?? '');
      if (lvl == null) return false;
      return kTargetAdminLevels.contains(lvl);
    }

    /// City-states that appear as both Bundesland (level=4) and
    /// Gemeinde (level=6) in one entity. 04-RESEARCH §12 pitfall #10.
    /// Match by name (stable across OSM revisions).
    const Set<String> kCityStateNames = {'Berlin', 'Hamburg', 'Bremen'};
    ```

    **`admin_scratch_schema.dart`** — CREATE statements:
    ```dart
    /// SQL CREATE statements for admin-region scratch tables.
    /// Applied by ScratchDb.openTempFile() alongside the base scratch_schema.dart
    /// (owned by 04-03). Kept in a separate file so 04-03 and 04-04 can execute
    /// in parallel without touching the same file.
    const List<String> kAdminScratchSchema = [
      '''
      CREATE TABLE admin_regions_raw (
        region_id       INTEGER PRIMARY KEY,
        osm_relation_id INTEGER NOT NULL,
        admin_level     INTEGER NOT NULL,
        name            TEXT NOT NULL,
        geometry_wkb    BLOB NOT NULL,
        bbox_minlat     REAL NOT NULL,
        bbox_maxlat     REAL NOT NULL,
        bbox_minlng     REAL NOT NULL,
        bbox_maxlng     REAL NOT NULL
      );
      ''',
      'CREATE INDEX idx_admin_regions_raw_level ON admin_regions_raw(admin_level);',
    ];
    ```

    **`scratch_db_admin_ext.dart`** — Dart extension methods on `ScratchDb`:
    ```dart
    extension ScratchDbAdmin on ScratchDb {
      /// Applies CREATE statements from admin_scratch_schema.dart.
      /// Called by the pipeline orchestrator once, right after openTempFile().
      void applyAdminSchema() {
        for (final stmt in kAdminScratchSchema) {
          rawDb.execute(stmt);
        }
      }

      Future<void> insertAdminRegion({
        required int regionId,
        required int osmRelationId,
        required int adminLevel,
        required String name,
        required Uint8List geometryWkb,
        required double bboxMinLat, required double bboxMaxLat,
        required double bboxMinLng, required double bboxMaxLng,
      }) async { /* prepared-statement INSERT */ }
    }
    ```

    NOTE: The extension needs access to the underlying sqlite3 database handle. 04-03's `ScratchDb` should expose a `rawDb` getter or similar — coordinate the API by checking `scratch_db.dart` at task-start time and using whatever public surface 04-03 provided. If 04-03 chose to make the sqlite handle private, this task creates a public accessor as a same-file (04-04-owned) doesn't work — coordinate by adding the accessor as part of THIS plan's edit to a co-authored `scratch_db_api.dart` if needed; the simpler resolution is: 04-03 exposes `Database get rawDb` on `ScratchDb`. Since 04-03 also runs in Wave 3, mention this as a coordination point in that plan's executor SUMMARY.

    (**Executor coordination note:** at the start of 04-04's execution, if 04-03 has already been completed and did NOT expose `rawDb`, add that getter in `scratch_db_admin_ext.dart` via a workaround — pass the raw sqlite Database into `insertAdminRegion` explicitly. Do not modify `scratch_db.dart` in this plan — that would recreate the parallel-write conflict this plan structure is designed to avoid.)
  </action>
  <verify>
    `flutter analyze` clean.
    `dart test tool/osm_pipeline/test/admin/admin_relation_filter_test.dart` — new tests pass (see task 3 below for the test list).
    `admin_scratch_schema.dart` and `scratch_db_admin_ext.dart` do NOT modify any file owned by 04-03.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Multipolygon assembler + WKB writer</name>
  <files>
    tool/osm_pipeline/lib/admin/multipolygon_assembler.dart
    tool/osm_pipeline/lib/admin/wkb_writer.dart
  </files>
  <intent>Turn an OsmRelation + its member ways into a valid multipolygon; encode as WKB.</intent>
  <action>
    **`multipolygon_assembler.dart`** — algorithm:

    1. Partition `relation.members` into `outerWayIds` and `innerWayIds` by role (`role == 'outer'` or empty-role defaults to outer per OSM convention; `role == 'inner'` is inner). Anything else, ignore.

    2. For each role's way list, resolve refs via `waysById[wayId]`. If missing (deleted-node cascade), log to skipped.log and skip the ring — do NOT fail the whole relation.

    3. **Stitch open ways into closed rings.** Multipolygon relations often provide fragment ways that share endpoints (way A ends at node X, way B starts at node X). Repeat:
       - Take an unused fragment; walk forward: at each end-node, find another unused fragment starting or ending there; append (reverse if needed) until the ring closes.
       - If no matching fragment exists mid-walk, the ring is broken; log and skip that ring.
    4. Resolve each ring's node IDs to lat/lng via `nodesById`. If any node missing, skip the ring.
    5. Compute ring orientation (shoelace-sign): outer rings should be CCW, inner should be CW. Reverse in place if wrong.
    6. Detect self-intersection: simplest sufficient check is to test whether any non-adjacent segment of the ring crosses any other — O(N²). For the ~thousands-of-vertices admin rings we care about, N² is acceptable in offline dev time; the whole assembly runs in seconds, not minutes. If crossing found, log and skip the ring (04-RESEARCH §12 pitfall #5).
    7. Bucket outer rings and inner rings. Each inner ring is subtracted from the outer ring that CONTAINS it (point-in-polygon test using ANY point of the inner). Inners that don't lie inside any outer are logged and dropped.
    8. Emit a `MultiPolygon` value class: `List<Polygon>` where each `Polygon` is `{outer: List<Point>, holes: List<List<Point>>}`.

    The full assembler is ~250 LOC in Dart with plain lists. Do NOT pull in `dart_jts` or `spatially`.

    **`wkb_writer.dart`** — Well-Known Binary encoder for `MultiPolygon`:
    - Byte-order flag = 1 (little-endian).
    - MultiPolygon type = 6.
    - Little-endian uint32 num_polygons.
    - For each polygon: Polygon type = 3, uint32 num_rings, then per ring: uint32 num_points, then num_points × (double lng, double lat).
    - Fixed 21 + 4 + Σ(polygon_size) bytes; can be computed exactly for bbox-sanity assertions.
    - Reference: [OGC 06-103r4 §8.2.7](https://portal.ogc.org/files/?artifact_id=25355) — implement only the flat WKB variant, no SRID prefix (EWKB) needed since we're single-CRS (EPSG:4326).

    Add a `bbox()` helper to `MultiPolygon` — returns `(minLat, maxLat, minLng, maxLng)` from a single pass over all points; used to populate the scratch row's bbox columns.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/admin/multipolygon_assembler_test.dart test/admin/wkb_writer_test.dart` — all green.
    Round-trip WKB: encode → decode with a reference tool (e.g. `sqlite3` with SpatiaLite loaded, if easy on Windows; else compare byte-for-byte against a precomputed hex string in the test).
  </verify>
</task>

<task type="auto">
  <name>Task 3: admin_pipeline orchestrator + comprehensive tests</name>
  <files>
    tool/osm_pipeline/lib/admin/admin_pipeline.dart
    tool/osm_pipeline/test/admin/admin_relation_filter_test.dart
    tool/osm_pipeline/test/admin/multipolygon_assembler_test.dart
    tool/osm_pipeline/test/admin/wkb_writer_test.dart
  </files>
  <intent>End-to-end admin extractor that consumes PbfReader output and writes admin_regions_raw; tests hit all 04-RESEARCH §12 pitfalls listed for this plan.</intent>
  <action>
    **`admin_pipeline.dart`** — public function:
    ```dart
    Future<int> extractAdminRegions({
      required File pbf,
      required ScratchDb scratch,
      required File skippedLog,
    }) async {
      // Pass A: collect admin RELATIONS (with their member way refs) — RAM-bound.
      final admins = <OsmRelation>[];
      final relevantWayIds = <int>{};
      final relevantNodeIds = <int>{};

      await for (final e in PbfReader().stream(pbf)) {
        if (e is OsmRelation && isAdminRelation(e)) {
          admins.add(e);
          for (final m in e.members) {
            if (m.type == 'way') relevantWayIds.add(m.refId);
          }
        }
      }

      // Pass B: collect the member ways referenced by admin relations.
      final waysById = <int, OsmWay>{};
      await for (final e in PbfReader().stream(pbf)) {
        if (e is OsmWay && relevantWayIds.contains(e.id)) {
          waysById[e.id] = e;
          relevantNodeIds.addAll(e.nodeRefs);
        }
      }

      // Pass C: collect nodes referenced by admin ways.
      final nodesById = <int, ({double lat, double lng})>{};
      await for (final e in PbfReader().stream(pbf)) {
        if (e is OsmNode && relevantNodeIds.contains(e.id)) {
          nodesById[e.id] = (lat: e.lat, lng: e.lng);
        }
      }

      // Pass D: assemble + write.
      var regionId = 0;
      for (final rel in admins) {
        try {
          final mp = MultipolygonAssembler.assemble(rel, waysById, nodesById, skippedLog);
          if (mp == null || mp.isEmpty) continue;

          final lvl = int.parse(rel.tags['admin_level']!);
          final name = rel.tags['name'] ?? '';
          if (name.isEmpty) continue;   // nameless regions are useless downstream

          await _write(scratch, ++regionId, rel.id, lvl, name, mp);

          // Pitfall #10: Berlin/Hamburg/Bremen dual-write at level 6.
          if (lvl == 4 && kCityStateNames.contains(name)) {
            await _write(scratch, ++regionId, rel.id, 6, name, mp);
            _log(skippedLog, 'INFO dual-write city-state ${rel.id} $name at level 6');
          }
        } on Object catch (err, st) {
          _log(skippedLog, 'ERR relation ${rel.id} assembly: $err');
        }
      }
      return regionId;
    }
    ```

    Three-pass streaming means 3× the PBF read cost — acceptable at this stage; 04-05/06 may combine passes with 04-03's stream into one. This plan optimizes for clarity, not throughput.

    **`admin_relation_filter_test.dart`** — parameterize over:
    - type=boundary + boundary=administrative + admin_level=2 → accept.
    - Same but admin_level=3 (Regierungsbezirk, we don't want) → reject.
    - Same but admin_level=11 → reject.
    - type=multipolygon (natural=water, not administrative) → reject.
    - type=boundary + boundary=maritime → reject.
    - admin_level=8 but type=multipolygon (some Landkreise use this) → reject.  *(Note: OSM tagging is inconsistent here; document that we require BOTH type=boundary AND boundary=administrative. If Berlin smoke shows missing common Landkreise, relax to `type IN (boundary, multipolygon)` + boundary=administrative — but 04-05's smoke will surface that empirically.)*

    **`multipolygon_assembler_test.dart`**:
    - Single closed way as outer ring → produces 1-polygon MultiPolygon.
    - Two open fragment ways sharing endpoints → stitched into 1 closed ring.
    - Outer + one inner ring (enclave) → MultiPolygon with hole.
    - Missing member way (relation refs way 999 not in `waysById`) → logs to skippedLog, skips ring, does NOT throw.
    - Self-intersecting ring (deliberately crafted) → logged as pitfall #5, skipped.
    - Wrong winding: outer given as CW → reversed to CCW in output.
    - Inner ring not inside any outer → logged, dropped.

    **`wkb_writer_test.dart`**:
    - Encode a known unit square (0,0)→(1,0)→(1,1)→(0,1)→(0,0) → byte hash matches the hand-computed expected value.
    - Round-trip: encode + immediately decode (a small decoder in the test file) → identical polygons.
    - MultiPolygon with two disjoint polygons → correct `num_polygons=2` header.

    Run: `cd tool/osm_pipeline && dart test`.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/admin/` — all green.
    `flutter analyze` clean.
    Manual smoke: `dart run tool/osm_pipeline/bin/osm_pipeline.dart --pbf=tool/osm_pipeline/test/fixtures/tiny.osm.pbf` — CLI now reports "1 admin region extracted at level=8, name=Testgemeinde" (plus 0 dual-write since Testgemeinde is not a city-state).
  </verify>
</task>

## Verification

- All `test/admin/**` tests green.
- `flutter analyze` clean at repo root.
- Running the CLI on `tiny.osm.pbf` produces exactly 1 admin_regions_raw row (relation 1, level 8, name Testgemeinde) with a valid WKB blob whose ring count is 2 (outer + inner enclave).
- The `skipped.log` file exists (possibly empty).
- 04-04 did NOT modify `tool/osm_pipeline/lib/scratch/scratch_schema.dart` or `tool/osm_pipeline/lib/scratch/scratch_db.dart` (both owned by 04-03). Verified via `git diff --name-only` after execution.

## Deviation Handling

- If a real Landkreis in the Berlin PBF turns out to use `type=multipolygon` (not `type=boundary`) and gets rejected, the filter check will need widening in 04-05 or 04-09 — do NOT preemptively widen; wait for empirical evidence.
- The O(N²) self-intersection check is fine for ~thousands-of-vertex admin rings but not for degenerate rings with 100k+ vertices. If Berlin admin_level=10 rings are ever that large (unlikely — Ortsteil polygons are typically simple), replace with sweep-line in a follow-up.
- Multipolygon assembly is one of the most complex algorithms in Phase 4. If the executor gets stuck > 3 iterations on task 2, escalate to the user for a targeted design review — do NOT try to fake it with sqlite/PostGIS FFI (that's the wrong dep for a Dart-only pipeline).
- If 04-03's `ScratchDb` doesn't expose a way to run arbitrary CREATE statements (e.g. no public `applyExtraSchema` method): this is a coordination bug. Escalate to the user before duplicating scratch_db code in 04-04. The proper fix is a small 04-03 amendment.
- Iterate up to 3 times per task; if blocked, report failing test output verbatim.
