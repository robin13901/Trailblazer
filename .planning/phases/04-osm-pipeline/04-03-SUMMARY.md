---
phase: 04-osm-pipeline
plan: 03
subsystem: pipeline-filter
tags: [osm, highway-filter, kfz, feldweg, directionality, sqlite, scratch-db, streaming, stage-b]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: 04-01 CLI scaffold (PipelineError, ParsedArgs, path-imported sub-package)
  - phase: 04-osm-pipeline
    provides: 04-02 PbfReader.stream() → Stream<OsmEntity>
  - phase: 04-osm-pipeline
    provides: CONTEXT.md 14-tag Kfz allowlist + retained-tag list
  - phase: 04-osm-pipeline
    provides: RESEARCH.md §4 (Feldweg carve-out) + §5 (directionality) + §10 (scratch pragmas) + §12 pitfalls
provides:
  - "isKfzWay predicate + retainKfzTags (14-tag OSM-02 allowlist)"
  - "feldwegTagsOrNull for track / path+motor_vehicle=yes|permissive / service=driveway|alley"
  - "normalizeDirectionality: yes/-1/no explicit + implicit-oneway for motorway|motorway_link|trunk_link"
  - "kExplicitFeldwegHighwayValues constant (rejection-reason disambiguation)"
  - "ScratchDb.openTempFile — journal_mode=OFF / synchronous=OFF / cache_size=-524288 / temp_store=MEMORY / page_size=65536"
  - "encodeNodeIds / decodeNodeIds — uint32 count + int64 LE per id BLOB layout"
  - "WayPipeline.run() — two-pass Stage B filter → ways_raw + nodes_raw + skipped.log + filter_stats"
  - "Stage B wired into CLI stub — dart run tool/osm_pipeline --pbf=... prints filter stats"
affects: [04-04, 04-05, 04-06, 04-07, 04-08, 04-09, 04-10, 05-osm-db]

# Tech tracking
tech-stack:
  added:
    - "sqlite3 ^2.4.0 (pure-Dart bindings; prebuilt Windows/macOS/Linux binaries — no FFI DLL prereq)"
    - "ffi 2.2.0 (transitive)"
  patterns:
    - "Two-pass streaming filter: pass A collects ways + referenced node ids; pass B ingests only referenced nodes"
    - "Skip-log-continue error handling with typed reason codes in skipped.log"
    - "Prepared-statement + batched-transaction writer (10 000 rows/flush)"
    - "Length-prefixed int64 LE BLOB encoding for node-id sequences on SQLite rows"
    - "Rejection reason disambiguation via a small constant set (kExplicitFeldwegHighwayValues)"

key-files:
  created:
    - "tool/osm_pipeline/lib/filter/highway_class.dart"
    - "tool/osm_pipeline/lib/filter/kfz_filter.dart"
    - "tool/osm_pipeline/lib/filter/feldweg_filter.dart"
    - "tool/osm_pipeline/lib/filter/directionality.dart"
    - "tool/osm_pipeline/lib/filter/way_pipeline.dart"
    - "tool/osm_pipeline/lib/scratch/scratch_schema.dart"
    - "tool/osm_pipeline/lib/scratch/scratch_db.dart"
    - "tool/osm_pipeline/test/filter/kfz_filter_test.dart"
    - "tool/osm_pipeline/test/filter/feldweg_filter_test.dart"
    - "tool/osm_pipeline/test/filter/directionality_test.dart"
    - "tool/osm_pipeline/test/filter/way_pipeline_test.dart"
    - "tool/osm_pipeline/test/scratch/scratch_db_test.dart"
  modified:
    - "tool/osm_pipeline/pubspec.yaml (sqlite3 ^2.4.0 dep)"
    - "tool/osm_pipeline/pubspec.lock (regenerated)"
    - "tool/osm_pipeline/bin/osm_pipeline.dart (Stage B wired into run())"

key-decisions:
  - "highway=service excluded from Kfz — re-enters only via Feldweg service=driveway|alley (locked at 04-01, enforced here)"
  - "Implicit-oneway is exactly motorway | motorway_link | trunk_link (trunk itself is NOT — verified in tests)"
  - "oneway=-1 physically reverses node order in NormalizedDirection.nodeIds; downstream stages always treat is_directional=1 as forward-along-stored-order"
  - "surface retained on Feldweg rows only (04-RESEARCH §4); Kfz retention set is highway/name/ref/oneway/maxspeed"
  - "ScratchDb uses INSERT OR IGNORE for nodes_raw (two-pass pass B may see the same node twice across passes / relations)"
  - "Way integrity check runs POST-pass, not per-way during pass A — avoids O(N) per-way DB round-trip"
  - "kExplicitFeldwegHighwayValues constant scopes rejection-reason disambiguation; unknown highway values collapse to highway_class_not_allowlisted"
  - "WayPipeline.readerFactory is injectable (Function returning PbfReader) — enables future isolate parallelism from 04-10 without refactor"

patterns-established:
  - "Filter layer split: highway_class.dart (constants) + kfz_filter.dart (predicate+retention) + feldweg_filter.dart (branch table) + directionality.dart (normalizer) + way_pipeline.dart (streaming orchestrator)"
  - "All four filter primitives are pure Dart, no I/O, no scratch_db dep — trivially unit-testable with synthetic OsmWay values"
  - "Scratch DB wrapper: prepared statements lazy-init, single BEGIN/COMMIT per _batchSize (10 000 rows) window, flush() drains before COMMIT"
  - "Reason-tagged skipped.log format: `{reason_code}\\tway/{osm_id}` — grep-friendly, machine-parseable"

# Metrics
duration: 10min
completed: 2026-07-05
---

# Phase 4 Plan 03: Highway Filter + Directionality Summary

**Stage B of the OSM pipeline shipped — `PbfReader.stream()` from 04-02 is now consumed by `WayPipeline.run()`, which filters ways down to the 14-tag Kfz allowlist + the Feldweg carve-out (track / path+motor_vehicle / service=driveway|alley), normalises directionality (including physical `oneway=-1` reversal + the OSM implicit-oneway rule for motorway|motorway_link|trunk_link), and lands rows in an ephemeral `journal_mode=OFF` scratch SQLite DB alongside a reason-tagged `skipped.log`. 80 new tests (98 sub-package total) all green; end-to-end tiny-fixture smoke run completes in < 1 s.**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-05T17:25:25Z
- **Completed:** 2026-07-05T17:35:38Z
- **Tasks:** 3
- **Files created:** 13 (5 filter/scratch sources + 5 test files + 1 integration test + scratch_schema.dart + way_pipeline_test.dart)
- **Files modified:** 3 (pubspec.yaml, pubspec.lock, bin/osm_pipeline.dart)
- **Tests added:** 80 (from 18 → 98 sub-package tests)

## Accomplishments

- **Filter layer primitives.** Split into four pure-Dart files (each < 100 LOC): `highway_class.dart` (14-tag Kfz + 3-tag implicit-oneway constant sets), `kfz_filter.dart` (predicate + retention), `feldweg_filter.dart` (branch table returning retained-tag subset or null), `directionality.dart` (normaliser returning `NormalizedDirection` with `isDirectional` + possibly-reversed `nodeIds`). No I/O, no scratch_db dep — unit-testable in isolation.
- **`highway=service` exclusion enforced end-to-end.** OSM-02 locked at 04-01; here, `isKfzWay` rejects `service` explicitly (test), and the Feldweg branch is the sole re-entry point (only `service=driveway|alley`, verified in a dedicated test).
- **Implicit-oneway rule verified.** `motorway`, `motorway_link`, `trunk_link` alone are implicit-oneway; `trunk` is NOT (per OSM wiki). Directionality test asserts this explicitly to prevent future drift.
- **Physical `oneway=-1` reversal.** `normalizeDirectionality` returns `nodeIds` in traversal order — for `oneway=-1` ways, that is the REVERSED sequence of raw OSM refs. Downstream stages (pmtiles emission 04-07 per 04-RESEARCH §12 pitfall #7) can treat every `is_directional=1` way as forward-direction without remembering the twist.
- **Scratch SQLite DB.** `ScratchDb.openTempFile()` opens a fresh DB under `Directory.systemTemp/trailblazer_osm_*/scratch.sqlite`, applies the 04-RESEARCH §10 write-optimised pragmas (`page_size=65536` FIRST, then `journal_mode=OFF`, `synchronous=OFF`, `cache_size=-524288`, `temp_store=MEMORY`), and creates `nodes_raw`, `ways_raw`, `relations_raw`, `filter_stats`. `insertWayKfz` / `insertWayFeldweg` / `insertNode` / `insertRelation` / `bumpStat` use prepared statements + batched BEGIN/COMMIT (10 000 rows per flush). `close(deleteFile: true)` disposes prepared statements, closes the DB, and removes the temp directory.
- **Length-prefixed int64 LE BLOB for `node_ids`.** Compact, deterministic across platforms, decode is O(n) with a single `ByteData` view. `encodeNodeIds([1, 2, 3])` → `04 00 00 00 | 01 00 …` (uint32 count + int64 per id, all little-endian).
- **Two-pass way pipeline.** `WayPipeline.run(pbf, scratch)` streams the PBF twice:
  - **Pass A** filters ways: Kfz path calls `normalizeDirectionality` + `retainKfzTags`; Feldweg path calls `feldwegTagsOrNull`; unknown highway values go to `skipped.log` with reason `highway_class_not_allowlisted` (or the more specific `feldweg_missing_motor_vehicle` / `feldweg_service_not_driveway_or_alley` / `no_highway_tag`). Retained ways add their node ids to a `Set<int>` seen-list.
  - **Pass B** re-streams the PBF and writes only the seen-list nodes to `nodes_raw` (`INSERT OR IGNORE` guards against duplicate node ids across primitive groups).
  - **Post-pass** integrity check scans every way in `ways_raw`, decodes its `node_ids` BLOB, and checks each id against `nodes_raw`; ways with any missing node are deleted and logged as `deleted_node_ref` (04-RESEARCH §12 pitfall #4).
- **`highway=road` counter.** Bumped in `filter_stats` on every accepted Kfz way with `highway=road`; a warning fires at run end if the ratio exceeds 0.1 % of total Kfz ways (04-RESEARCH §12 pitfall #9).
- **CLI wired for Stage B.** `bin/osm_pipeline.dart` opens the scratch DB, runs `WayPipeline`, prints a one-line filter summary, and disposes the scratch DB via `finally`. `dart run tool/osm_pipeline/bin/osm_pipeline.dart --pbf=tool/osm_pipeline/test/fixtures/tiny.osm.pbf` completes in ~0.6 s and prints:
  ```
  [info] Stage B (highway filter): 1 Kfz, 1 Feldweg, 14 nodes, 2 rejected (highway=road: 0, deleted-node-refs: 0).
  ```
- **Tests.** 80 new (from 18 → 98 sub-package tests total).
  - `kfz_filter_test.dart` — 24 parameterised acceptance cases (all 14 allowlist tags) + 11 rejection cases (`service`, `footway`, `cycleway`, `pedestrian`, `bridleway`, `track`, `path`, `construction`, `proposed`, made-up value, no-highway) + 2 retention tests.
  - `feldweg_filter_test.dart` — 15 cases covering all three branches (track, path with `motor_vehicle=yes|permissive|no|private`, service with `driveway|alley|parking_aisle|none`) + non-drivable rejections (footway/cycleway/pedestrian/bridleway) + missing/unrecognised highway.
  - `directionality_test.dart` — 10 cases covering explicit `yes`/`-1`/`no` (including reversal from `[1,2,3]` → `[3,2,1]`) + missing tag with implicit-oneway for `motorway`/`motorway_link`/`trunk_link` and NOT for `trunk`/`primary`/`residential`.
  - `way_pipeline_test.dart` — 4 integration tests on the tiny fixture: entity counts, Kfz spot-check, Feldweg spot-check, `skipped.log` contents.
  - `scratch_db_test.dart` — 6 tests for open+pragmas, Kfz insert+read, Feldweg insert+read, bumpStat, encodeNodeIds round-trip, empty-list edge case.

## Task Commits

Each task committed atomically; no `git add -A`:

1. **Task 1: Filter primitives + directionality normalizer** — `2eba791` (feat)
   - `lib/filter/highway_class.dart`, `lib/filter/kfz_filter.dart`, `lib/filter/feldweg_filter.dart`, `lib/filter/directionality.dart`
2. **Task 2: Scratch SQLite schema + writer** — `0a88b3b` (feat)
   - `lib/scratch/scratch_schema.dart`, `lib/scratch/scratch_db.dart`, `test/scratch/scratch_db_test.dart`
   - `pubspec.yaml` (+ `sqlite3: ^2.4.0`), `pubspec.lock` regenerated
3. **Task 3: Two-pass way_pipeline + tests + CLI wire** — `b45e520` (feat)
   - `lib/filter/way_pipeline.dart`, 4 test files under `test/filter/`, `bin/osm_pipeline.dart` (Stage B wired)

**Plan metadata commit:** to be created after this summary lands.

## Files Created/Modified

**Created (13):**

- `tool/osm_pipeline/lib/filter/highway_class.dart` — `kKfzHighwayTags` (14) + `kImplicitOnewayKfzTags` (3) constant sets with sourcing comments
- `tool/osm_pipeline/lib/filter/kfz_filter.dart` — `isKfzWay` predicate + `retainKfzTags` retention subset
- `tool/osm_pipeline/lib/filter/feldweg_filter.dart` — `feldwegTagsOrNull` branch on track/path/service
- `tool/osm_pipeline/lib/filter/directionality.dart` — `NormalizedDirection` class + `normalizeDirectionality` (yes/-1/no + implicit)
- `tool/osm_pipeline/lib/filter/way_pipeline.dart` — `WayPipeline.run` two-pass orchestrator + `WayPipelineStats` result type + `kExplicitFeldwegHighwayValues` rejection-reason helper set
- `tool/osm_pipeline/lib/scratch/scratch_schema.dart` — `kScratchDdl` list of 4 CREATE TABLE statements
- `tool/osm_pipeline/lib/scratch/scratch_db.dart` — `ScratchDb` wrapper class + `encodeNodeIds` / `decodeNodeIds` BLOB helpers
- `tool/osm_pipeline/test/filter/kfz_filter_test.dart` — parameterised over all 14 accepted tags + 10 rejections + 2 retention tests
- `tool/osm_pipeline/test/filter/feldweg_filter_test.dart` — every carve-out branch verified
- `tool/osm_pipeline/test/filter/directionality_test.dart` — 10 cases across explicit + implicit rules
- `tool/osm_pipeline/test/filter/way_pipeline_test.dart` — end-to-end 4 tests on tiny fixture
- `tool/osm_pipeline/test/scratch/scratch_db_test.dart` — 6 round-trip + BLOB tests

**Modified (3):**

- `tool/osm_pipeline/pubspec.yaml` — added `sqlite3: ^2.4.0` under `dependencies` (alphabetized between `path` and — future — new deps)
- `tool/osm_pipeline/pubspec.lock` — regenerated by `dart pub get`; picked up `sqlite3 2.9.4` + transitive `ffi 2.2.0`
- `tool/osm_pipeline/bin/osm_pipeline.dart` — `run()` now opens `ScratchDb`, invokes `WayPipeline`, prints stats, disposes via `finally`

## Decisions Made

See STATE.md "Plan 04-03" decision block for the full rationale. Key highlights:

- **Filter layer split into 5 pure files.** Constants, predicates, normalisers, and orchestrator are separate so unit tests can synthesise `OsmWay` values without touching disk or scratch DB.
- **Kfz retention set matches CONTEXT exactly.** `highway`, `name`, `ref`, `oneway`, `maxspeed`. `surface` is Feldweg-only (04-RESEARCH §4). Non-Latin `name:*` tags are dropped by construction (pitfall #8).
- **`oneway=-1` physically reverses node order.** Downstream never needs to know the twist happened; `is_directional=1` always means forward-along-stored-order.
- **`ScratchDb` uses prepared statements + 10 000-row batched COMMITs.** Balances throughput vs. peak memory. `INSERT OR IGNORE` on `nodes_raw` guards against multi-pass node duplication.
- **Integrity check is a single POST-pass scan.** Avoids O(N) per-way DB round-trip during Pass A. Missing-node ways are dropped, not silently kept.
- **`readerFactory` injectable on `WayPipeline`.** Prepares 04-10 for isolate-based parallelism without a refactor.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Analyzer info-level lints on new files**

- **Found during:** Tasks 1, 2, 3 (running `dart analyze` in the sub-package)
- **Issue:** `very_good_analysis` enforces `prefer_constructors_over_static_methods`, `cascade_invocations`, `prefer_if_elements_to_conditional_expressions`, `avoid_redundant_argument_values`, `require_trailing_commas`, `lines_longer_than_80_chars`, `comment_references` at info level. First pass produced 10 analyzer notices across the new files. The pre-push hook runs `flutter analyze --fatal-infos`, so info-level issues would block push.
- **Fix:**
  - `lib/scratch/scratch_db.dart`: added `// ignore: prefer_constructors_over_static_methods` above `ScratchDb.openTempFile` (matches Plan 04-01 static-method pattern); rewrote `isDirectional ? 1 : 0` as `if (isDirectional) 1 else 0`; folded `ByteData(...); buffer.setUint32(...);` into a single cascaded expression; consolidated pragma statements into one cascade.
  - `lib/filter/way_pipeline.dart`: rewrote `[reader]` doc reference to `[readerFactory]`; removed unused `feldwegCount` local (final count is read back from DB anyway).
  - Test files: added trailing commas at `expect(...)` call sites; broke a 81-char test name into a shorter one; dropped a redundant `refs: const [1, 2, 3]` argument (matches the parameter's default).
- **Files modified:** `lib/scratch/scratch_db.dart`, `lib/filter/way_pipeline.dart`, `test/filter/kfz_filter_test.dart`, `test/filter/feldweg_filter_test.dart`, `test/filter/directionality_test.dart`
- **Verification:** `dart analyze` inside `tool/osm_pipeline/` → "No issues found!". `flutter analyze` at repo root shows 6 unrelated warnings from `tool/osm_pipeline/lib/admin/geometry.dart` — those are untracked files owned by parallel Plan 04-04's agent and out of my lane per the Wave 3 parallelism warning.
- **Committed in:** `2eba791` (Task 1 filters), `0a88b3b` (Task 2 scratch), `b45e520` (Task 3 orchestrator + tests)

---

**Total deviations:** 1 auto-fixed (lint hygiene across three commits). No functional deviations from the plan — the two-pass shape, the Kfz/Feldweg allowlists, the directionality rules, and the scratch pragmas are exactly as specified in the PLAN + RESEARCH. No architectural surprises.

## Issues Encountered

- **`flutter analyze` at repo root reports 6 issues in `tool/osm_pipeline/lib/admin/geometry.dart`.** Those files are untracked in my working tree and belong to Plan 04-04 (the parallel Wave 3 agent). Per the Wave 3 lane discipline in my execution prompt ("You must NOT touch: admin_regions scratch code"), I did not modify or stage them. Plan 04-04's SUMMARY will need to resolve those lints in its own commits.
- **CRLF line-ending warnings on Windows.** Same as prior plans — Git will convert LF to CRLF on the working tree. No action needed.

## User Setup Required

None. `sqlite3 ^2.4.0` ships prebuilt binaries for Windows/macOS/Linux via the `sqlite3` package's native asset bundle — no manual DLL install, no Visual Studio Build Tools prerequisite. Verified locally on the Windows dev box.

## Next Phase Readiness

**Ready:**

- **04-05 (segmented intersection):** consumes `ways_raw` + `nodes_raw` from the scratch DB. Node coverage is guaranteed complete post-integrity-check — no dangling refs. `is_directional` + `oneway_tag` columns match the schema RESEARCH §5 specifies.
- **04-04 (admin_regions):** shares `ScratchDb` — the `relations_raw` table shape is defined here (04-04 owns the writer for admin `type=multipolygon` / `type=boundary` relations). `relations_raw.members` BLOB layout is Plan 04-04's contract.
- **04-06 (osm.sqlite emit):** `ways_raw` schema + `is_directional` semantics are locked. Downstream reads `source='kfz'` for coverage-counting rows and `source='feldweg'` for see-only rows.
- **04-07 (pmtiles emit):** `is_directional=1` always means forward-along-stored-order — pitfall #7 is closed here, not deferred.
- **04-09 (Berlin smoke):** pipeline stub already runs end-to-end on the tiny fixture; Berlin bbox will exercise the same code path with real data.
- **04-10 (full-Germany isolate parallelism):** `WayPipeline.readerFactory` is injectable — a pool of `PbfReader` instances can be swapped in without touching `WayPipeline` logic.

**Blockers / concerns:**

- **None new from this plan.**
- **Parallel Plan 04-04's untracked admin/ files** carry 6 analyzer info-level notes. Those are 04-04's SUMMARY-time cleanup; my lane is clean.
- **WSL2 tippecanoe install (Plan 04-07 concern)** unchanged.
- **Phase 3 in-car verification** unchanged (deferred).

---
*Phase: 04-osm-pipeline*
*Completed: 2026-07-05*
