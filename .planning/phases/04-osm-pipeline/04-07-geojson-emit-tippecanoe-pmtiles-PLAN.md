---
id: 04-07
phase: 04-osm-pipeline
plan: 07
type: execute
wave: 5
depends_on: [04-05]
files_modified:
  - tool/osm_pipeline/lib/pmtiles/layer_schema.dart
  - tool/osm_pipeline/lib/pmtiles/geojson_writer.dart
  - tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart
  - tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart
  - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
  - tool/osm_pipeline/test/pmtiles/layer_schema_test.dart
  - tool/osm_pipeline/test/pmtiles/geojson_writer_test.dart
  - tool/osm_pipeline/test/pmtiles/tippecanoe_runner_test.dart
autonomous: true
requirements: []

must_haves:
  truths:
    - "Four layers emitted as separate GeoJSONSeq files: roads, admin_boundaries, water, labels — per 04-CONTEXT + 04-RESEARCH §3"
    - "roads layer features carry kind (motorway|trunk|primary|secondary|tertiary|minor|track|path), name, ref, oneway (bool) — motorway_link etc. collapsed to parent per 04-RESEARCH §3"
    - "admin_boundaries features carry admin_level (2|4|6|8|9|10), kind (country|state|county|municipality|district|suburb), name — as both LineStrings (borders) AND Polygons (fills)"
    - "water layer features: kind (lake|river|stream), name — inland lakes + rivers only (sea skipped, 04-RESEARCH §12 pitfall #3)"
    - "labels layer features: kind (place_country|place_state|place_city|place_town|place_village|road_shield), name, ref, population"
    - "tippecanoe subprocess is invoked with maxzoom=11 per 04-CONTEXT; on Windows the runner shells out via wsl.exe to a WSL2-installed tippecanoe binary; on macOS/Linux it invokes tippecanoe directly"
    - "germany-base.pmtiles is produced with 4 vector_layers matching the schema; tippecanoe stdout+stderr streamed to Logger.info during the subprocess run"
  artifacts:
    - path: "tool/osm_pipeline/lib/pmtiles/layer_schema.dart"
      provides: "Constant maps + kind-collapse helpers for each of the 4 layers"
    - path: "tool/osm_pipeline/lib/pmtiles/geojson_writer.dart"
      provides: "Streams per-layer GeoJSONSeq features to disk (.geojsonl one-feature-per-line)"
    - path: "tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart"
      provides: "Cross-platform Process invocation of tippecanoe (native on macOS/Linux, WSL2 on Windows)"
  key_links:
    - from: "tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart"
      to: "tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart"
      via: "shells out with per-layer args to produce germany-base.pmtiles"
      pattern: "TippecanoeRunner.run"
    - from: "tool/osm_pipeline/lib/output/pipeline_orchestrator.dart"
      to: "tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart"
      via: "Stage D of the monolithic run"
      pattern: "runPmtilesStage"
---

## Goal

Emit the four-layer vector schema as GeoJSONSeq files and invoke tippecanoe to produce `germany-base.pmtiles`. Runs in parallel with 04-06.

## Context

- 04-RESEARCH §2 locks tippecanoe (subprocess) as the pmtiles author. Hand-rolling PMTiles v3 writing in Dart is out of scope for v1.
- 04-RESEARCH §3 defines the 4-layer schema (`roads`, `admin_boundaries`, `water`, `labels`) with concrete field names and per-feature min_zoom values. Subset of Protomaps v4 semantics — same `kind` vocabulary for future style-lift reuse.
- 04-CONTEXT.md pins `maxzoom = 11`.
- 04-RESEARCH §12 pitfall #3: no sea polygons in v1 — Germany's coastline requires a separate Daylight/OSMCoastline dataset. Inland lakes + rivers are enough.
- 04-RESEARCH §12 pitfall #7: after 04-03's physical reversal of `oneway=-1`, roads-layer features emit `oneway=true` verbatim (no re-reversal in emission).
- 04-RESEARCH.md §2 Windows mitigation: shell out to `wsl tippecanoe ...` on Windows dev boxes. 04-01 already documented the WSL2 prerequisite in `tool/osm_pipeline/README.md`. 04-09 owns the more detailed WSL setup doc.
- This plan reads directly from the SCRATCH DB (produced by 04-03/04/05), not from 04-06's final osm.sqlite — running 04-07 and 04-06 in parallel means both consume scratch and don't step on each other. Alternative: 04-07 reads the final osm.sqlite. Choosing SCRATCH keeps parallelism.

## Tasks

<task type="auto">
  <name>Task 1: Layer schema constants + kind-collapse helpers</name>
  <files>
    tool/osm_pipeline/lib/pmtiles/layer_schema.dart
    tool/osm_pipeline/test/pmtiles/layer_schema_test.dart
  </files>
  <intent>Pin the vector-layer vocabulary in code so 04-08's style JSON references the same names.</intent>
  <action>
    **`layer_schema.dart`**:
    ```dart
    /// Vector tile layer names — must match style JSON source-layer references.
    /// 04-08 rewrites map_style_light.json + map_style_dark.json to target these.
    class Layers {
      static const roads = 'roads';
      static const adminBoundaries = 'admin_boundaries';
      static const water = 'water';
      static const labels = 'labels';
    }

    /// Collapse motorway_link → motorway, primary_link → primary, etc.
    /// per 04-RESEARCH §3.
    String collapseHighwayKind(String osmHighway) {
      switch (osmHighway) {
        case 'motorway_link': return 'motorway';
        case 'trunk_link': return 'trunk';
        case 'primary_link': return 'primary';
        case 'secondary_link': return 'secondary';
        case 'tertiary_link': return 'tertiary';
        case 'motorway': case 'trunk': case 'primary':
        case 'secondary': case 'tertiary': return osmHighway;
        case 'residential': case 'unclassified':
        case 'living_street': case 'road': return 'minor';
        case 'track': return 'track';
        case 'path': return 'path';
        default: return 'other';
      }
    }

    /// Minimum zoom per road kind (Protomaps convention, 04-RESEARCH §3).
    int minZoomForRoadKind(String kind) {
      switch (kind) {
        case 'motorway': return 5;
        case 'trunk': return 6;
        case 'primary': return 7;
        case 'secondary': return 9;
        case 'tertiary': return 10;
        case 'minor': case 'track': case 'path': return 11;
        default: return 11;
      }
    }

    /// Admin level → kind label (04-RESEARCH §3).
    String adminKindForLevel(int lvl) {
      switch (lvl) {
        case 2: return 'country';
        case 4: return 'state';
        case 6: return 'county';
        case 8: return 'municipality';
        case 9: return 'district';
        case 10: return 'suburb';
        default: return 'other';
      }
    }

    /// Min zoom per admin level (04-RESEARCH §3).
    int minZoomForAdminLevel(int lvl) {
      if (lvl <= 4) return 0;
      if (lvl == 6) return 6;
      return 9;  // 8, 9, 10
    }
    ```

    **`layer_schema_test.dart`**:
    - `collapseHighwayKind('motorway_link') == 'motorway'`
    - `collapseHighwayKind('residential') == 'minor'`
    - `collapseHighwayKind('anything_weird') == 'other'`
    - `minZoomForRoadKind('motorway') == 5`
    - `minZoomForRoadKind('minor') == 11`
    - `adminKindForLevel(2) == 'country'`, `adminKindForLevel(10) == 'suburb'`
    - `minZoomForAdminLevel(2) == 0`, `minZoomForAdminLevel(6) == 6`, `minZoomForAdminLevel(10) == 9`
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/pmtiles/layer_schema_test.dart` — green.
  </verify>
</task>

<task type="auto">
  <name>Task 2: GeoJSONSeq per-layer writer + water/labels extractors</name>
  <files>
    tool/osm_pipeline/lib/pmtiles/geojson_writer.dart
    tool/osm_pipeline/test/pmtiles/geojson_writer_test.dart
  </files>
  <intent>Stream 4 layer files to disk in GeoJSONSeq format (one Feature per line, no wrapping FeatureCollection — tippecanoe's preferred input).</intent>
  <action>
    **`geojson_writer.dart`** — one writer function per layer, all streaming to `IOSink`:

    ```dart
    class GeoJsonSeqWriter {
      /// Emits roads-layer features from ways_raw + nodes_raw.
      static Future<void> writeRoads(ScratchDb scratch, IOSink out) async { ... }

      /// Emits admin_boundaries (both LineString borders AND Polygon fills)
      /// from admin_regions_raw. Emits BOTH — see 04-RESEARCH §3.
      static Future<void> writeAdminBoundaries(ScratchDb scratch, IOSink out) async { ... }

      /// Emits water features by ADDITIONAL PBF pass (this plan is the first
      /// consumer of natural=water and waterway=river data). Adds a small
      /// water-pipeline stage that scans the PBF for waterway=river/stream
      /// and natural=water areas — skips coastlines (pitfall #3).
      static Future<void> writeWater(File pbf, ScratchDb scratch, IOSink out) async { ... }

      /// Emits labels by ADDITIONAL PBF pass — place=* nodes + road-shield ref.
      static Future<void> writeLabels(File pbf, ScratchDb scratch, IOSink out) async { ... }
    }
    ```

    Each Feature is a single line: `{"type":"Feature","geometry":{...},"properties":{...}}\n`.

    **Roads layer** — one Feature per way in `ways_raw`:
    - `geometry: {"type": "LineString", "coordinates": [[lng,lat], ...]}` — resolve node_ids via nodes_raw.
    - `properties: { "kind": collapseHighwayKind(hw), "name": name, "ref": ref, "oneway": is_directional == 1 }`.
    - Include Feldweg rows too — their `kind` becomes 'track' or 'path'.

    **Admin boundaries** — TWO features per admin_regions_raw row:
    - The Polygon fill (from geometry_wkb): `properties: { "admin_level": lvl, "kind": adminKindForLevel(lvl), "name": name, "shape": "fill" }`.
    - The LineString outline (extracted from the polygon's outer + inner rings): `properties: { ..., "shape": "outline" }`.
    - This lets 04-08's style paint fills at low opacity and outlines at high opacity independently.

    **Water** — new PBF pass:
    - Ways/relations with `natural=water` → Polygon (skip if `water=sea` OR admin boundary type=coastline — pitfall #3).
    - Ways with `waterway=river|stream|canal` → LineString.
    - Retain `name` at min_zoom 8 for rivers, 10 for streams.
    - Simplify: keep only water bodies with bbox area > (5 × 5 km) at z ≤ 8 to keep tile size down.

    **Labels** — new PBF pass:
    - Nodes with `place=country|state|city|town|village|suburb` → Point + `kind = 'place_' + place`.
    - Ways with `highway=motorway|trunk|primary` AND non-empty `ref` → Point at midpoint of the way + `kind='road_shield'` + `ref`.
    - Retain `population` where present (Protomaps convention — style ranks labels by pop).

    Do NOT hand-implement PBF passes twice. Accept the second scan cost (04-RESEARCH §10 notes the scratch DB approach); water + labels come from a single joined pass here.

    **`geojson_writer_test.dart`**:
    - Synthetic scratch DB with 1 Kfz way and 1 Feldweg → `writeRoads` emits exactly 2 lines, each parses as valid GeoJSON Feature with the expected `kind`.
    - Emitted `oneway: true` for `is_directional=1` and `oneway: false` for `is_directional=0`.
    - `writeAdminBoundaries` emits 2 lines per admin region (fill + outline).
    - Water writer round-trip on the tiny fixture (which currently has no water — emits 0 lines): test asserts empty output, not error.
    - Labels writer on tiny fixture (currently has no `place=*` nodes): emits 0 lines.
    - JSON escaping: a name containing `"` or backslash serializes correctly (`"Der \"Nord\" Weg"`).
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/pmtiles/geojson_writer_test.dart` — green.
    Manual: after end-to-end run on tiny fixture, `out/roads.geojsonl` contains 2 lines; `out/admin_boundaries.geojsonl` contains 2 lines; `out/water.geojsonl` empty; `out/labels.geojsonl` empty.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Cross-platform tippecanoe runner + pmtiles pipeline stage</name>
  <files>
    tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart
    tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart
    tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
    tool/osm_pipeline/test/pmtiles/tippecanoe_runner_test.dart
  </files>
  <intent>Invoke tippecanoe cross-platform, stream its output, produce germany-base.pmtiles.</intent>
  <action>
    **`tippecanoe_runner.dart`**:
    ```dart
    class TippecanoeRunner {
      /// Runs tippecanoe with the given args. On Windows shells out via wsl.exe;
      /// on macOS/Linux invokes tippecanoe directly.
      static Future<void> run(List<String> args, {File? cwd}) async {
        final (executable, prefixArgs) = _resolveExecutable();
        final proc = await Process.start(
          executable,
          [...prefixArgs, 'tippecanoe', ...args],
          workingDirectory: cwd?.path,
          runInShell: false,
        );
        // Stream stdout + stderr live to Logger.info / Logger.warn.
        proc.stdout.transform(utf8.decoder).transform(const LineSplitter())
          .listen(Logger.info);
        proc.stderr.transform(utf8.decoder).transform(const LineSplitter())
          .listen(Logger.warn);
        final code = await proc.exitCode;
        if (code != 0) {
          throw PipelineError('tippecanoe exited $code', cause: args);
        }
      }

      static (String executable, List<String> prefixArgs) _resolveExecutable() {
        if (Platform.isWindows) {
          // Requires wsl.exe with a distro that has tippecanoe installed.
          // 04-01's README + 04-09's tippecanoe/README.md document the WSL setup.
          return ('wsl.exe', <String>[]);
        }
        return ('tippecanoe', <String>[]);
      }

      /// Pre-flight check: returns tippecanoe version string, or throws
      /// PipelineError with actionable install instructions.
      static Future<String> preflightCheck() async { ... }
    }
    ```

    Note the `[...prefixArgs, 'tippecanoe', ...args]` shape: on Windows, `Process.start('wsl.exe', ['tippecanoe', ...])` runs `wsl tippecanoe ...`. On Linux/macOS, `Process.start('tippecanoe', [...])` invokes it directly. The 'tippecanoe' string is duplicated at position [0] of the args list on Windows — that IS the WSL invocation shape.

    **Path translation on Windows:** tippecanoe running under WSL sees Linux paths. If the executor passes `C:\Users\...` paths, they must be converted to `/mnt/c/Users/...`. Add a `_wslifyPath(String path)` helper for Windows-only.

    **`pmtiles_pipeline.dart`** — Stage D orchestration:

    ```dart
    Future<File> runPmtilesStage({
      required ScratchDb scratch,
      required File pbf,
      required Directory outDir,
    }) async {
      await TippecanoeRunner.preflightCheck();

      final roads = File('${outDir.path}/roads.geojsonl');
      final admins = File('${outDir.path}/admin_boundaries.geojsonl');
      final water = File('${outDir.path}/water.geojsonl');
      final labels = File('${outDir.path}/labels.geojsonl');

      Logger.info('Stage D.1: emit GeoJSONSeq per layer...');
      await GeoJsonSeqWriter.writeRoads(scratch, roads.openWrite());
      await GeoJsonSeqWriter.writeAdminBoundaries(scratch, admins.openWrite());
      await GeoJsonSeqWriter.writeWater(pbf, scratch, water.openWrite());
      await GeoJsonSeqWriter.writeLabels(pbf, scratch, labels.openWrite());

      Logger.info('Stage D.2: run tippecanoe...');
      final out = File('${outDir.path}/germany-base.pmtiles');
      if (await out.exists()) await out.delete();

      await TippecanoeRunner.run([
        '-o', _p(out),
        '--maximum-zoom=11',
        '--minimum-zoom=0',
        '--drop-densest-as-needed',
        '--extend-zooms-if-still-dropping',
        '--no-tile-compression',                 // keep raw MVT; app decompresses
        '--force',
        '-L', jsonEncode({'file': _p(roads),  'layer': 'roads'}),
        '-L', jsonEncode({'file': _p(admins), 'layer': 'admin_boundaries'}),
        '-L', jsonEncode({'file': _p(water),  'layer': 'water'}),
        '-L', jsonEncode({'file': _p(labels), 'layer': 'labels'}),
      ]);

      // Clean up intermediate geojsonl files.
      for (final f in [roads, admins, water, labels]) {
        if (await f.exists()) await f.delete();
      }

      Logger.info('  → ${out.path}  (${await out.length()} bytes)');
      return out;
    }

    String _p(File f) => Platform.isWindows ? _wslifyPath(f.absolute.path) : f.absolute.path;
    ```

    Note: `--no-tile-compression` matches Phase 2's MapLibre setup (the app's MapLibre expects uncompressed MVT). Verify against `pubspec.yaml`'s `maplibre_gl` version — if it expects gzipped, drop this flag.

    Wire Stage D into `pipeline_orchestrator.dart` (replace the earlier stub call).

    **`tippecanoe_runner_test.dart`**:
    - Mocked `Process.start` (via `dart:io` platform channel replacement or just testing the `_resolveExecutable()` helper directly):
      - On Windows platform → `('wsl.exe', [])` — args list starts with 'tippecanoe' when run() is called.
      - On macOS/Linux → `('tippecanoe', [])` — args just the raw list.
    - `_wslifyPath('C:\\Users\\foo\\bar.geojsonl')` → `'/mnt/c/Users/foo/bar.geojsonl'`.
    - `_wslifyPath('/home/foo/bar')` → `'/home/foo/bar'` (unchanged).
    - `preflightCheck()` with missing tippecanoe → throws PipelineError containing the string "install tippecanoe" and a link to the README.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/pmtiles/tippecanoe_runner_test.dart` — green.
    Manual smoke on tiny fixture: `dart run tool/osm_pipeline --pbf=tool/osm_pipeline/test/fixtures/tiny.osm.pbf` completes, `out/germany-base.pmtiles` exists (tiny — a few KB — but valid).
    Executor note: on Windows dev boxes without WSL2/tippecanoe, this task's tippecanoe execution WILL fail. The unit tests should still pass (they test the runner shape, not real execution). Real invocation is validated in 04-09's Berlin smoke.
  </verify>
</task>

## Verification

- All `test/pmtiles/**` tests green.
- `flutter analyze` clean.
- On a machine with tippecanoe available, running the CLI on tiny.osm.pbf produces `out/germany-base.pmtiles` and cleans up intermediate `.geojsonl` files.
- On Windows without WSL2 tippecanoe installed, the CLI fails cleanly with a PipelineError pointing at 04-01's README install instructions — NOT a silent hang or an unhelpful crash.

## Deviation Handling

- If tippecanoe's flag set has evolved (v2.30+ specifics may drift), pin a version in `04-01`'s README and `04-09`'s WSL doc. Executor: check `tippecanoe --version` in preflight, warn if below 2.30 (`--no-tile-compression` requires 2.10+, `--extend-zooms-if-still-dropping` requires 1.36+).
- If `--no-tile-compression` produces pmtiles that the app's `maplibre_gl` rejects, drop the flag — but 04-08's style JSON rewrite must match whichever compression state the pmtiles ships with.
- If sea-polygon absence looks wrong at zoom 3–5 (Germany's coast looks jagged), the fix is a v2 Daylight/OSMCoastline integration — DO NOT try to reconstruct sea polygons from OSM coastline ways in this phase (04-RESEARCH §12 pitfall #3).
- Iterate up to 3 times per task; report blockers verbatim.
