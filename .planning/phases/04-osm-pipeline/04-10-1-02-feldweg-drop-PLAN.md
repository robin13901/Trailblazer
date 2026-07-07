---
id: 04-10-1-02
phase: 04-osm-pipeline
plan: 10-1-02
type: execute
wave: 2
depends_on: [04-10-1-01]
files_modified:
  - tool/osm_pipeline/lib/schema.dart
  - tool/osm_pipeline/lib/filter/way_pipeline.dart
  - tool/osm_pipeline/lib/output/osm_sqlite_writer.dart
  - tool/osm_pipeline/lib/intersect/way_admin_join.dart
  - tool/osm_pipeline/lib/pmtiles/geojson_writer.dart
  - tool/osm_pipeline/test/filter/way_pipeline_test.dart
  - tool/osm_pipeline/test/output/osm_sqlite_writer_test.dart
  - tool/osm_pipeline/test/output/pipeline_orchestrator_test.dart
  - tool/osm_pipeline/test/pmtiles/geojson_writer_test.dart
  - .planning/REQUIREMENTS.md
  - .planning/ROADMAP.md
autonomous: true
requirements: [OSM-02, REN-02, OSM-06]

must_haves:
  truths:
    - "osm.sqlite `ways` table contains ONLY Kfz-source rows (14-tag allowlist). Feldweg rows do NOT appear."
    - "germany-base.pmtiles `roads` layer STILL emits both Kfz and Feldweg — REN-02's visual base geometry is intact."
    - "Stage D (way_admin_join) processes only Kfz ways — its WHERE clause was already `source='kfz'`, but the row-count total dropped by the Feldweg share so ProgressLogger totals stay honest."
    - "Stage E writes only Kfz ways to osm.sqlite via a WHERE clause on `ways_raw`."
    - "`pipelineSchemaVersion` = 2. Phase 5 integrity check will detect version=1 → version=2 as a mandatory re-download / re-generate boundary."
    - "REQUIREMENTS.md OSM-02 rewrite lands verbatim per research §1.6. REN-02 clarifying note lands. ROADMAP P4-SC2 rewords to reflect Feldweg-in-pmtiles-only. ROADMAP P7-SC1 clarifies Feldwege as static base geometry."
    - "REQUIREMENTS.md MMT-05 gains an explicit NOTE (2026-07-07) that Feldweg-drop narrows matcher scope; STATE.md Pending Todos gains a Phase-5-facing entry so the Phase 5 planner sees the scope narrowing during discovery."
    - "Berlin smoke: osm.sqlite drops from 84.8 MB baseline by at least 40% (target: < 50 MB); `SELECT COUNT(*) FROM ways` = 91 707 (Kfz-only)."
  artifacts:
    - path: "tool/osm_pipeline/lib/schema.dart"
      provides: "pipelineSchemaVersion = 2"
      contains: "const int pipelineSchemaVersion = 2;"
    - path: ".planning/REQUIREMENTS.md"
      provides: "OSM-02 rewrite + REN-02 clarifying note per research §1.6"
    - path: ".planning/ROADMAP.md"
      provides: "P4-SC2 + P7-SC1 narrowing edits per research §1.6"
  key_links:
    - from: "tool/osm_pipeline/lib/output/osm_sqlite_writer.dart"
      to: "ways_raw scratch table"
      via: "SELECT ... FROM ways_raw WHERE source = 'kfz'"
      pattern: "source = 'kfz'"
    - from: "tool/osm_pipeline/lib/pmtiles/geojson_writer.dart"
      to: "roads.geojsonl"
      via: "writeRoads emits BOTH source='kfz' and source='feldweg' — unchanged"
      pattern: "SELECT id, highway, name, ref, is_directional, node_ids FROM ways_raw"
---

## Goal

Drop Feldweg ways from the final `osm.sqlite` while keeping them visible in the `germany-base.pmtiles` `roads` layer. Bump `pipelineSchemaVersion` to 2. Land the four narrowing edits in REQUIREMENTS.md and ROADMAP.md. Empirical proof on Berlin: osm.sqlite shrinks by ~half.

## Context

- Source: `.planning/phases/04-osm-pipeline/04-10-1-RESEARCH.md` §1 (requirement impact), §2.5 (empirical byte math), §3.3 (Feldweg-drop size projection), §8.1 (Berlin gate).
- User decision: SC4 target renegotiation is deferred to Wave 5 (this plan does not touch ROADMAP SC4 wording).
- STATE.md line 172: Kfz retention set is `highway|name|ref|oneway|maxspeed` — do not disturb.
- STATE.md line 204: R-Tree granularity is a Wave 3 concern — this plan does NOT touch `rtree_builder.dart` defaults.
- Rendering side (REN-02): the pmtiles `roads` layer keeps Feldweg. Only the driven-per-way state-coloring path degrades. Documented in the REQUIREMENTS.md edit.

## Tasks

<task type="auto">
  <name>Task 1: Filter Feldweg out of osm.sqlite writes + bump schema version</name>
  <files>
    tool/osm_pipeline/lib/schema.dart
    tool/osm_pipeline/lib/output/osm_sqlite_writer.dart
    tool/osm_pipeline/lib/intersect/way_admin_join.dart
    tool/osm_pipeline/test/output/osm_sqlite_writer_test.dart
    tool/osm_pipeline/test/output/pipeline_orchestrator_test.dart
  </files>
  <intent>Make osm.sqlite Kfz-only. Preserve source column (still writes 'kfz') for now — a future plan can drop the column if the schema audit clears.</intent>
  <action>
    **`schema.dart`:** change `const int pipelineSchemaVersion = 1;` → `const int pipelineSchemaVersion = 2;`. Add a comment noting the reason: "v2 (2026-07-07 · Plan 04-10.1): Feldweg dropped from osm.sqlite ways table."

    **`osm_sqlite_writer.dart`:** in `_copyWays`, change the SELECT from ways_raw to filter Kfz-only:
    ```
    SELECT id, source, is_counting, is_directional, oneway_tag, highway,
           name, ref, maxspeed, surface, node_ids
    FROM ways_raw
    WHERE source = 'kfz';
    ```
    Do NOT drop the `source` column from the output `ways` table schema — leaving it as always='kfz' is a smaller schema diff. If ProgressLogger total was being computed from `COUNT(*) FROM ways_raw`, update it to `WHERE source='kfz'` as well (Task 1 of Wave 1 handled this in principle; verify the exact call site).

    **`way_admin_join.dart`:** its existing SELECT is already `WHERE source='kfz'` — verify and leave as-is. Update the ProgressLogger total (added in 04-10-1-01) to the same Kfz-only COUNT if it isn't already.

    **Tests to update:**
    - `test/output/osm_sqlite_writer_test.dart`: any test asserting Feldweg rows in the output `ways` table must flip to asserting absence. Update WHERE-clause expectations.
    - `test/output/pipeline_orchestrator_test.dart`: assert `SELECT COUNT(*) FROM ways` equals the Kfz count only.
    - Add a NEW test in `osm_sqlite_writer_test.dart`: seed scratch with 1 Kfz + 1 Feldweg way, run writer, assert output `ways` has exactly 1 row (source='kfz').
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    dart test test/output/
    dart test test/intersect/
    ```
    All green. `PRAGMA user_version` of the output DB now reads 2.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Confirm Feldweg still lands in pmtiles roads.geojsonl</name>
  <files>
    tool/osm_pipeline/lib/pmtiles/geojson_writer.dart
    tool/osm_pipeline/test/pmtiles/geojson_writer_test.dart
  </files>
  <intent>Guarantee REN-02's visual base geometry survives — Feldweg features must still stream to roads.geojsonl.</intent>
  <action>
    Read `geojson_writer.dart::writeRoads` — its SELECT is already
    `SELECT id, highway, name, ref, is_directional, node_ids FROM ways_raw;`
    (no WHERE clause). This means both Kfz and Feldweg still flow through.
    LEAVE THIS UNCHANGED. Add an inline comment at the SELECT:

    ```dart
    // v2 (2026-07-07 · Plan 04-10-1-02): Feldweg is INCLUDED here on purpose.
    // osm.sqlite drops Feldweg (Kfz-only after 04-10-1-02) but the pmtiles
    // roads layer must retain both — REN-02's visual base geometry (dashed
    // blue Feldweg tracks) reads from the pmtiles, not osm.sqlite.
    ```

    **Tests:**
    - Ensure existing `geojson_writer_test.dart` has (or add) an assertion:
      when the scratch DB has both Kfz and Feldweg rows, `writeRoads` emits
      one Feature per row (Kfz count + Feldweg count = feature count).
    - If a test currently short-circuited on source column, update the
      expectation to include Feldweg features in the roads output.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    dart test test/pmtiles/
    ```
    All green. Manual grep: `grep "source = 'kfz'" lib/pmtiles/geojson_writer.dart` returns 0 matches (Feldweg is NOT filtered here).
  </verify>
</task>

<task type="auto">
  <name>Task 3: REQUIREMENTS.md + ROADMAP.md narrowing edits</name>
  <files>
    .planning/REQUIREMENTS.md
    .planning/ROADMAP.md
  </files>
  <intent>Land the four narrowing edits from research §1.6 verbatim.</intent>
  <action>
    **REQUIREMENTS.md OSM-02 (line 45):** replace with:

    ```
    - [ ] **OSM-02**: Pipeline extracts only ways with `highway=motorway|trunk|primary|
      secondary|tertiary|residential|unclassified|living_street|road|motorway_link|
      trunk_link|primary_link|secondary_link|tertiary_link` (14-tag Kfz allowlist)
      into osm.sqlite. `highway=track|path` (Feldweg/Fußweg) are emitted ONLY into
      the pmtiles `roads` layer for map rendering — they do NOT appear in
      osm.sqlite. See Plan 04-10.1 decision log 2026-07-07.
    ```

    **REQUIREMENTS.md REN-02 (line 134):** replace with:

    ```
    - [ ] **REN-02**: Driven Feldweg/Fußweg ways are rendered in a distinct
      secondary color (default: dashed blue). NOTE (2026-07-07): Feldwege are
      rendered as static base geometry from the pmtiles roads layer; per-way
      driven-state coloring (feature-state) applies to Kfz ways only.
    ```

    **ROADMAP.md P4-SC2 (line 128):** replace with:

    ```
      2. Output artifacts include the Kfz `highway=*` set in osm.sqlite;
         Feldweg/Fußweg (`highway=track|path`) are emitted into the pmtiles `roads`
         layer only. Admin boundaries at OSM levels 2, 4, 6, 8, 9, 10.
    ```

    **ROADMAP.md P7-SC1 (line 173):** replace with:

    ```
      1. Driven Kfz-ways render in the primary "explored" color (default warm green); Feldweg/Fußweg ways render as static base geometry from the pmtiles roads layer in a distinct secondary color (default: dashed blue). Per-way driven-state coloring applies to Kfz ways only (see REN-02 note dated 2026-07-07).
    ```

    **Update REQUIREMENTS.md COV-04:** leave unchanged (Feldweg was already excluded from coverage math).

    **REQUIREMENTS.md MMT-05 (matcher scope narrowing):** append a NOTE below the existing MMT-05 line:

    ```
      NOTE (2026-07-07): Feldweg ways are not in osm.sqlite (see OSM-02);
      GPS traces over Feldwege will produce points that the matcher cannot
      snap to a road — these register as trip gaps or "points that cannot be
      matched confidently are dropped" per this requirement. Intended v1
      scope per Plan 04-10.1. If future work restores Feldweg matching,
      this note is deleted.
    ```

    Rationale: research §1.5 flags that Feldweg-drop is an implicit scope narrowing for MMT-05 ("Points that cannot be matched confidently are dropped"). Making that narrowing explicit here prevents a Phase 5 planner from being surprised by rural GPS gaps and keeps the reversibility scoping clean.

    Also append to `.planning/STATE.md` "Pending Todos" a matching entry so the Phase 5 planner sees it during discovery:

    ```
    - **Phase 5 (matcher scope):** Feldweg ways were removed from osm.sqlite
      in Plan 04-10.1 (2026-07-07). MMT-05's "points that cannot be matched
      confidently are dropped" now includes any GPS point over a Feldweg —
      the matcher never sees Feldweg candidates in `findWaysNear`. Phase 5
      golden corpus must not include Feldweg-heavy routes unless we choose
      to restore Feldweg indexing (add a Phase 5.1 gap-closure).
    ```


    **Update REQUIREMENTS.md SET-04:** leave wording unchanged (semantic narrowing only, no text change).

    **Update ROADMAP.md P8-SC5:** leave unchanged.

    Update the "Last updated" line at the bottom of REQUIREMENTS.md to
    `2026-07-07 (Plan 04-10.1)`.
  </action>
  <verify>
    ```bash
    grep -n "Plan 04-10.1 decision log" .planning/REQUIREMENTS.md
    grep -n "NOTE (2026-07-07)" .planning/REQUIREMENTS.md
    grep -n "Feldweg/Fußweg (\`highway=track|path\`) are emitted" .planning/ROADMAP.md
    grep -n "static base geometry from the pmtiles roads layer" .planning/ROADMAP.md
    ```
    All four grep commands return exactly 1 match each.
  </verify>
</task>

<task type="auto">
  <name>Task 4: Berlin verify — measure osm.sqlite shrinkage</name>
  <files>
    (none — measurement only)
  </files>
  <intent>Empirical proof that Wave 2 lands the ~50% shrink projected in research §2.5.</intent>
  <action>
    Run Berlin smoke (from `tool/osm_pipeline/`):
    ```bash
    dart run bin/osm_pipeline.dart --pbf=<berlin-pbf> --bbox=13.088,52.338,13.761,52.675
    ```

    Capture:
    - `stat --printf="%s" out/osm.sqlite` — should be < 50 MB (down from 84.8 MB baseline).
    - `sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways;"` — should be exactly 91 707 (Kfz-only per 04-05 measurement).
    - `sqlite3 out/osm.sqlite "PRAGMA user_version;"` — should be 2.
    - `sqlite3 out/osm.sqlite "SELECT COUNT(DISTINCT source) FROM ways;"` — should be 1 (only 'kfz').

    Confirm pmtiles roads layer still contains Feldweg by inspecting the
    generated roads.geojsonl (or an intermediate log line count showing
    ~176 567 features written total).

    Do NOT modify 04-05-BERLIN-MEASUREMENT.md in this task — that's a Wave 5
    concern (measurement doc update).

    If any gate fails, iterate on Task 1 or Task 2 before proceeding to
    Wave 3.
  </action>
  <verify>
    Manual: capture the four numbers above and record them in the task's
    execution log / SUMMARY. Fail-close if osm.sqlite > 50 MB or
    user_version != 2 or COUNT(*) != 91 707 or DISTINCT source != 1.
  </verify>
</task>

## Success Criteria

- osm.sqlite Berlin size < 50 MB (down from 84.8 MB — at least 40% shrinkage).
- `SELECT COUNT(*) FROM ways` = 91 707 (Kfz only, exact match).
- `PRAGMA user_version` returns 2.
- pmtiles Berlin build still contains Feldweg features in the roads layer.
- REQUIREMENTS.md + ROADMAP.md carry the four narrowing edits verbatim per research §1.6.
- `dart analyze` clean; `dart test` green in `tool/osm_pipeline/`.

## Ralph Loop

- Tight loop: `cd tool/osm_pipeline && dart analyze`.
- Behavior-sensitive (Tasks 1-2): run `dart test test/output/ test/intersect/ test/pmtiles/` inside the loop — filter changes are the definition of behavior-sensitive.
- Pre-push: `flutter analyze --fatal-infos` + `flutter test` at repo root (hook handles this).

## Deviations

- If Berlin osm.sqlite ends up > 50 MB but < 60 MB, log the delta and continue — the extrapolation is a projection, not a guarantee. Escalate if > 60 MB (research §3.3 math is off by 20% at that point).
- If a Phase 5 concern surfaces (integrity check hard-codes `pipelineSchemaVersion == 1`), that's a follow-up for Phase 5 — do not chase into `lib/` app code. This sub-phase is 100% pipeline + planning docs (per orchestrator rules). File as a Phase 5 pending todo in STATE.md if discovered.
- If a test in `pipeline_orchestrator_test.dart` uses a fixture that ships Feldweg-only sample and now returns 0 ways, update the fixture or the assertion; the intent is unchanged.

## Commit Strategy

- Task 1: `feat(04-10-1-02): drop Feldweg from osm.sqlite ways table; schemaVersion=2`
- Task 2: `docs(04-10-1-02): comment geojson_writer to preserve Feldweg in pmtiles roads`
- Task 3: `docs(04-10-1-02): narrow OSM-02/REN-02/P4-SC2/P7-SC1 per research §1.6`
- Task 4: no commit — measurement only; capture numbers in SUMMARY.
