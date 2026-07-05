---
id: 04-06
phase: 04-osm-pipeline
plan: 06
type: execute
wave: 5
depends_on: [04-05]
files_modified:
  - tool/osm_pipeline/lib/output/osm_sqlite_schema.dart
  - tool/osm_pipeline/lib/output/osm_sqlite_writer.dart
  - tool/osm_pipeline/lib/output/rtree_builder.dart
  - tool/osm_pipeline/lib/output/version_stamp.dart
  - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
  - tool/osm_pipeline/bin/osm_pipeline.dart
  - tool/osm_pipeline/test/output/osm_sqlite_writer_test.dart
  - tool/osm_pipeline/test/output/rtree_builder_test.dart
  - tool/osm_pipeline/test/output/version_stamp_test.dart
autonomous: true
requirements: [OSM-05, OSM-07]

must_haves:
  truths:
    - "osm.sqlite is created with WAL journal, synchronous=NORMAL, page_size=4096, matching 04-RESEARCH §10 output-DB pragmas"
    - "PRAGMA user_version returns pipelineSchemaVersion from tool/osm_pipeline/lib/schema.dart (currently 1)"
    - "metadata table contains rows for pbf_date, pbf_source (basename), pbf_sha256, bbox (or '*'), pipeline_schema_version, pipeline_git_sha (or 'unknown' if git absent), generated_at (ISO 8601 UTC)"
    - "ways table carries admin_region_id_L{2,4,6,8,9,10} INTEGER columns per the 04-05 measurement recommendation (or the fallback subset if measurement rejected some levels)"
    - "way_admin table holds cross-border sub-segment rows (way_id, region_id, admin_level, fraction_start, fraction_end); no row exists for a wholly-contained (way, region, level) pair once denormalization has been rolled up"
    - "SQLite R*Tree virtual table ways_rtree indexes per-segment bbox rows (way_id, segment_idx, min_lat, max_lat, min_lng, max_lng); default is per-segment, downgraded to per-way if the row-count measurement in 04-05 said so"
    - "admin_regions + admin_regions_rtree tables promoted from scratch (04-04) into the final osm.sqlite unchanged"
    - "Berlin-scope end-to-end run produces an osm.sqlite file that opens under `sqlite3` and passes a smoke SELECT: at least 1 way row, 1 admin_regions row, 1 ways_rtree row"
  artifacts:
    - path: "tool/osm_pipeline/lib/output/osm_sqlite_schema.dart"
      provides: "CREATE statements + PRAGMA writes for the final osm.sqlite"
    - path: "tool/osm_pipeline/lib/output/osm_sqlite_writer.dart"
      provides: "Copies scratch tables into final osm.sqlite, applies the denormalization roll-up per 04-05 recommendation, computes way length"
    - path: "tool/osm_pipeline/lib/output/rtree_builder.dart"
      provides: "Builds ways_rtree at the granularity chosen by 04-05 measurement (per-segment default; per-way fallback)"
  key_links:
    - from: "tool/osm_pipeline/lib/output/pipeline_orchestrator.dart"
      to: "tool/osm_pipeline/lib/output/osm_sqlite_writer.dart"
      via: "invoked as Stage C in the pipeline"
      pattern: "OsmSqliteWriter.write"
    - from: "tool/osm_pipeline/lib/output/osm_sqlite_writer.dart"
      to: ".planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md"
      via: "reads the Recommendation section to pick strategy at build time (executor supplies decision via a build const or CLI flag; default is denormalized L2..L10)"
      pattern: "AdminDenormStrategy"
---

## Goal

Produce the final on-disk `osm.sqlite` artifact — schema, R-Tree, version stamp, denormalization roll-up per 04-05 measurement, and Berlin-scope proof it works end-to-end.

## Context

- 04-RESEARCH.md §7 final strategy: denormalized `admin_region_id_L{2,4,6,8,9,10}` on `ways` for wholly-contained ways; `way_admin` join table for cross-border sub-segments. 04-05 measurement confirms/adjusts.
- 04-RESEARCH.md §8: R-Tree over per-segment rows (default) with per-way fallback if measurement projects > 150 MB.
- 04-RESEARCH.md §9: version stamp = `PRAGMA user_version` + `metadata` table. Keys pinned in §9.
- 04-RESEARCH.md §10 output pragmas: `journal_mode=WAL`, `synchronous=NORMAL`, `page_size=4096`.
- 04-06 promotes scratch tables (`ways_raw`, `nodes_raw`, `admin_regions_raw`, `way_admin_raw` from plans 04-03/04/05) into final tables. Renaming: `ways_raw` → `ways`, `admin_regions_raw` → `admin_regions`, `way_admin_raw` → `way_admin`. `nodes_raw` does NOT survive — nodes are inlined into way geometry BLOBs (see Task 1).
- Way geometry storage: each row in `ways` carries a `geometry_wkb` BLOB (LineString WKB) instead of separately joining against `nodes`. This keeps the matcher's read path to a single indexed lookup — no N+1 across a nodes table.
- **04-07 runs in wave 6, AFTER this plan (04-06 = wave 5).** 04-06 creates a stub Stage D call in `pipeline_orchestrator.dart`; 04-07 replaces the stub with the real GeoJSONSeq → pmtiles pipeline. They share the orchestrator file but run sequentially, so no merge conflict.

## Tasks

<task type="auto">
  <name>Task 1: Final osm.sqlite schema + writer</name>
  <files>
    tool/osm_pipeline/lib/output/osm_sqlite_schema.dart
    tool/osm_pipeline/lib/output/osm_sqlite_writer.dart
  </files>
  <intent>Emit the on-disk schema and copy scratch rows to final tables with denormalization + inline geometry.</intent>
  <action>
    **`osm_sqlite_schema.dart`** — CREATE + PRAGMA statements as a `const List<String>`. Schema:

    ```sql
    -- Runtime pragmas
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA page_size = 4096;
    PRAGMA user_version = <pipelineSchemaVersion>;   -- filled at write time

    -- Metadata (04-RESEARCH §9)
    CREATE TABLE metadata (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    -- Ways (Kfz + Feldweg unified)
    CREATE TABLE ways (
      way_id             INTEGER PRIMARY KEY,
      source             TEXT NOT NULL,       -- 'kfz' | 'feldweg'
      is_counting        INTEGER NOT NULL,    -- 1 | 0
      is_directional     INTEGER NOT NULL,    -- 0 | 1  (post-normalization, forward-along-nodes)
      oneway_tag         TEXT,                -- raw, debugging
      highway            TEXT NOT NULL,
      name               TEXT,
      ref                TEXT,
      maxspeed           TEXT,
      surface            TEXT,                -- Feldweg only
      length_m           REAL NOT NULL,       -- haversine sum along stored geometry
      geometry_wkb       BLOB NOT NULL,       -- LineString WKB, one row per way
      admin_region_id_l2  INTEGER,
      admin_region_id_l4  INTEGER,
      admin_region_id_l6  INTEGER,
      admin_region_id_l8  INTEGER,
      admin_region_id_l9  INTEGER,            -- may be dropped if 04-05 recommends
      admin_region_id_l10 INTEGER
    );
    CREATE INDEX idx_ways_source_counting ON ways(source, is_counting);
    CREATE INDEX idx_ways_highway ON ways(highway);

    -- Admin regions
    CREATE TABLE admin_regions (
      region_id       INTEGER PRIMARY KEY,
      osm_relation_id INTEGER NOT NULL,
      admin_level     INTEGER NOT NULL,       -- 2 | 4 | 6 | 8 | 9 | 10
      name            TEXT NOT NULL,
      geometry_wkb    BLOB NOT NULL,
      bbox_minlat     REAL NOT NULL, bbox_maxlat REAL NOT NULL,
      bbox_minlng     REAL NOT NULL, bbox_maxlng REAL NOT NULL
    );
    CREATE INDEX idx_admin_regions_level ON admin_regions(admin_level);
    CREATE VIRTUAL TABLE admin_regions_rtree USING rtree(
      id, min_lat, max_lat, min_lng, max_lng
    );

    -- way_admin join for cross-border ways
    CREATE TABLE way_admin (
      way_id         INTEGER NOT NULL,
      region_id      INTEGER NOT NULL,
      admin_level    INTEGER NOT NULL,        -- 2 | 4 | 6 | 8 | 9 | 10
      fraction_start REAL NOT NULL,
      fraction_end   REAL NOT NULL,
      PRIMARY KEY (way_id, region_id, admin_level, fraction_start)
    ) WITHOUT ROWID;
    CREATE INDEX idx_way_admin_region ON way_admin(region_id, admin_level);

    -- R-Tree over per-segment (default) or per-way rows
    CREATE VIRTUAL TABLE ways_rtree USING rtree(
      id,                    -- rowid; composite (way_id, segment_idx) encoded
      min_lat, max_lat,
      min_lng, max_lng
    );
    -- Companion table because SQLite rtree stores only bbox — need way_id lookup:
    CREATE TABLE ways_rtree_lookup (
      rtree_id    INTEGER PRIMARY KEY,
      way_id      INTEGER NOT NULL,
      segment_idx INTEGER NOT NULL             -- 0-based; -1 if per-way granularity
    );
    CREATE INDEX idx_ways_rtree_lookup_way ON ways_rtree_lookup(way_id);
    ```

    Node: SQLite `rtree` (not `rtree_i32`) — 04-RESEARCH §8 explicitly rejects int-scaled lat/lng.

    Denormalization strategy source: read from `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md` at plan-execution time. Parse the "**Recommendation:**" line. If it says "L2..L10", keep all six columns. If it says "drop L9/L10", omit those two CREATE-column clauses. If it says "join-table-only", omit ALL six admin_region_id columns and rely entirely on the way_admin table.

    **HARD GATE (see Deviation Handling):** if `04-05-BERLIN-MEASUREMENT.md` does not exist, OR contains the phrase "not empirically verified", 04-06 REFUSES to execute and returns to the user with an actionable error. Do NOT silently fall back to the L2..L10 default. The whole point of the measurement (04-RESEARCH §7: "Do NOT lock a schema before running the Berlin-bbox smoke and scaling") is that we don't guess.

    **`osm_sqlite_writer.dart`** — the copy-and-rollup logic:

    0. **Preflight:** open `04-05-BERLIN-MEASUREMENT.md`. If the file is absent, throw a `PipelineError('04-06 blocked: 04-05-BERLIN-MEASUREMENT.md missing. Run tool/osm_pipeline/bin/measure_berlin_row_count.dart with a real Berlin PBF first (see 04-05 Task 3).')`. If the file contains "not empirically verified", throw a `PipelineError('04-06 blocked: measurement is a stub, not empirically verified. Rerun 04-05 Task 3 with a real Berlin PBF, OR pass --allow-unverified-measurement to explicitly override (records the risk in the SUMMARY).')`. The `--allow-unverified-measurement` flag is the ONLY way past the gate; there is no silent fallback.
    1. Open a new sqlite3 file at the CLI's output dir (`--out` isn't a CLI flag yet — write to `${scratch_dir}/../osm.sqlite` or `Directory.current/osm.sqlite`, decision: `Directory.current/out/osm.sqlite`. Create `out/` if missing.).
    2. Apply pragmas + CREATE statements.
    3. Bulk-copy admin_regions_raw → admin_regions (rename only). Populate admin_regions_rtree from the bbox columns.
    4. For each way in ways_raw:
       - Resolve node_ids → lat/lng via nodes_raw (in-memory batched fetch).
       - Serialize to LineString WKB.
       - Compute length_m via haversine sum.
       - Determine denormalization: for each admin_level ∈ {2,4,6,8,9,10}, query way_admin_raw for rows matching (way_id, level). If exactly 1 row with fraction_start ≤ 1e-9 and fraction_end ≥ 1 − 1e-9 → wholly-contained; write region_id to `admin_region_id_l{lvl}`. Otherwise → leave column NULL, keep the row(s) in way_admin.
       - After the roll-up, DELETE way_admin_raw rows that were rolled up (i.e., only cross-border rows survive).
    5. Populate ways_rtree + ways_rtree_lookup:
       - Per-segment (default): iterate the LineString's coordinates in pairs; for each `(p_i, p_{i+1})`, insert a bbox row.
       - Per-way (fallback): insert one row per way with the full-way bbox and `segment_idx=-1`.
       - Assign `rtree_id` as a sequential counter.
    6. Write metadata rows (see Task 3).

    Use a single `BEGIN;`/`COMMIT;` around the bulk-copy — one transaction for the whole write. Batch prepared-statement executions in chunks of 10 000 rows for progress visibility.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/output/osm_sqlite_writer_test.dart` — passes.
    Preflight gate covered by a test: given a missing measurement file, writer throws PipelineError with the expected message. Given a stub file with "not empirically verified", writer throws PipelineError. Given a valid measurement file, writer proceeds.
    Manual smoke on tiny fixture: `dart run tool/osm_pipeline` produces `out/osm.sqlite`. Open with the `sqlite3` CLI (or via `sqlite3` Dart package):
    - `.schema` shows all expected tables.
    - `SELECT COUNT(*) FROM ways;` → 2 (1 kfz + 1 feldweg).
    - `SELECT COUNT(*) FROM admin_regions;` → 1.
    - `SELECT COUNT(*) FROM ways_rtree;` → number of segments (e.g., 12 for a 10-node way + 3-node feldweg = 9 + 3 = 12).
  </verify>
</task>

<task type="auto">
  <name>Task 2: R-Tree granularity selector + builder</name>
  <files>
    tool/osm_pipeline/lib/output/rtree_builder.dart
    tool/osm_pipeline/test/output/rtree_builder_test.dart
  </files>
  <intent>Encapsulate the per-segment vs per-way decision + build the R-Tree with the selected granularity.</intent>
  <action>
    **`rtree_builder.dart`**:
    ```dart
    enum RtreeGranularity { perSegment, perWay }

    class RtreeBuilder {
      RtreeBuilder(this._db, this._granularity);
      final Database _db;
      final RtreeGranularity _granularity;

      /// Read the recommendation from 04-05-BERLIN-MEASUREMENT.md if present;
      /// default to perSegment.
      static Future<RtreeGranularity> loadFromMeasurement(File measurementMd) async {
        if (!await measurementMd.exists()) return RtreeGranularity.perSegment;
        final txt = await measurementMd.readAsString();
        if (txt.contains(RegExp(r'per-way|per_way'))) return RtreeGranularity.perWay;
        return RtreeGranularity.perSegment;
      }

      Future<void> buildForWay(int wayId, List<Vec2> line) async {
        switch (_granularity) {
          case RtreeGranularity.perSegment:
            for (var i = 0; i < line.length - 1; i++) {
              final bb = _bboxOf([line[i], line[i + 1]]);
              _insert(wayId, i, bb);
            }
          case RtreeGranularity.perWay:
            _insert(wayId, -1, _bboxOf(line));
        }
      }
    }
    ```

    **`rtree_builder_test.dart`**:
    - Straight 3-point line → 2 segments → 2 rtree rows in perSegment mode.
    - Same line → 1 rtree row in perWay mode.
    - Bbox arithmetic: line from (52.5, 13.4) to (52.6, 13.5) → bbox exactly those values.
    - Zero-length segment (duplicate consecutive points) → skipped (no rtree row).
    - Query round-trip: after building, `SELECT id FROM ways_rtree WHERE min_lat <= X AND ...` returns the expected candidate.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/output/rtree_builder_test.dart` — green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Version stamp writer + orchestrator + Berlin end-to-end smoke</name>
  <files>
    tool/osm_pipeline/lib/output/version_stamp.dart
    tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
    tool/osm_pipeline/bin/osm_pipeline.dart
    tool/osm_pipeline/test/output/version_stamp_test.dart
  </files>
  <intent>Wire all stages together + write metadata + prove end-to-end on tiny fixture (Berlin smoke is 04-09).</intent>
  <action>
    **`version_stamp.dart`**:
    ```dart
    class VersionStamp {
      final DateTime pbfDate;        // ISO 8601 from PbfReader.header.osmosis_replication_timestamp
      final String pbfSource;        // basename
      final String pbfSha256;
      final String? bbox;            // 'minlng,minlat,maxlng,maxlng' or null → '*'
      final int schemaVersion;
      final String gitSha;           // 'git rev-parse HEAD' or 'unknown'
      final DateTime generatedAt;

      Future<void> writeTo(Database db) async {
        db.execute('PRAGMA user_version = $schemaVersion;');
        final stmt = db.prepare('INSERT INTO metadata(key, value) VALUES (?, ?)');
        try {
          stmt.execute(['pbf_date', pbfDate.toIso8601String()]);
          stmt.execute(['pbf_source', pbfSource]);
          stmt.execute(['pbf_sha256', pbfSha256]);
          stmt.execute(['bbox', bbox ?? '*']);
          stmt.execute(['pipeline_schema_version', '$schemaVersion']);
          stmt.execute(['pipeline_git_sha', gitSha]);
          stmt.execute(['generated_at', generatedAt.toUtc().toIso8601String()]);
        } finally {
          stmt.dispose();
        }
      }
    }
    ```

    - `pbfDate` source: PBF header has `osmosis_replication_timestamp` and `writingprogram` fields — 04-02's `HeaderBlock` exposes them; VersionStamp.pbfDate reads from there.
    - `gitSha`: run `git rev-parse HEAD` via `Process.runSync`, capture stdout, or set to 'unknown' if exit code ≠ 0 (running outside a git checkout).

    **`pipeline_orchestrator.dart`** — top-level `runPipeline({pbf, bbox, outDir})`:
    ```dart
    Future<void> runPipeline({ ... }) async {
      final scratch = await ScratchDb.openTempFile();
      final skippedLog = File('${outDir.path}/skipped.log').openWrite();
      try {
        Logger.info('Stage A: extract Kfz + Feldweg ways...');
        await WayPipeline.extract(pbf, scratch, skippedLog);

        Logger.info('Stage A.2: extract admin regions...');
        await extractAdminRegions(pbf: pbf, scratch: scratch, skippedLog: skippedLog);

        Logger.info('Stage B: segmented intersection way_admin...');
        await buildWayAdminJoin(scratch);

        Logger.info('Stage C: write osm.sqlite...');
        final osmSqlite = File('${outDir.path}/osm.sqlite');
        await OsmSqliteWriter.write(scratch, osmSqlite);

        Logger.info('Stage D: GeoJSONSeq + tippecanoe...  (plan 04-07)');
        // Stub call — 04-07 replaces this with a real runPmtilesStage() call.
        // 04-07 runs in wave 6 (after this plan) — no merge conflict, sequential edit.

        Logger.info('Stage E: pmtiles metadata + style rewrite...  (plan 04-08)');
        // Stub call — 04-08 implements this.

        Logger.info('Done. Artifacts:');
        Logger.info('  ${osmSqlite.path}  (${await osmSqlite.length()} bytes)');
      } finally {
        await skippedLog.close();
        await scratch.close(deleteFile: true);
      }
    }
    ```

    Update `bin/osm_pipeline.dart` from the 04-01 stub to invoke `runPipeline(...)`.

    **`version_stamp_test.dart`**:
    - Given a fixture osm.sqlite + a fixed VersionStamp, `writeTo` produces the 7 metadata rows.
    - `PRAGMA user_version` returns the schemaVersion after write.
    - Idempotent write: calling `writeTo` twice on the same DB fails cleanly (metadata.key is PK) OR replaces (executor's choice — recommend REPLACE for reproducibility).
    - `gitSha = 'unknown'` when `Process.runSync('git', ...)` throws (mock via a fake Process runner).

    **End-to-end smoke on tiny fixture (manual — codified as a checklist in this task's verify block):**
    - `dart run tool/osm_pipeline --pbf=tool/osm_pipeline/test/fixtures/tiny.osm.pbf` completes in < 5 s.
    - `out/osm.sqlite` exists.
    - `sqlite3 out/osm.sqlite "SELECT * FROM metadata;"` shows 7 rows.
    - `sqlite3 out/osm.sqlite "PRAGMA user_version;"` returns 1.
    - `sqlite3 out/osm.sqlite ".schema"` matches the expected schema.
    - `out/skipped.log` exists.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/output/` — all green.
    `dart run tool/osm_pipeline/bin/osm_pipeline.dart --pbf=tool/osm_pipeline/test/fixtures/tiny.osm.pbf` — exits 0, artifacts created, metadata rows present.
  </verify>
</task>

## Verification

- All `test/output/**` tests green.
- `flutter analyze` clean.
- End-to-end smoke on tiny.osm.pbf produces a valid osm.sqlite with all expected tables + metadata + R-Tree rows.
- `PRAGMA user_version` returns `pipelineSchemaVersion` (currently 1).
- `metadata` table has 7 rows with the expected keys.
- Preflight gate covered by a test: missing or "not empirically verified" measurement file → PipelineError, no partial osm.sqlite written.

## Deviation Handling

- **HARD GATE on 04-05 measurement:** if `.planning/phases/04-osm-pipeline/04-05-BERLIN-MEASUREMENT.md` is absent OR contains "not empirically verified", 04-06 refuses to run and returns an actionable error to the user (see Task 1 preflight). The user must either:
  1. Run 04-05 Task 3 with a real Berlin PBF, OR
  2. Pass `--allow-unverified-measurement` to the CLI to explicitly override. The override MUST be recorded in the SUMMARY and the SC4 (200 MB budget) risk called out.

  Do NOT silently fall back to the L2..L10 default. This gate is the whole point of the 04-05 measurement.
- If SQLite's rtree module is not enabled in the `sqlite3` Dart package's bundled binary, switch to `sqlite3_flutter_libs` (the app already uses it) OR build sqlite3 with the R-Tree module. 04-RESEARCH §8 assumes R-Tree is available; verify at execute time via a quick `SELECT * FROM sqlite_master WHERE type='table' AND name='sqlite_stat1';` — if that fails, escalate to the user.
- If the tiny fixture doesn't have a `osmosis_replication_timestamp` (hand-crafted PBFs often don't), fall back to `DateTime.fromMillisecondsSinceEpoch(0)` and log a warning. Real Geofabrik PBFs always carry this field.
- If the writer's single-transaction bulk-copy exceeds RAM on real Germany, split into per-table transactions with COMMIT between tables (each still bulk).
- Iterate up to 3 times per task; if blocked, report failing test/analyzer output verbatim.
