---
id: 04-05
phase: 04-osm-pipeline
plan: 05
type: execute
wave: 4
depends_on: [04-03, 04-04]
files_modified:
  - tool/osm_pipeline/lib/intersect/vec2.dart
  - tool/osm_pipeline/lib/intersect/polygon_clip.dart
  - tool/osm_pipeline/lib/intersect/way_admin_join.dart
  - tool/osm_pipeline/lib/scratch/scratch_schema.dart
  - tool/osm_pipeline/lib/measure/berlin_row_count_probe.dart
  - tool/osm_pipeline/bin/measure_berlin_row_count.dart
  - tool/osm_pipeline/test/intersect/polygon_clip_test.dart
  - tool/osm_pipeline/test/intersect/way_admin_join_test.dart
autonomous: false
requirements: [OSM-04]

must_haves:
  truths:
    - "Berlin-bbox row-count probe measures actual Kfz-way count, actual admin-region count per level, actual cross-border way ratio, and produces a schema-choice recommendation (denormalized-on-ways vs join-table-only) BEFORE the schema is locked"
    - "clip_linestring_to_polygon returns a list of connected sub-linestrings representing where the input line lies inside the polygon; handles enter/exit/re-enter, coincident-edge tie-break (left-of-line), and epsilon-clip (segments < 1 m dropped)"
    - "For every Kfz way that intersects any admin region at levels 2/4/6/8/9/10, the pipeline writes exactly one way_admin_raw row per (way_id, region_id, level) pair; a way that enters/exits/re-enters produces multiple rows"
    - "Multipolygon admin regions (outer + inner enclaves) are handled correctly — the inner ring is a SUBTRACTED hole, not an independent region"
    - "way_admin_raw carries the fraction_start and fraction_end columns (double in [0,1]) representing where along the way each sub-segment starts and ends — enables Phase 8 coverage math without storing sub-geometries"
    - "way_admin_raw contains one row per (way_id, region_id, admin_level, fraction_start, fraction_end) for every cross-border sub-segment, including sub-segments produced by enter/exit/re-enter and multipolygon-with-hole cases (denormalization roll-up onto the ways table is 04-06's responsibility)"
  artifacts:
    - path: "tool/osm_pipeline/lib/intersect/polygon_clip.dart"
      provides: "clip_linestring_to_polygon(line, polygon) → List<Subsegment>"
    - path: "tool/osm_pipeline/lib/measure/berlin_row_count_probe.dart"
      provides: "Diagnostic tool: prints row-count projections + a schema-locking recommendation from a Berlin-bbox scratch DB"
    - path: "tool/osm_pipeline/lib/intersect/way_admin_join.dart"
      provides: "buildWayAdminJoin(scratch) — iterates ways × admin regions and populates way_admin_raw"
  key_links:
    - from: "tool/osm_pipeline/lib/intersect/way_admin_join.dart"
      to: "tool/osm_pipeline/lib/scratch/scratch_db.dart"
      via: "reads ways_raw + admin_regions_raw, writes way_admin_raw"
      pattern: "INSERT INTO way_admin_raw"
    - from: "tool/osm_pipeline/bin/measure_berlin_row_count.dart"
      to: "tool/osm_pipeline/lib/measure/berlin_row_count_probe.dart"
      via: "prints diagnostic report + writes .planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md"
      pattern: "printRecommendation"
---

## Goal

Precede any schema-locking task with a **Berlin-bbox row-count measurement** (04-RESEARCH.md §7 planner note), then implement segmented intersection to populate the `way_admin` join. The measurement's output determines whether the denormalized ways.admin_region_id_L{2,4,6,8,9,10} strategy fits the 200 MB budget or whether we fall back to a join-table-only variant.

## Context

- 04-RESEARCH.md §7 spells out the algorithm (Sutherland-Hodgman variant for linestring-vs-polygon clipping) and the correctness pitfalls (enter/exit/re-enter, coincident-edge tie-break, epsilon-clip at 1 m).
- 04-RESEARCH.md §7 "final strategy" recommendation: denormalized `admin_region_id_L{2,4,6,8,9,10}` on `ways` for wholly-contained ways + `way_admin_raw` for cross-border ways. But this is guarded on "actual Kfz way count for Germany is ~4M, not 40M" — **an empirical claim that must be verified on Berlin before locking**.
- 04-RESEARCH.md §7 states explicitly: "Do NOT lock a schema before running the Berlin-bbox smoke and scaling. The plan should include an early 'measure Berlin-bbox row count and extrapolate' task before committing schema."
- Fallback: if Berlin measurement projects > 150 MB for the denormalized columns, DROP the level 9 and level 10 columns (Stadtteil/Ortsteil) and require a runtime spatial lookup for those two levels — 04-RESEARCH §7 escape hatch.
- This plan is a Wave 4 blocker for 04-06 (which owns the final osm.sqlite schema). 04-06 reads the recommendation from `04-05-BERLIN-MEASUREMENT.md` and picks columns accordingly. 04-06's Deviation Handling documents a HARD gate: if the measurement file is missing or marked "not empirically verified", 04-06 refuses to execute.
- Berlin fixture: NO commit of a real Berlin PBF (60 MB, too big — 04-RESEARCH §11). The probe task expects the user to point at a local Berlin PBF via env var / CLI arg. Because the schema-lock in 04-06 depends on this measurement, this plan is `autonomous: false` — Task 3 is a checkpoint that requires the user to supply the Berlin PBF and confirm the measurement result before Task 4 runs.

## Tasks

<task type="auto">
  <name>Task 1: Vec2 primitives + linestring-polygon clipper</name>
  <files>
    tool/osm_pipeline/lib/intersect/vec2.dart
    tool/osm_pipeline/lib/intersect/polygon_clip.dart
    tool/osm_pipeline/test/intersect/polygon_clip_test.dart
  </files>
  <intent>The geometric core — clip a linestring by a polygon, return the inside-sub-linestrings with fractional along-way positions.</intent>
  <action>
    **`vec2.dart`** — plain 2D primitives, no dep. `class Vec2 { double lng, lat; }` + `segmentIntersection(a1, a2, b1, b2) → Vec2?` (returns the intersection point or null; handles collinear + touching-endpoint cases) + `pointInPolygon(p, ring) → bool` (crossing-number test with epsilon).

    Coordinates are lat/lng doubles. Distances for the epsilon-clip use the haversine formula in a `haversineMeters(a, b)` helper — sub-metre precision at latitude 51°N is fine at REAL doubles.

    **`polygon_clip.dart`** — the clipper:
    ```dart
    class Subsegment {
      final List<Vec2> points;
      final double fractionStart;   // 0..1 along the source way
      final double fractionEnd;     // 0..1 along the source way
    }

    /// Clip [line] against [polygon] (outer ring + optional inner rings).
    /// Returns disjoint sub-linestrings where the line is INSIDE the polygon
    /// (outer minus inners). Sub-segments shorter than [epsilonMeters]=1 are
    /// dropped. Ties (line coincident with polygon edge) resolve as "line is
    /// on the LEFT side" — deterministic tie-break per 04-RESEARCH §7.
    List<Subsegment> clipLinestringToPolygon(
      List<Vec2> line,
      MultiPolygon polygon, {
      double epsilonMeters = 1.0,
    }) { ... }
    ```

    Algorithm outline:
    1. Compute total length of `line` in meters (haversine sum). This anchors the fraction_start / fraction_end computation.
    2. Walk `line` segment by segment. For each segment:
       - Determine whether each endpoint is inside/outside/on-boundary of the polygon.
       - Compute all intersections with the polygon's edges (outer + inners).
       - Emit sub-segments accordingly. Use an "inside flag" state machine.
    3. Bucket collected points into connected sub-linestrings (breaks at exit-and-reenter).
    4. Convert per-sub-linestring meter offsets to fractions (offset / total_length).
    5. Drop sub-linestrings shorter than epsilonMeters.

    **`polygon_clip_test.dart`** covers:
    - Line entirely inside a square → 1 sub-segment spanning fraction 0.0..1.0.
    - Line entirely outside → empty list.
    - Line enters and exits once → 1 sub-segment with fraction_start > 0 and fraction_end < 1.
    - Line enters, exits, re-enters, exits → 2 sub-segments (pitfall from 04-RESEARCH §7).
    - Line touches a polygon vertex only (no crossing) → 0 sub-segments (or 1 zero-length dropped by epsilon).
    - Line lies exactly along an edge for 100 m → assigned to the polygon (left-of-line tie-break) as 1 sub-segment.
    - Polygon with inner ring (donut): line crossing hole → 2 sub-segments (in-outer, in-hole, in-outer) → the middle drops out, leaving 2.
    - Sub-segment shorter than 1 m (5-cm clip artifact) → dropped by epsilon.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/intersect/polygon_clip_test.dart` — all green.
    `flutter analyze` clean.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Berlin-bbox row-count probe (implementation)</name>
  <files>
    tool/osm_pipeline/lib/measure/berlin_row_count_probe.dart
    tool/osm_pipeline/bin/measure_berlin_row_count.dart
  </files>
  <intent>Implement the probe binary + probe library. Running it against a real Berlin PBF is Task 3 (checkpoint) — this task is code-only.</intent>
  <action>
    Requires the user to provide a Berlin PBF locally at RUN time. Read the path from the `TRAILBLAZER_BERLIN_PBF` env var. If unset, print a clear instruction message and exit non-zero:

    ```
    Berlin PBF not provided. Download from
      https://download.geofabrik.de/europe/germany/berlin.html
    then set TRAILBLAZER_BERLIN_PBF=/absolute/path/to/berlin-latest.osm.pbf
    and rerun:
      dart run tool/osm_pipeline/bin/measure_berlin_row_count.dart
    ```

    **`berlin_row_count_probe.dart`** — the diagnostic:
    1. Run stages A (04-03) and admin extraction (04-04) on the Berlin PBF, into a scratch DB.
    2. Query:
       - `SELECT COUNT(*) FROM ways_raw WHERE source='kfz'`  → kfz_way_count
       - `SELECT COUNT(*) FROM admin_regions_raw GROUP BY admin_level`  → per-level counts
       - `SELECT COUNT(*) FROM nodes_raw` → total_node_count
    3. Do a NAIVE bbox-vs-bbox overlap count (fast — not the real segmented intersection):
       - For each admin_region, count how many kfz way bboxes overlap its bbox.
       - Divide overlap_count / kfz_way_count → cross-border-way ratio (upper bound; true intersection is a subset).
    4. Extrapolate to full Germany:
       - Germany land area / Berlin land area ≈ 400  (Berlin ~890 km², Germany ~357 000 km²).
       - Assume Kfz way density is roughly constant → germany_kfz_way_count ≈ berlin_kfz_way_count × 400.
       - Cross-border ratio is roughly scale-invariant (admin polygons don't shrink with dataset), so germany_cross_border_ratio ≈ berlin_cross_border_ratio.
    5. Compute per-strategy size estimates:
       - **Denormalized-on-ways (recommended by 04-RESEARCH §7):**
         `ways_size = germany_kfz_way_count × row_bytes_per_way`
         where `row_bytes_per_way` conservatively = 200 B (existing columns) + 6 × 8 B (six BIGINT admin_region_id columns) = 248 B.
         `way_admin_raw_size = germany_kfz_way_count × germany_cross_border_ratio × ~40 B/row`
         Report the sum.
       - **Denormalized-on-ways minus L9/L10 columns (fallback):**
         Deduct 2 × 8 B from row_bytes_per_way.
       - **Join-table-only (drop denormalization entirely):**
         `way_admin_raw_size = germany_kfz_way_count × 6 levels × row_bytes(way_id, region_id, level_id, frac_start, frac_end) ≈ 40 B`.

       Add ~30 % overhead for indexes.
    6. Emit a recommendation:
       - If projected size < 100 MB → "denormalized-on-ways ok, 04-06 uses six columns"
       - If 100 MB < projected < 150 MB → "denormalized-on-ways with L9/L10 dropped"
       - Else → "join-table-only"
    7. Write the report as a MARKDOWN artifact: `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md` — table of counts, projections, and the recommendation. This file is committed and 04-06 reads it.

    Structure of the report (Task 3 fills this in by running the probe):
    ```markdown
    # Phase 4 · Plan 05 · Berlin-bbox Row-Count Measurement

    **Ran:** <ISO date>
    **Berlin PBF:** <basename + sha256>
    **Berlin land area:** ~890 km²  (extrapolation ratio to Germany: ≈ 400)

    ## Berlin actuals

    | Metric | Value |
    |---|---|
    | Kfz ways | ... |
    | Admin regions (level 2) | ... |
    | Admin regions (level 4) | ... |
    | ...level 10 | ... |
    | Bbox-overlap ratio (upper bound on cross-border) | ... % |

    ## Germany projections + strategy sizing

    | Strategy | Projected osm.sqlite size |
    |---|---|
    | Denormalized L2..L10 on ways + way_admin_raw for splits | ... MB |
    | Denormalized L2..L8 only (drop L9, L10) | ... MB |
    | Join-table-only (no denormalization) | ... MB |

    ## Recommendation

    04-06 SHOULD use: **<strategy>**
    ```

    **`bin/measure_berlin_row_count.dart`** — thin CLI wrapper: parse env var, call the probe, print the report to stdout, write the markdown artifact, exit 0/1 accordingly.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test` — no test regressions introduced.
    `flutter analyze` clean.
    Unit-level smoke: without a Berlin PBF, `dart run tool/osm_pipeline/bin/measure_berlin_row_count.dart` exits non-zero with the download instruction message (Task 3 covers the real run).
  </verify>
</task>

<task type="checkpoint:human-verify">
  <name>Task 3: Berlin measurement run + user confirmation (schema unlock)</name>
  <gate>blocking</gate>
  <what-built>
    Task 2 implemented the probe binary. Now we need a real measurement against a real Berlin PBF, because 04-06 will read this file to lock its schema strategy. The whole point of the Berlin measurement (per RESEARCH §7: *"Do NOT lock a schema before running the Berlin-bbox smoke and scaling"*) is that we don't guess.
  </what-built>
  <how-to-verify>
    1. Download the Berlin PBF from Geofabrik if not already present:
       ```
       https://download.geofabrik.de/europe/germany/berlin.html
       → berlin-latest.osm.pbf  (~60 MB)
       ```
    2. Point the probe at the file:
       ```bash
       export TRAILBLAZER_BERLIN_PBF=/absolute/path/to/berlin-latest.osm.pbf
       # PowerShell: $env:TRAILBLAZER_BERLIN_PBF = "..."
       ```
    3. Run:
       ```bash
       dart run tool/osm_pipeline/bin/measure_berlin_row_count.dart
       ```
       Should complete in < 5 min. Produces `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md`.

    4. Read the "Recommendation" line at the bottom of the produced file. Confirm the projected sizes look reasonable and the recommended strategy matches your intuition.

    5. If the recommendation says "join-table-only" or "denormalized L2..L8 only": the schema in 04-06 will differ from the 04-RESEARCH §7 default — this is EXPECTED behavior, not a red flag. Confirm you're OK proceeding with the measurement-driven strategy.

    6. If you cannot obtain a Berlin PBF right now: explicitly acknowledge to the executor that 04-06 is blocked until this is resolved. Do NOT bypass with a stub — 04-06 has a hard gate that will refuse to run without a real measurement.
  </how-to-verify>
  <resume-signal>
    Reply with one of:
    - "measurement complete, recommendation: <strategy>"  — 04-06 will read the file and use this strategy
    - "blocked, no Berlin PBF available"  — execution pauses; the user must obtain the PBF before 04-06 can run
    - "override, use default L2..L10"  — explicit user override; the executor writes a stub file marked "not empirically verified" AND flags the risk in the SUMMARY. 04-06 will still HARD-FAIL on this stub unless the user also confirms the override there.
  </resume-signal>
</task>

<task type="auto">
  <name>Task 4: way_admin_join orchestrator + tests</name>
  <files>
    tool/osm_pipeline/lib/intersect/way_admin_join.dart
    tool/osm_pipeline/lib/scratch/scratch_schema.dart
    tool/osm_pipeline/test/intersect/way_admin_join_test.dart
  </files>
  <intent>Populate the scratch way_admin_raw table using the clipper. Runs after the measurement is locked (Task 3 checkpoint).</intent>
  <action>
    Extend `scratch_schema.dart` with a **PROVISIONAL** schema — the final osm.sqlite shape is decided in 04-06 but we need a scratch stagingground here:

    ```sql
    CREATE TABLE way_admin_raw (
      way_id         INTEGER NOT NULL,
      region_id      INTEGER NOT NULL,      -- FK to admin_regions_raw.region_id
      admin_level    INTEGER NOT NULL,      -- 2 | 4 | 6 | 8 | 9 | 10
      fraction_start REAL NOT NULL,         -- 0..1 along the way
      fraction_end   REAL NOT NULL,         -- 0..1 along the way
      PRIMARY KEY (way_id, region_id, admin_level, fraction_start)
    ) WITHOUT ROWID;

    CREATE INDEX idx_way_admin_way ON way_admin_raw(way_id);
    CREATE INDEX idx_way_admin_region ON way_admin_raw(region_id);
    ```

    **`way_admin_join.dart`** — algorithm:

    1. Build an in-memory R-Tree-lite (simple bbox-array + linear scan works for Berlin; for Germany, use a bucketed grid at 0.1° resolution — cheap in Dart). Index admin_regions_raw by admin_level.
    2. For each way in ways_raw where source='kfz':
       a. Load its node_ids BLOB, resolve to Vec2 list via nodes_raw.
       b. Compute way bbox.
       c. For each admin_level in {2,4,6,8,9,10}:
          - Query candidates whose bbox overlaps the way bbox.
          - For each candidate region: `clipLinestringToPolygon(wayLine, regionMultiPolygon)`.
          - For each returned sub-segment, INSERT way_admin_raw(way_id, region_id, level, fraction_start, fraction_end).
    3. Post-pass integrity check: no way should appear more than once for the same (region_id, admin_level) if fraction_start values overlap — assert as a sanity SELECT.

    Denormalization on ways (deferred to 04-06 based on measurement): this plan does NOT touch the denormalized columns. 04-06 promotes way_admin_raw to the final osm.sqlite and applies the wholly-contained-way roll-up.

    **`way_admin_join_test.dart`** using synthetic tiny data (populate nodes_raw / ways_raw / admin_regions_raw programmatically in the test):
    - Way wholly inside one admin region at all six levels → 6 rows written (one per level), fraction_start=0.0, fraction_end=1.0.
    - Way crossing the border between two admin_level=6 regions once → 2 rows written at level=6 (fraction_start < 1 for the first, fraction_end > 0 for the second).
    - Way entering and re-entering the same region → 2 rows for that (way, region, level).
    - Way lying exactly along an admin border → assigned to left region only (tie-break).
    - Way not intersecting any admin region → 0 rows.
    - Multipolygon admin region with inner ring: way crossing the hole → the sub-segment inside the hole does NOT get a row.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/intersect/way_admin_join_test.dart` — all green.
    Manual smoke on tiny fixture: after running the CLI, `way_admin_raw` has exactly 1 row (the single Kfz way crossing the single admin region at level 8), fraction_start ≈ 0.4, fraction_end ≈ 0.7 (or similar — depends on how the fixture geometry was laid out).
  </verify>
</task>

## Verification

- `cd tool/osm_pipeline && dart test test/intersect/` — all green.
- `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md` exists AND contains a filled-in "Recommendation" line (produced by Task 3's real run against a real Berlin PBF).
- `flutter analyze` clean.
- Running the full CLI on tiny.osm.pbf produces the expected 1 way_admin_raw row for the fixture's Kfz way crossing Testgemeinde.

## Deviation Handling

- **Berlin PBF unavailable at execution time:** the Task 3 checkpoint blocks. Do NOT auto-generate a stub measurement — 04-06 has a hard gate that rejects unverified measurements. The user must either supply the PBF or explicitly override via the Task 3 "override" resume-signal (which flags the risk and requires a matching override in 04-06).
- If the O(ways × admin_regions_at_level) scan is too slow even for Berlin (> 60 s), replace the linear-scan candidate query with a proper R-Tree. `sqlite3`'s built-in R*Tree virtual table can be used here as a scratch structure — no extra dep.
- Coincident-edge tie-break: 04-RESEARCH §7 says "left of line". If tests reveal this is inconsistent for closed polygons (left is defined relative to line direction; polygons have no direction), fall back to "assign to the polygon whose centroid is on the left" — document the switch in the code.
- Multipolygon-with-inner geometry uses MultiPolygon.polygons[0].holes — task 2 of 04-04 already produced that shape.
- Iterate up to 3 times per task; report blockers verbatim.
