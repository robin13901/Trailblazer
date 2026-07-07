---
id: 04-10-1-03
phase: 04-osm-pipeline
plan: 10-1-03
type: execute
wave: 3
depends_on: [04-10-1-02]
files_modified:
  - tool/osm_pipeline/lib/output/rtree_builder.dart
  - tool/osm_pipeline/lib/cli/args.dart
  - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
  - tool/osm_pipeline/bin/osm_pipeline.dart
  - tool/osm_pipeline/test/output/rtree_builder_test.dart
  - tool/osm_pipeline/test/cli/args_test.dart
  - tool/osm_pipeline/test/output/pipeline_orchestrator_test.dart
autonomous: true
requirements: [OSM-05]

must_haves:
  truths:
    - "Default R-Tree granularity is perWay. The measurement-file lookup is retained as a fallback / override path but no longer required to opt-in to perWay."
    - "New CLI flag `--rtree-granularity=perSegment|perWay` (default: perWay). Passes through the orchestrator into RtreeBuilder."
    - "Berlin gate: `ways_rtree` row count equals `ways` row count exactly (perWay = 1 rtree row per way, post-Feldweg-drop = 91 707 Kfz rows)."
    - "Phase 5 `findWaysNear` semantic note (bbox-hits require line-clip) is captured as a TODO(phase-5) in rtree_builder.dart so future readers see the contract."
    - "RtreeBuilder tests cover BOTH perSegment and perWay paths — perSegment stays alive as an opt-in fallback."
  artifacts:
    - path: "tool/osm_pipeline/lib/output/rtree_builder.dart"
      provides: "Default granularity = perWay; documented perSegment opt-in."
      contains: "TODO(phase-5)"
    - path: "tool/osm_pipeline/lib/cli/args.dart"
      provides: "--rtree-granularity CLI option"
    - path: "tool/osm_pipeline/test/output/rtree_builder_test.dart"
      provides: "Coverage of both perSegment (opt-in) and perWay (default) paths."
  key_links:
    - from: "tool/osm_pipeline/bin/osm_pipeline.dart"
      to: "tool/osm_pipeline/lib/output/pipeline_orchestrator.dart"
      via: "ParsedArgs.rtreeGranularity forwarded to runPipeline"
      pattern: "rtreeGranularity"
    - from: "tool/osm_pipeline/lib/output/pipeline_orchestrator.dart"
      to: "tool/osm_pipeline/lib/output/rtree_builder.dart"
      via: "granularity is chosen from ParsedArgs first, then measurement fallback, then perWay default"
      pattern: "RtreeGranularity\\."
---

## Goal

Flip the R-Tree default from `perSegment` to `perWay` so full-Germany osm.sqlite drops the ~5 GB R-Tree tax to ~340 MB (research §4.3). Keep `perSegment` as an opt-in via new CLI flag. Land a Phase 5 TODO documenting the bbox-hits-require-line-clip contract.

## Context

- Source: `.planning/phases/04-osm-pipeline/04-10-1-RESEARCH.md` §4 (R-Tree perWay vs perSegment) and §7.1 (byte projection).
- STATE.md line 204: current default is perSegment; per-way is a measurement-recommended fallback. This plan inverts the default.
- STATE.md line 209: Berlin baseline has 555 920 rtree rows for 176 567 ways under perSegment. Post-Feldweg-drop (Wave 2) baseline: 91 707 Kfz ways only. Berlin gate: 91 707 rtree rows post-Wave-3.
- Phase 5's `findWaysNear` implementation is Phase 5 scope. This plan documents the contract change (bbox-hits require line-clip) via a `TODO(phase-5)` comment in the builder — no `lib/` code changes.
- 04-05-BERLIN-MEASUREMENT.md currently states "perSegment default"; DO NOT edit it here — the measurement doc is a historical measurement, not a config file. If the executor discovers a live production hazard (measurement file causes perSegment to be picked despite the CLI flag), fix the load order (CLI wins over measurement, measurement wins over default) rather than editing the measurement doc.

## Tasks

<task type="auto">
  <name>Task 1: Flip RtreeBuilder default + add CLI flag</name>
  <files>
    tool/osm_pipeline/lib/output/rtree_builder.dart
    tool/osm_pipeline/lib/cli/args.dart
    tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
    tool/osm_pipeline/bin/osm_pipeline.dart
  </files>
  <intent>Make perWay the default. Keep perSegment reachable. Document the Phase 5 contract.</intent>
  <action>
    **`rtree_builder.dart`:**
    - Update the library docstring: "Default is perWay (Plan 04-10-1-03 · 2026-07-07). Per-segment is opt-in via `--rtree-granularity=perSegment` on the CLI."
    - Change `RtreeBuilder.loadFromMeasurement`: still supported for backwards compat, but its behavior inverts — if the file says `per-segment` (case-insensitive), return `perSegment`; otherwise return `perWay`. Update the doc comment. If the file is missing → `perWay`.
    - Add a `TODO(phase-5)` block near the top of the file:
      ```
      // TODO(phase-5): perWay R-Tree returns 1 candidate row per way. The
      // returned bbox is the full-way bounding box — a query point can be
      // inside the bbox but far from the actual polyline. The HMM matcher
      // MUST line-clip each candidate (walk the LineString-WKB and take
      // the nearest point) before feeding it to Viterbi. This was
      // intentional per Plan 04-10.1 research §4.
      ```
    - No signature changes: `RtreeGranularity` enum stays; `buildForWay` unchanged.

    **`args.dart`:**
    - Add option: `--rtree-granularity` (allowed: `perSegment`, `perWay`; default: null → let orchestrator pick).
    - Parse into `RtreeGranularity?` (nullable — null means "orchestrator decides"). Rejection on unknown values → PipelineArgsError.
    - Add field `final RtreeGranularity? rtreeGranularity;` to `ParsedArgs`.

    **`pipeline_orchestrator.dart::runPipeline`:**
    - Add parameter `RtreeGranularity? granularityOverride`. Selection order:
      1. If `granularityOverride != null` → use it.
      2. Else if measurement file exists → `RtreeBuilder.loadFromMeasurement(...)` (which now defaults to perWay when the file doesn't explicitly say `per-segment`).
      3. Else → `RtreeGranularity.perWay`.
    - Log the chosen granularity via `Logger.info('R-Tree granularity: perWay|perSegment')` before Stage E.

    **`bin/osm_pipeline.dart`:**
    - Forward `parsed.rtreeGranularity` as `granularityOverride:` into `runPipeline(...)`.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    grep -n "TODO(phase-5)" lib/output/rtree_builder.dart    # exactly 1 match
    ```
    Both green.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Update tests for both paths + CLI parsing</name>
  <files>
    tool/osm_pipeline/test/output/rtree_builder_test.dart
    tool/osm_pipeline/test/cli/args_test.dart
    tool/osm_pipeline/test/output/pipeline_orchestrator_test.dart
  </files>
  <intent>Exercise both granularity paths + the new CLI plumbing.</intent>
  <action>
    **`rtree_builder_test.dart`:**
    - Existing tests probably cover perSegment as default. Keep perSegment tests but rename their group to `'perSegment (opt-in)'`.
    - Add a `'perWay (default)'` group with:
      - `builds 1 rtree row per way` — feed a 5-point line, assert 1 row inserted.
      - `bbox spans the full polyline` — assert min_lat/max_lat/min_lng/max_lng span all 5 points.
      - `segment_idx = -1 sentinel` — assert lookup row's segment_idx column is -1.
    - Update `loadFromMeasurement` tests:
      - Missing file → perWay (was: perSegment).
      - File containing `per-segment` → perSegment.
      - File containing `per-way` → perWay.
      - File containing neither → perWay.

    **`args_test.dart`:**
    - `--rtree-granularity=perSegment` → parses to `RtreeGranularity.perSegment`.
    - `--rtree-granularity=perWay` → parses to `RtreeGranularity.perWay`.
    - No flag → null.
    - `--rtree-granularity=invalid` → throws `PipelineArgsError`.

    **`pipeline_orchestrator_test.dart`:**
    - Existing end-to-end test: after this plan, `ways_rtree` row count should equal `ways` row count (both = Kfz way count in the fixture). Update the assertion.
    - Add: passing `granularityOverride: RtreeGranularity.perSegment` produces > 1 rtree row per multi-segment fixture way.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    dart test test/output/rtree_builder_test.dart
    dart test test/cli/args_test.dart
    dart test test/output/pipeline_orchestrator_test.dart
    ```
    All green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Berlin verify — rtree row count = ways row count</name>
  <files>
    (none — measurement only)
  </files>
  <intent>Empirical proof of the perWay = 1-row-per-way invariant + DB shrinkage.</intent>
  <action>
    Run Berlin smoke (from `tool/osm_pipeline/`):
    ```bash
    dart run bin/osm_pipeline.dart --pbf=<berlin-pbf> --bbox=13.088,52.338,13.761,52.675
    ```
    (default flag → perWay).

    Capture:
    - `sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways;"` → 91 707.
    - `sqlite3 out/osm.sqlite "SELECT COUNT(*) FROM ways_rtree;"` → 91 707 (exact match; the perWay = 1-row-per-way invariant).
    - `stat --printf="%s" out/osm.sqlite` → target < 25 MB (down from ~45 MB after Wave 2).
    - `sqlite3 out/osm.sqlite "SELECT segment_idx FROM ways_rtree_lookup LIMIT 5;"` → all -1.

    Also verify perSegment still works via explicit flag:
    ```bash
    dart run bin/osm_pipeline.dart --pbf=<berlin-pbf> --bbox=... --rtree-granularity=perSegment
    ```
    - `SELECT COUNT(*) FROM ways_rtree;` → > 91 707 (per-segment count; ~3.15× typically).
  </action>
  <verify>
    Manual: capture the numbers above. Fail-close if
    `ways_rtree` count != `ways` count under perWay default.
  </verify>
</task>

## Success Criteria

- Default R-Tree granularity is perWay (verified by CLI run without the flag).
- `ways_rtree` row count = `ways` row count on Berlin (exact match: 91 707).
- osm.sqlite Berlin size < 25 MB.
- `--rtree-granularity=perSegment` opt-in still works.
- TODO(phase-5) comment present in `rtree_builder.dart`.
- `dart analyze` clean; `dart test` green in `tool/osm_pipeline/`.

## Ralph Loop

- Tight loop: `cd tool/osm_pipeline && dart analyze`.
- Behavior-sensitive (Tasks 1-2): `dart test test/output/ test/cli/` after each edit.
- Pre-push: repo-wide `flutter analyze --fatal-infos` + `flutter test`.

## Deviations

- If the pmtiles integration test breaks because it opens the output osm.sqlite and queries per-segment structure — investigate and either fix the test to be granularity-agnostic (preferred) or gate it with an explicit --rtree-granularity=perSegment fixture invocation.
- If `RtreeBuilder.loadFromMeasurement` inversion collides with 04-05-BERLIN-MEASUREMENT.md's actual current wording (which says the recommendation is perSegment): DO NOT rewrite the measurement doc. Instead: the CLI default supersedes the measurement doc from this plan forward, and a note about the supersession lands in this plan's SUMMARY.

## Commit Strategy

- Task 1: `feat(04-10-1-03): flip R-Tree default to perWay; add --rtree-granularity CLI flag`
- Task 2: `test(04-10-1-03): cover both perSegment and perWay paths + CLI parsing`
- Task 3: no commit — measurement only.
