---
id: 04-06
phase: 04-osm-pipeline
plan: 06
title: osm.sqlite Finalization
status: complete
subsystem: osm-pipeline
tags: [osm, sqlite, rtree, wkb, denormalization, version-stamp, orchestrator]
requires: [04-01, 04-02, 04-03, 04-04, 04-05]
provides:
  - osm.sqlite schema (final, on-disk)
  - LineString-WKB geometry per way
  - denormalized admin_region_id_l{2,4,6,8} columns
  - way_admin cross-border join table
  - ways_rtree + ways_rtree_lookup R-Tree
  - admin_regions + admin_regions_rtree
  - metadata table + PRAGMA user_version stamp
  - pipeline_orchestrator (Stages B..E wired end-to-end)
affects: [04-07, 04-08, 05, 07, 08, 10]
tech-stack:
  added:
    - crypto ^3.0.0
  patterns:
    - preflight measurement gate (throws PipelineIoError / PipelineArgsError)
    - denormalized L2..L8 admin roll-up (single-row wholly-contained → column; keep in way_admin otherwise)
    - inline LineString-WKB geometry_wkb blob per way (no N+1 join to a nodes table)
    - per-segment R-Tree default, per-way fallback under measurement recommendation
    - metadata INSERT OR REPLACE (idempotent re-writes)
    - streamed PBF SHA-256 (openRead().transform(sha256).single) — no full read into RAM
key-files:
  created:
    - tool/osm_pipeline/lib/output/osm_sqlite_schema.dart
    - tool/osm_pipeline/lib/output/osm_sqlite_writer.dart
    - tool/osm_pipeline/lib/output/rtree_builder.dart
    - tool/osm_pipeline/lib/output/version_stamp.dart
    - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
    - tool/osm_pipeline/test/output/osm_sqlite_writer_test.dart
    - tool/osm_pipeline/test/output/rtree_builder_test.dart
    - tool/osm_pipeline/test/output/version_stamp_test.dart
    - tool/osm_pipeline/test/output/pipeline_orchestrator_test.dart
  modified:
    - tool/osm_pipeline/bin/osm_pipeline.dart
    - tool/osm_pipeline/pubspec.yaml
    - tool/osm_pipeline/pubspec.lock
metrics:
  duration: ~35 min
  completed: 2026-07-06
  tests_added: 21
  tests_total_pipeline: 177
  commits: 4
---

# Phase 4 Plan 06: osm.sqlite Finalization Summary

**One-liner:** Final on-disk `osm.sqlite` produced end-to-end from Berlin PBF in 2 min 19 s, 84.8 MB, WAL journal, denormalized L2..L8 admin columns + per-segment R-Tree + 7-row metadata block + `PRAGMA user_version = 1`.

## Objective

Produce the final on-disk `osm.sqlite` artifact — final schema, R-Tree spatial index, version stamp, denormalization roll-up per the locked 04-05 Berlin measurement variant (L2..L8 denormalized + way_admin cross-border), and a Berlin-scope proof it works end-to-end.

## Locked variant

Per user decision (2026-07-06, commit `b7540ce`) SC4 was relaxed **200 MB → 800 MB** based on the 04-05 Berlin measurement. The chosen variant is:

- **Denormalized `admin_region_id_l{2,4,6,8}` columns on `ways`** for wholly-contained ways.
- **`way_admin` table** for cross-border ways only (sub-segment rows with `fraction_start` / `fraction_end`).
- **L9 and L10 dropped** from denormalized columns per slim projection (Berlin measurement projected ~696 MB Germany with L2..L8, vs ~775 MB with L2..L10).

The plan text's "SC4 lock checkpoint" task was downgraded to a no-op documentation task — the decision was final before 04-06 started.

## Tasks completed

### Task 2 (committed first — Task 1 depends on it) — R-Tree granularity selector + builder

Commit: `5d78f77 feat(04-06): R-Tree granularity selector + builder`

- `RtreeBuilder` class emits rows into `ways_rtree` + `ways_rtree_lookup`.
- `RtreeGranularity.perSegment` (default): one row per two-point segment; `segment_idx` = 0-based index into the way's polyline.
- `RtreeGranularity.perWay` (fallback): one row per way; `segment_idx = -1` sentinel.
- Zero-length segments (duplicate consecutive nodes) are skipped so degenerate ways don't bloat the R-Tree.
- `loadFromMeasurement(File)` reads 04-05-BERLIN-MEASUREMENT.md and returns `perWay` iff the file mentions `per-way`, else defaults to `perSegment`.
- **7 unit tests:** per-segment counts, per-way sentinel, bbox arithmetic (SQLite R-Tree stores single-precision floats — tests use ~1e-4 tolerance), degenerate lines, R-Tree query round-trip, `loadFromMeasurement` branches.

### Task 1 — Final osm.sqlite schema + writer

Commit: `8d232ca feat(04-06): final osm.sqlite schema + writer with L2..L8 denormalization`

- `osm_sqlite_schema.dart` — const list of PRAGMA + DDL statements:
  - Runtime PRAGMAs: `page_size = 4096`, `journal_mode = WAL`, `synchronous = NORMAL` (matches 04-RESEARCH §10 output pragmas).
  - Tables: `metadata`, `ways`, `admin_regions`, `way_admin`, `ways_rtree_lookup`.
  - Virtual tables: `admin_regions_rtree`, `ways_rtree` (both `USING rtree`, float — not `rtree_i32`).
  - Indexes: `idx_ways_source_counting`, `idx_ways_highway`, `idx_admin_regions_level`, `idx_way_admin_region`, `idx_ways_rtree_lookup_way`.
- `ways` schema locks the L2..L8 denormalization: `admin_region_id_l2 / l4 / l6 / l8 INTEGER`. L9 and L10 are absent by construction.
- `ways.geometry_wkb` is a **LineString WKB blob** — one row per way, inline geometry. Phase 5 matcher reads via a single indexed lookup, no join to a `nodes` table.
- `OsmSqliteWriter.write({scratch, outFile, granularity})`:
  1. Preflight gate on 04-05-BERLIN-MEASUREMENT.md (missing → `PipelineIoError`; "not empirically verified" → `PipelineArgsError` unless `allowUnverifiedMeasurement=true`).
  2. Opens fresh sqlite3 file, applies PRAGMAs + DDL.
  3. Copies `admin_regions_raw → admin_regions` (bulk, single transaction) and seeds `admin_regions_rtree` from the bbox columns.
  4. Iterates `ways_raw`, resolves each node id via a prepared `nodes_raw` lookup, encodes LineString WKB, sums haversine length.
  5. For each way, groups `way_admin_raw` rows by (way_id, level). If exactly one row exists at a level with `fraction_start ≤ 1e-9 AND fraction_end ≥ 1 − 1e-9`, rolls that row's `region_id` into `admin_region_id_l{level}` and marks it for removal from `way_admin_raw`.
  6. Delegates R-Tree emission to `RtreeBuilder`.
  7. Post-roll-up: DELETEs the rolled-up rows from `way_admin_raw`; then bulk-copies the survivors into `way_admin`.
  8. `PRAGMA wal_checkpoint(TRUNCATE)` before sampling final on-disk size.
- **8 unit tests:** 4 preflight branches, end-to-end schema/roll-up, cross-border no-rollup, per-way granularity, PRAGMA verification, WKB round-trip.

### Task 3 — Version stamp + orchestrator + Berlin proof

Commit: `4bf5415 chore(04-06): add crypto ^3.0.0 for PBF SHA-256 version stamp`
Commit: `b26f1f6 feat(04-06): version stamp + pipeline orchestrator wiring + Berlin proof`

- `VersionStamp` writes the 7 canonical metadata keys (04-RESEARCH §9) via `INSERT OR REPLACE`:
  - `pbf_date` — ISO-8601 UTC from PBF header's `osmosis_replication_timestamp` (0 fallback when the field is absent).
  - `pbf_source` — basename of the source PBF.
  - `pbf_sha256` — full hex SHA-256 (streamed from disk via `openRead().transform(sha256).single`).
  - `bbox` — `--bbox` argument as-is, or `*` when null.
  - `pipeline_schema_version` — mirrors `PRAGMA user_version`.
  - `pipeline_git_sha` — `git rev-parse HEAD` output, or `unknown` on any failure.
  - `generated_at` — pipeline run start UTC.
- `pipeline_orchestrator.dart` — `runPipeline({pbf, outDir, bbox, allowUnverifiedMeasurement, measurementFile, gitShaResolver, nowUtc})` wires Stage B (WayPipeline) → Stage C (extractAdminRegions) → Stage D (buildWayAdminJoin) → Stage E (OsmSqliteWriter + VersionStamp). Stages F/G land in wave 6 (04-07/08) and are logged as stubs here.
- `bin/osm_pipeline.dart` rewritten to invoke `runPipeline`; added `--out-dir` and `--allow-unverified-measurement` CLI flags.
- **8 tests:** 5 for `VersionStamp` (7-row write, null-bbox → '*', REPLACE idempotency, `defaultGitShaResolver` doesn't throw, `basenameOf`); 3 e2e via `runPipeline` on the tiny fixture (schema/tables/metadata/counts, preflight rejection of stub, `allowUnverifiedMeasurement` override).

## Berlin end-to-end proof

Ran the pipeline against the real Berlin PBF used by 04-05:

```
$ dart run tool/osm_pipeline/bin/osm_pipeline.dart \
    --pbf=C:/Users/I551358/Downloads/berlin-260705.osm.pbf \
    --out-dir=tool/osm_pipeline/out/berlin-osm-sqlite
```

**Result: OK in 2 min 19 s.**

| Metric | Value |
|---|---:|
| Kfz ways written | 91 707 |
| Feldweg ways written | 84 860 |
| Total ways | **176 567** |
| Admin regions | **118** (all L4..L10 for Berlin — no L2 in extract) |
| way_admin rows (cross-border only) | 180 795 |
| ways_rtree rows (per-segment) | 555 920 |
| Metadata rows | 7 |
| **osm.sqlite size** | **84 844 544 bytes (≈ 84.8 MB)** — informational; SC4 is Germany-scale |
| PBF SHA-256 | `c96a067a18ebf7ec2d5f513cf43624000ddb3860fe9928bc68d5f22e9e82f775` ✅ matches 04-05 |
| PBF replication timestamp | `2026-07-05T20:21:10.000Z` (Geofabrik header) |
| `PRAGMA user_version` | `1` (= `pipelineSchemaVersion`) |
| `PRAGMA journal_mode` | `wal` |

**Sanity queries verified via a smoke script:**

- `SELECT COUNT(*)` on every table returns the expected non-zero row counts.
- `PRAGMA user_version` returns `1`.
- All 7 metadata rows present with the expected keys.
- **R-Tree spot-check at Brandenburg Gate (lat 52.5163, lng 13.3777, ±0.001°):** 85 candidate rows returned. R-Tree is queryable.
- **Sample way LineString round-trips:** `decodeLineStringWkb` on a random way's `geometry_wkb` returns 20 points; `length_m` = 214.1 m for that residential Waldstraße segment — realistic urban block length.
- The file opens cleanly under `sqlite3` package's `sqlite3.open()` — same C library Drift's `NativeDatabase` uses on the app side. No Drift import needed to prove compatibility; `sqlite3` package IS the underlying engine.

## Test results

- **Pipeline test suite: 177/177 green** (was 156 pre-04-06; +21 tests).
- `dart analyze` (tight loop): clean.
- `flutter analyze` (repo root, pre-push tier): clean (258 s).

## Decisions made

1. **SC4 lock checkpoint downgraded to a no-op documentation acknowledgment.** User decision from 2026-07-06 (commit `b7540ce`) predated 04-06 execution; the plan text's checkpoint task was implicit. The final variant is fixed at L2..L8 denormalized + way_admin (per 04-05 recommendation, ~696 MB projected Germany).
2. **`crypto ^3.0.0` chosen over hand-rolled SHA-256.** First-party Dart package, prebuilt binaries, streamed API (`openRead().transform(sha256).single`) — zero extra install burden.
3. **PBF SHA-256 streamed via a stream transformer, not `readAsBytes`.** Berlin PBF is 94 MB, full Germany PBF is ~4 GB — reading into RAM is disqualifying at Germany scale.
4. **`ways.geometry_wkb` = LineString WKB, not a `nodes` join table.** Matcher's `findWaysNear` returns candidates then reads geometry — single-row lookup, no join, matches Phase 5 SC2 p95 < 30 ms budget. This is the intent that had "way_admin_raw survives to osm.sqlite" replaced with "cross-border rows only survive" once denormalization landed.
5. **`INSERT OR REPLACE` on metadata.** Idempotent re-writes match the "regenerate the DB and stamp version again" workflow; PK still enforces one row per key.
6. **R-Tree defaults to per-segment.** 04-05 Berlin measurement did not recommend per-way; `loadFromMeasurement` returns per-way only if the file mentions `per-way`, else defaults to per-segment. Berlin produced 555 920 rtree rows over 176 567 ways — ~3.15 segments/way, healthy density for tight bbox queries.
7. **`PRAGMA wal_checkpoint(TRUNCATE)` before sampling final on-disk size.** Without this the WAL sidecar file holds most of the payload and `File.lengthSync` returns a misleading value. Runs at end of both the writer and the version-stamp phases.
8. **R-Tree stores single-precision floats.** Tests that assert bbox equality use ~1e-4 tolerance — spec-level fact of SQLite's `rtree` module.
9. **CLI splits its own arg parser.** `bin/osm_pipeline.dart` peels off `--allow-unverified-measurement` and `--out-dir` before delegating `--pbf` / `--bbox` to `ParsedArgs.parse` — keeps ParsedArgs unchanged (04-01 boundary) while adding two flags 04-06 needs.

## Deviations from Plan

### Auto-fixed (Rule 2 — critical missing functionality)

**1. Preflight gate implementation gained a `measurementFile` injection point on the orchestrator.**

- **Found during:** Task 3 test authoring.
- **Issue:** `runPipeline` originally hard-coded `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md` — untestable without polluting the real repo file.
- **Fix:** Added an optional `measurementFile` parameter with the real file as default. Tests inject a stub-or-good `File(...)` via the temp directory.
- **Files:** `tool/osm_pipeline/lib/output/pipeline_orchestrator.dart`
- **Commit:** `b26f1f6`

**2. PBF SHA-256 streaming API.**

- **Found during:** Task 3 orchestrator wiring.
- **Issue:** Berlin PBF is 94 MB; full Germany PBF ~4 GB. Reading fully into RAM would break at Germany scale.
- **Fix:** Streamed via `file.openRead().transform(crypto.sha256).single`.
- **Files:** `tool/osm_pipeline/lib/output/pipeline_orchestrator.dart`
- **Commit:** `b26f1f6`

### Plan-text deltas (documentation-only)

- Plan text said the SC4-lock checkpoint should exist. Per user direction (this execution context) it was downgraded to a no-op since the decision was already made in commit `b7540ce`.
- Plan text said the writer should write to `Directory.current/out/osm.sqlite`. Implementation added an explicit `--out-dir` CLI flag with `out/` as the default — testable + explicit.
- Plan text said `way_admin` "no row exists for a wholly-contained (way, region, level) pair once denormalization has been rolled up". Implementation delivers this literally: rolled-up rows are DELETEd from `way_admin_raw` before the survivors are bulk-copied into `way_admin`.

## Follow-ups / handoffs

- **04-07 (wave 6, Stage F): GeoJSONSeq + tippecanoe → `germany-base.pmtiles`.** Orchestrator has a `Logger.info` stub at the correct seam; 04-07 replaces the stub with a real `runPmtilesStage()` call.
- **04-08 (wave 6, Stage G): pmtiles metadata + style rewrite.** Same seam pattern.
- **Phase 5 integrity check** must read `PRAGMA user_version` and cross-check against the pmtiles metadata (also stamped with `pipeline_schema_version` in 04-08). Current schema is version 1.
- **Full Germany run is the SC4 verifier.** Berlin is 84.8 MB; slim projection puts Germany at ~696 MB (well under 800 MB SC4). A real Germany run is Phase 4 close-out territory (04-10).

## SC/must_haves alignment

| Must-have | Status |
|---|---|
| WAL journal, synchronous=NORMAL, page_size=4096 | ✅ verified via PRAGMA queries in test + Berlin proof |
| PRAGMA user_version = pipelineSchemaVersion (1) | ✅ verified in Berlin osm.sqlite |
| 7 metadata rows with expected keys | ✅ verified (bbox, pbf_date, pbf_sha256, pbf_source, pipeline_schema_version, pipeline_git_sha, generated_at) |
| ways table with L2..L8 denormalized columns | ✅ (L9/L10 intentionally dropped per 04-05 recommendation) |
| way_admin holds cross-border rows only after roll-up | ✅ Berlin: 180 795 rows survived; wholly-contained rolled to columns |
| R-Tree (per-segment default) | ✅ Berlin: 555 920 rows; queryable within tight bbox |
| admin_regions + admin_regions_rtree promoted from scratch | ✅ Berlin: 118 rows both tables |
| Berlin end-to-end run produces a valid osm.sqlite | ✅ 84.8 MB, opens under sqlite3.open, smoke queries pass |
