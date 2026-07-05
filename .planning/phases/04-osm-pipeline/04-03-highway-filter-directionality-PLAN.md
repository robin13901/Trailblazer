---
id: 04-03
phase: 04-osm-pipeline
plan: 03
type: execute
wave: 3
depends_on: [04-02]
files_modified:
  - tool/osm_pipeline/lib/filter/highway_class.dart
  - tool/osm_pipeline/lib/filter/kfz_filter.dart
  - tool/osm_pipeline/lib/filter/feldweg_filter.dart
  - tool/osm_pipeline/lib/filter/directionality.dart
  - tool/osm_pipeline/lib/filter/way_pipeline.dart
  - tool/osm_pipeline/lib/scratch/scratch_db.dart
  - tool/osm_pipeline/lib/scratch/scratch_schema.dart
  - tool/osm_pipeline/test/filter/kfz_filter_test.dart
  - tool/osm_pipeline/test/filter/feldweg_filter_test.dart
  - tool/osm_pipeline/test/filter/directionality_test.dart
autonomous: true
requirements: [OSM-02]

must_haves:
  truths:
    - "kfzFilter(OsmWay) accepts exactly the 14 tags in OSM-02 (motorway, motorway_link, trunk, trunk_link, primary, primary_link, secondary, secondary_link, tertiary, tertiary_link, unclassified, residential, living_street, road) and rejects all others — including highway=service"
    - "feldwegFilter(OsmWay) accepts highway=track unconditionally, highway=path only with motor_vehicle IN (yes, permissive), highway=service only with service IN (driveway, alley); rejects footway, cycleway, pedestrian, bridleway"
    - "Directionality normalization: oneway=yes → is_directional=1, node order unchanged; oneway=-1 → is_directional=1, node order physically reversed; oneway=no or missing on Kfz → is_directional=1 for motorway/motorway_link/trunk_link (OSM implicit-oneway rule), else is_directional=0"
    - "Scratch SQLite writes ways_raw rows tagged with source (kfz|feldweg), is_counting (1|0), is_directional, kept tags (name, ref, oneway, maxspeed for Kfz; name, surface for Feldweg), and node_ids as a length-prefixed BLOB (int64 little-endian)"
    - "Unit tests use synthetic OsmWay values and cover every branch of the 14 Kfz tags, all Feldweg carve-outs, both oneway=-1 reversal directions, and the highway=road counter (04-RESEARCH §12 pitfall #9)"
    - "way_pipeline logs each rejected way to skipped.log with reason (highway_class_not_allowlisted, feldweg_missing_motor_vehicle, no_highway_tag, deleted_node_ref) — never dies on a malformed way"
  artifacts:
    - path: "tool/osm_pipeline/lib/filter/kfz_filter.dart"
      provides: "Predicate + tag-retention for OSM-02 Kfz ways"
    - path: "tool/osm_pipeline/lib/filter/feldweg_filter.dart"
      provides: "Predicate for the Feldweg/Fußweg carve-out per 04-RESEARCH §4"
    - path: "tool/osm_pipeline/lib/filter/directionality.dart"
      provides: "normalizeDirectionality(way) → returns (isDirectional, reversedNodeIds)"
    - path: "tool/osm_pipeline/lib/scratch/scratch_db.dart"
      provides: "Sqlite3 wrapper for the ephemeral pipeline scratch DB — journal_mode=OFF pragmas per 04-RESEARCH §10"
  key_links:
    - from: "tool/osm_pipeline/lib/filter/way_pipeline.dart"
      to: "tool/osm_pipeline/lib/pbf/pbf_reader.dart"
      via: "consumes Stream<OsmEntity> from 04-02"
      pattern: "PbfReader"
    - from: "tool/osm_pipeline/lib/filter/way_pipeline.dart"
      to: "tool/osm_pipeline/lib/scratch/scratch_db.dart"
      via: "writes ways_raw + nodes_raw rows"
      pattern: "insertWay"
---

## Goal

Consume `Stream<OsmEntity>` from 04-02 and produce filtered Kfz + Feldweg way rows in the scratch SQLite DB — with directionality normalized once, tags trimmed to the retained set, and every reject logged.

## Context

- 04-CONTEXT.md locks the Kfz allowlist (14 tags, `service` excluded — reconciled in 04-01).
- 04-RESEARCH.md §4 defines the concrete Feldweg/Fußweg filter and calls out that `highway=service` re-enters ONLY as `service=driveway|alley` for the driveable-spur case.
- 04-RESEARCH.md §5 fixes directionality: 2-column schema (`oneway_tag` raw + `is_directional` derived), physical node reversal for `oneway=-1` at parse time.
- 04-RESEARCH.md §10 fixes the scratch DB pragmas: `journal_mode=OFF`, `synchronous=OFF`, `cache_size=-524288` (512 MB), `temp_store=MEMORY`, `page_size=65536`.
- 04-RESEARCH.md §12 pitfall #4: deleted-node refs — a way can reference a node ID that isn't in the PBF's nodes. Skip and log.
- 04-RESEARCH.md §12 pitfall #9: `highway=road` counter — include but warn if > 0.1 % of Kfz ways.
- 04-RESEARCH.md §12 pitfall #7: after `oneway=-1` physical reversal, pmtiles emission (04-07) can treat every remaining `is_directional=1` way as forward-direction — do NOT reintroduce the reversal state downstream.
- Ways can reference nodes we haven't seen yet — PBF is not strictly nodes-first. Two-pass: pass A collects all Kfz+Feldweg way IDs and their node ID references; pass B collects only the referenced nodes' lat/lng. This plan implements both passes. Memory bound: node-id → lat/lng map for ~10 M relevant nodes ≈ 240 MB at 24 B/entry — acceptable inside the 4 GB budget. If too big, spill to scratch DB (implement in 04-05, not here).

## Tasks

<task type="auto">
  <name>Task 1: Filter primitives + directionality normalizer</name>
  <files>
    tool/osm_pipeline/lib/filter/highway_class.dart
    tool/osm_pipeline/lib/filter/kfz_filter.dart
    tool/osm_pipeline/lib/filter/feldweg_filter.dart
    tool/osm_pipeline/lib/filter/directionality.dart
  </files>
  <intent>Small, pure, unit-testable predicates + a directionality normalizer.</intent>
  <action>
    **`highway_class.dart`** — enums + constant sets:
    ```dart
    /// The 14 Kfz-classified highway values from OSM-02 (post-reconciliation).
    /// `service` is deliberately excluded.
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
    };

    /// OSM implicit-oneway classes — a way with no `oneway` tag but this
    /// highway class is treated as one-way in the forward direction.
    const Set<String> kImplicitOnewayKfzTags = {
      'motorway', 'motorway_link', 'trunk_link',
    };
    ```

    **`kfz_filter.dart`** — predicate + tag-retention:
    ```dart
    bool isKfzWay(OsmWay w) {
      final hw = w.tags['highway'];
      return hw != null && kKfzHighwayTags.contains(hw);
    }

    /// Retained tags on Kfz ways (04-CONTEXT: name, ref, oneway, maxspeed).
    /// surface is deliberately NOT retained for Kfz (04-RESEARCH §4 note).
    Map<String, String> retainKfzTags(OsmWay w) {
      const kept = {'highway', 'name', 'ref', 'oneway', 'maxspeed'};
      return {for (final k in kept) if (w.tags[k] != null) k: w.tags[k]!};
    }
    ```

    **`feldweg_filter.dart`** — per 04-RESEARCH §4:
    ```dart
    /// Result: null → reject. Non-null → accept, use returned tag subset.
    Map<String, String>? feldwegTagsOrNull(OsmWay w) {
      final hw = w.tags['highway'];
      switch (hw) {
        case 'track':
          // Wirtschaftsweg — always drivable in DE convention.
          return _pick(w, {'highway', 'name', 'surface'});
        case 'path':
          final mv = w.tags['motor_vehicle'];
          if (mv == 'yes' || mv == 'permissive') {
            return _pick(w, {'highway', 'name', 'surface', 'motor_vehicle'});
          }
          return null;
        case 'service':
          final svc = w.tags['service'];
          if (svc == 'driveway' || svc == 'alley') {
            return _pick(w, {'highway', 'name', 'surface', 'service'});
          }
          return null;
        default:
          return null;   // footway, cycleway, pedestrian, bridleway, etc.
      }
    }
    ```

    **`directionality.dart`** — the schema-locking normalizer:
    ```dart
    class NormalizedDirection {
      final bool isDirectional;
      final List<int> nodeIds;   // possibly reversed
    }

    NormalizedDirection normalizeDirectionality(OsmWay w) {
      final ow = w.tags['oneway'];
      final hw = w.tags['highway'];
      switch (ow) {
        case 'yes':
          return NormalizedDirection(true, w.nodeRefs);
        case '-1':
          // Physical reversal — is_directional=1 always means "forward along stored node order"
          return NormalizedDirection(true, w.nodeRefs.reversed.toList());
        case 'no':
          return NormalizedDirection(false, w.nodeRefs);
        default:
          // Missing tag — apply implicit-oneway rule for high-class Kfz.
          final isImplicit = kImplicitOnewayKfzTags.contains(hw);
          return NormalizedDirection(isImplicit, w.nodeRefs);
      }
    }
    ```

    All four files stay under 100 LOC each. No I/O, no dep on scratch_db — pure functions.
  </action>
  <verify>
    `flutter analyze` clean.
    Files compile via `dart analyze tool/osm_pipeline/lib/filter/`.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Scratch SQLite schema + writer</name>
  <files>
    tool/osm_pipeline/pubspec.yaml
    tool/osm_pipeline/lib/scratch/scratch_db.dart
    tool/osm_pipeline/lib/scratch/scratch_schema.dart
  </files>
  <intent>The ephemeral write-heavy DB that stages A-C use as a spillover for entities that don't fit in RAM.</intent>
  <action>
    Add `sqlite3: ^2.4.0` to `tool/osm_pipeline/pubspec.yaml` under `dependencies` (alphabetized). Pure Dart bindings — no FFI DLL prerequisite (the package vendors prebuilt sqlite3 for host platforms including Windows).

    **`scratch_schema.dart`** — the CREATE statements as a `const String[]`:
    ```sql
    CREATE TABLE nodes_raw (
      id       INTEGER PRIMARY KEY,
      lat      REAL NOT NULL,
      lng      REAL NOT NULL
    ) WITHOUT ROWID;

    CREATE TABLE ways_raw (
      id             INTEGER PRIMARY KEY,
      source         TEXT NOT NULL,          -- 'kfz' | 'feldweg'
      is_counting    INTEGER NOT NULL,       -- 1 for Kfz, 0 for Feldweg
      is_directional INTEGER NOT NULL,       -- 0 | 1 (post-normalization)
      oneway_tag     TEXT,                   -- raw, for debugging
      highway        TEXT NOT NULL,
      name           TEXT,
      ref            TEXT,
      maxspeed       TEXT,
      surface        TEXT,                   -- only populated for Feldweg (04-RESEARCH §4)
      motor_vehicle  TEXT,                   -- only populated for feldweg service/path
      service        TEXT,                   -- only populated for Feldweg service branch
      node_ids       BLOB NOT NULL           -- length-prefixed int64 LE array
    );

    CREATE TABLE relations_raw (
      id          INTEGER PRIMARY KEY,
      type        TEXT NOT NULL,             -- 'multipolygon' | 'boundary' | ...
      admin_level INTEGER,                   -- null for non-admin relations
      name        TEXT,
      members     BLOB NOT NULL              -- serialized {type,refId,role}[]
    );

    -- Bookkeeping counter for 04-RESEARCH §12 pitfall #9 (highway=road warning)
    CREATE TABLE filter_stats (
      key   TEXT PRIMARY KEY,
      count INTEGER NOT NULL DEFAULT 0
    );
    ```

    **`scratch_db.dart`** — wrapper class:
    ```dart
    class ScratchDb {
      static Future<ScratchDb> openTempFile() async { ... }
      void applyWritePragmas() {
        _db.execute('PRAGMA journal_mode = OFF;');
        _db.execute('PRAGMA synchronous = OFF;');
        _db.execute('PRAGMA cache_size = -524288;');   // 512 MB
        _db.execute('PRAGMA temp_store = MEMORY;');
        _db.execute('PRAGMA page_size = 65536;');
      }

      /// Bulk-insert ways_raw + nodes_raw rows. Uses prepared statements + BEGIN;COMMIT.
      /// Flush every 10 000 rows for balance of throughput vs peak memory.

      Future<void> insertWayKfz({
        required int id, required List<int> nodeIds, required bool isDirectional,
        required String? onewayTag, required String highway,
        required String? name, required String? ref, required String? maxspeed,
      }) { ... }

      Future<void> insertWayFeldweg({
        required int id, required List<int> nodeIds, required String highway,
        required String? name, required String? surface,
        required String? motorVehicle, required String? service,
      }) { ... }

      Future<void> insertNode({ required int id, required double lat, required double lng }) { ... }

      Future<void> bumpStat(String key) { ... }

      Future<void> close({ required bool deleteFile }) { ... }
    }
    ```

    `openTempFile()` creates the scratch DB at `Directory.systemTemp.createTempSync('trailblazer_osm_')`. Path is exposed as a getter so `skipped.log` can live alongside.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/filter/scratch_db_test.dart` — open+close+insert+read-back test passes.
    `dart analyze` clean.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Two-pass way_pipeline + tests</name>
  <files>
    tool/osm_pipeline/lib/filter/way_pipeline.dart
    tool/osm_pipeline/test/filter/kfz_filter_test.dart
    tool/osm_pipeline/test/filter/feldweg_filter_test.dart
    tool/osm_pipeline/test/filter/directionality_test.dart
  </files>
  <intent>Wire the filters + normalizer + scratch DB into a working streaming pipeline stage, with exhaustive unit tests.</intent>
  <action>
    **`way_pipeline.dart`** — orchestrates two passes over `PbfReader.stream(pbf)`:

    Pass A (way selection):
    ```dart
    Future<Set<int>> _collectRelevantWayNodeIds(File pbf, ScratchDb scratch) async {
      final nodeIds = <int>{};
      await for (final e in PbfReader().stream(pbf)) {
        if (e is! OsmWay) continue;
        if (isKfzWay(e)) {
          final nd = normalizeDirectionality(e);
          await scratch.insertWayKfz(
            id: e.id, nodeIds: nd.nodeIds, isDirectional: nd.isDirectional,
            onewayTag: e.tags['oneway'], highway: e.tags['highway']!,
            name: e.tags['name'], ref: e.tags['ref'], maxspeed: e.tags['maxspeed'],
          );
          if (e.tags['highway'] == 'road') await scratch.bumpStat('highway_road');
          nodeIds.addAll(nd.nodeIds);
        } else {
          final fTags = feldwegTagsOrNull(e);
          if (fTags == null) continue;
          await scratch.insertWayFeldweg(
            id: e.id, nodeIds: e.nodeRefs, highway: e.tags['highway']!,
            name: e.tags['name'], surface: e.tags['surface'],
            motorVehicle: e.tags['motor_vehicle'], service: e.tags['service'],
          );
          nodeIds.addAll(e.nodeRefs);
        }
      }
      return nodeIds;
    }
    ```

    Pass B (node ingest — only relevant nodes):
    ```dart
    Future<void> _collectNodes(File pbf, Set<int> relevantIds, ScratchDb scratch) async {
      await for (final e in PbfReader().stream(pbf)) {
        if (e is! OsmNode) continue;
        if (!relevantIds.contains(e.id)) continue;
        await scratch.insertNode(id: e.id, lat: e.lat, lng: e.lng);
      }
    }
    ```

    Post-pass integrity check: `SELECT COUNT(*) FROM ways_raw` and `SELECT COUNT(DISTINCT id) FROM nodes_raw`. If a way references a node ID absent from `nodes_raw`, log it to `skipped.log` and drop the way (04-RESEARCH §12 pitfall #4). Implement this as a post-B query — do NOT check per-way during pass A.

    Log a warning if `filter_stats.highway_road / total_kfz_ways > 0.001` (pitfall #9).

    **Tests:**

    `test/filter/kfz_filter_test.dart` — parameterized over all 14 Kfz tags + a negative case for each of `service`, `footway`, `cycleway`, and a made-up `highway=highway_that_doesnt_exist`.

    `test/filter/feldweg_filter_test.dart`:
    - `highway=track` alone → accepted.
    - `highway=path` alone → rejected.
    - `highway=path` + `motor_vehicle=yes` → accepted.
    - `highway=path` + `motor_vehicle=permissive` → accepted.
    - `highway=path` + `motor_vehicle=no` → rejected.
    - `highway=service` + `service=driveway` → accepted.
    - `highway=service` + `service=parking_aisle` → rejected.
    - `highway=footway`, `cycleway`, `pedestrian`, `bridleway` → all rejected.

    `test/filter/directionality_test.dart`:
    - `oneway=yes`, `highway=primary` → `isDirectional=true`, node order preserved.
    - `oneway=-1`, `highway=primary` → `isDirectional=true`, node order REVERSED (test: input [1,2,3] → output [3,2,1]).
    - `oneway=no`, `highway=primary` → `isDirectional=false`, node order preserved.
    - Missing oneway, `highway=motorway` → `isDirectional=true`  (implicit).
    - Missing oneway, `highway=motorway_link` → `isDirectional=true`.
    - Missing oneway, `highway=trunk_link` → `isDirectional=true`.
    - Missing oneway, `highway=primary` → `isDirectional=false`.
    - Missing oneway, `highway=residential` → `isDirectional=false`.
    - Missing oneway, `highway=trunk` → `isDirectional=false`  (trunk is NOT implicit-oneway per OSM wiki; only motorway/motorway_link/trunk_link are).

    Run: `cd tool/osm_pipeline && dart test`.
  </action>
  <verify>
    All new tests green.
    Ralph loop: `flutter analyze` clean at repo root.
    Manual smoke: `dart run tool/osm_pipeline/bin/osm_pipeline.dart --pbf=tool/osm_pipeline/test/fixtures/tiny.osm.pbf` — completes and prints filter_stats summary (1 Kfz way, 1 Feldweg, 0 highway=road, 24 nodes).
  </verify>
</task>

## Verification

- `cd tool/osm_pipeline && dart test test/filter/` — all green.
- `flutter analyze` clean at repo root.
- Running the CLI on the tiny fixture completes in < 1 s and produces a scratch DB with exactly 1 Kfz way, 1 Feldweg way, and 24 nodes (24 = 10 Kfz + 4 Feldweg + 11 admin outer + 4 admin inner − overlap; adjust to the fixture's actual counts).
- `skipped.log` is created (possibly empty) alongside the scratch DB.

## Deviation Handling

- If the scratch DB write throughput is bad (< 20 k rows/s) on the tiny fixture, increase batch size from 10 000 to 50 000 in `ScratchDb.flush()`. Real bottleneck measurement happens in 04-09 (Berlin smoke), not here.
- If a two-pass approach doubles wall-clock unacceptably (measured in 04-09), 04-05 will introduce a node-id → offset index that lets pass B seek — do NOT try to optimize in 04-03.
- 04-RESEARCH §12 pitfall #8 (non-Latin `name:*` tags): drop `name:*` entirely, keep only `name` (which is `name:de` by DE convention). This is already correct in the retained-tag sets — verify no test regresses on that.
- Iterate up to 3 times per task; if blocked, report the failing test/analyzer output verbatim.
