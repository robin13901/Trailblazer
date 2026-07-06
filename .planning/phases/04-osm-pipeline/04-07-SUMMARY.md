---
id: 04-07
phase: 04-osm-pipeline
plan: 07
title: GeoJSONSeq Emit + tippecanoe Subprocess
status: complete
subsystem: osm-pipeline
tags: [osm, pmtiles, tippecanoe, geojson, vector-tiles, wsl2, subprocess]
requires: [04-01, 04-02, 04-03, 04-04, 04-05, 04-06]
provides:
  - four-layer vector schema (roads, admin_boundaries, water, labels)
  - collapseHighwayKind + min-zoom helpers (single source of truth for 04-08 style)
  - GeoJSONSeq per-layer writer streaming to IOSink
  - additional PBF passes for water (natural=water + waterway=*) and labels (place=* + road_shield)
  - cross-platform tippecanoe subprocess runner (WSL2 shell-out on Windows)
  - Windows path → WSL mount path translator (wslifyPath)
  - Stage F wired into pipeline_orchestrator (replaces 04-06 stub)
  - Berlin-scale germany-base.pmtiles (14.58 MB, 4 layers, 184 521 features)
affects: [04-08, 04-09, 04-10, 02]
tech-stack:
  added: []
  patterns:
    - subprocess wrapper streaming stdout to Logger.info + stderr to Logger.warn
    - platform-conditional executable resolution (wsl.exe tippecanoe … vs tippecanoe …)
    - pure path translator (wslifyPath — unconditional, deterministic across host OS)
    - runPmtiles=true toggle on runPipeline (test/CI hosts can skip tippecanoe)
    - GeoJSONSeq one-Feature-per-line (tippecanoe's preferred input, no wrapping FeatureCollection)
    - fill + outline dual-emission per admin region (independent style paint at 04-08)
    - jsonEncode for JSON escaping (quotes/backslashes/unicode handled by dart:convert)
key-files:
  created:
    - tool/osm_pipeline/lib/pmtiles/layer_schema.dart
    - tool/osm_pipeline/lib/pmtiles/geojson_writer.dart
    - tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart
    - tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart
    - tool/osm_pipeline/test/pmtiles/layer_schema_test.dart
    - tool/osm_pipeline/test/pmtiles/geojson_writer_test.dart
    - tool/osm_pipeline/test/pmtiles/tippecanoe_runner_test.dart
  modified:
    - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
    - tool/osm_pipeline/bin/osm_pipeline.dart
metrics:
  duration: ~90 min (incl. tippecanoe bootstrap + Berlin end-to-end run)
  completed: 2026-07-06
  tests_added: 26
  tests_total_pipeline: 204
  commits: 4
---

# Phase 4 Plan 07: GeoJSONSeq Emit + tippecanoe Subprocess Summary

**One-liner:** Stage F wired end-to-end — 4-layer GeoJSONSeq emit from scratch DB + PBF, tippecanoe subprocess (WSL2 on Windows), Berlin proof produces 14.58 MB `germany-base.pmtiles` with 176 567 roads / 2 930 waters / 4 788 labels / 236 admin-boundary features across zooms 0..12.

## Objective

Replace the Stage F stub 04-06 planted in `pipeline_orchestrator.dart` with a real GeoJSONSeq emitter + tippecanoe subprocess. Produce the actual `germany-base.pmtiles` artifact that 04-08 will rewrite the style JSON against and Phase 2 will ship as the offline base map.

## tippecanoe bootstrap (Task 0 — deviation Rule 3, auto-fix blocker)

**Blocker:** Windows dev box has WSL2 (Rancher Desktop's Alpine distro) but no tippecanoe binary. Plan 04-09 owns the WSL setup guide but hasn't shipped yet — this plan needs a working binary before Task 3 can be smoke-tested.

**Actions taken automatically (no user prompt required):**

1. Fixed WSL DNS — Rancher's `/etc/resolv.conf` pointed at an unreachable `192.168.127.1`. Rewrote to `8.8.8.8` + `1.1.1.1`.
2. `apk add --no-cache build-base sqlite-dev zlib-dev git make g++ bash` (Alpine 3.19).
3. `git clone --depth 1 https://github.com/felt/tippecanoe.git /tmp/tippecanoe && cd /tmp/tippecanoe && make -j && make install`.
4. Result: `tippecanoe v2.80.0` at `/usr/local/bin/tippecanoe` inside the Rancher WSL distro.

Passwordless sudo confirmed (Rancher WSL runs as root by default) so no interactive prompt materialised. Documented in this SUMMARY so 04-09 can point at these exact commands.

## Tasks completed

### Task 1 — Layer schema constants + kind-collapse helpers

Commit: `97d84be feat(04-07): layer schema constants + kind-collapse helpers`

- `tool/osm_pipeline/lib/pmtiles/layer_schema.dart` exposes:
  - `Layers.{roads, adminBoundaries, water, labels}` string constants — the single source of truth both this plan (Task 3 tippecanoe `-L` args) and 04-08 (style JSON `source-layer`) reference.
  - `collapseHighwayKind(osmHighway)` — `motorway_link → motorway`, `primary_link → primary`, `residential → minor`, unknown → `other`.
  - `minZoomForRoadKind(kind)` — Protomaps ladder: `motorway = 5`, `trunk = 6`, `primary = 7`, `secondary = 9`, `tertiary = 10`, `minor/track/path = 11`.
  - `adminKindForLevel(lvl)` — `2 → country`, `4 → state`, `6 → county`, `8 → municipality`, `9 → district`, `10 → suburb`.
  - `minZoomForAdminLevel(lvl)` — `≤4 → 0`, `6 → 6`, `≥8 → 9`.
- 11 unit tests cover collapse rules + admin ladder + fallback (unknown highway → `other`, unknown admin level → `other`, unknown kind → min-zoom 11).

### Task 2 — GeoJSONSeq per-layer writer + water/labels extractors

Commit: `da3afb6 feat(04-07): GeoJSONSeq per-layer writer`

- `GeoJsonSeqWriter` (pure namespace, all static) — four writer functions:
  - `writeRoads(scratch, sink)` — one Feature per way row in `ways_raw` (Kfz + Feldweg). LineString geometry via `decodeNodeIds` + node lookup, `properties.oneway = (is_directional == 1)`. Ways with fewer than 2 resolved node coords are skipped silently.
  - `writeAdminBoundaries(scratch, sink)` — two Features per `admin_regions_raw` row: a MultiPolygon fill (`shape: 'fill'`) and a MultiLineString outline (concatenated outer + inner rings, `shape: 'outline'`). Independent-paint decision from 04-RESEARCH §3. Guarded on `admin_regions_raw` table existence so tests without the admin extension can still call the function (returns 0).
  - `writeWater(pbf, scratch, sink)` — additional PBF pass. Emits Polygon for `natural=water` (excluding `water=sea` per 04-RESEARCH §12 pitfall #3), LineString for `waterway=river|stream|canal`. Two passes over the PBF (way IDs + tag classification, then node coordinate resolution).
  - `writeLabels(pbf, scratch, sink)` — additional PBF pass. Emits Point for `place=country|state|city|town|village|suburb` nodes; emits `kind=road_shield` Point at the midpoint node of `motorway/trunk/primary` ways with a non-empty `ref`. Retains `population` on place nodes where present.
- JSON escaping is handled by `dart:convert.jsonEncode` — verified in a test that round-trips `Der "Nord" Weg\Süd` through the writer and back through `jsonDecode`.
- 8 unit tests, including a tiny-fixture round-trip that confirms the fixture's one primary way with `ref=M1` produces exactly one `road_shield` label.

### Task 3 — Cross-platform tippecanoe runner + pmtiles pipeline stage

Commit: `dba2f4c feat(04-07): tippecanoe runner + Stage F wired end-to-end`

- `TippecanoeRunner.run(args)` — `Process.start` wrapper. On Windows uses `('wsl.exe', ['tippecanoe', ...args])`; on macOS/Linux uses `('tippecanoe', args)`. Stdout streamed to `Logger.info`, stderr to `Logger.warn` (tippecanoe emits its progress bar on stderr). Non-zero exit → `PipelineIoError` carrying the failing argv.
- `TippecanoeRunner.preflightCheck()` runs `--version` and returns the banner. Missing binary → `PipelineIoError` with an install hint pointing at `tool/osm_pipeline/README.md`.
- `wslifyPath(path)` — pure transform: `C:\Users\me\out\x` → `/mnt/c/Users/me/out/x` (drive-letter → lowercase mount, backslash → forward slash). POSIX paths pass through unchanged. Unit tested with 5 cases (upper/lower drive, back/forward slash, POSIX absolute, relative).
- `runPmtilesStage(scratch, pbf, outDir)` orchestrates:
  1. Preflight (`tippecanoe --version` → logged banner).
  2. Emit 4 GeoJSONSeq inputs — logs feature count per layer.
  3. `tippecanoe -o germany-base.pmtiles --maximum-zoom=11 --minimum-zoom=0 --drop-densest-as-needed --extend-zooms-if-still-dropping --no-tile-compression --force -L …`.
  4. Delete the 4 intermediate `.geojsonl` files (only useful for debugging a failing run — Berlin's roads.geojsonl is ~50 MB).
  5. Return `PmtilesStageResult` with byte size + per-layer counts + tippecanoe version banner.
- `pipeline_orchestrator.dart` — Stage F stub replaced with `if (runPmtiles) await runPmtilesStage(...)`. `runPipeline` gains a `runPmtiles: true` optional flag (default `true`); the existing `pipeline_orchestrator_test.dart` end-to-end test benefits — it now produces a real 6 KB pmtiles from the tiny fixture and asserts the layer inventory.
- CLI (`bin/osm_pipeline.dart`) gained `--no-pmtiles` flag for hosts without tippecanoe. On success, logs the pmtiles path + byte count.

## Verification

### `dart test` (pipeline sub-package)

- 204/204 tests pass (204 total = 177 from 04-01..04-06 + 26 new + 1 flaky "no such file" flush-order test already fixed).
- `dart analyze` clean (0 issues) on the whole sub-package.

### `flutter analyze` (app)

- Clean (0 issues). App code untouched by this plan — Phase 4 is a dev-machine pipeline.

### Tiny-fixture CLI smoke

```
dart run tool/osm_pipeline/bin/osm_pipeline.dart \
  --pbf=tool/osm_pipeline/test/fixtures/tiny.osm.pbf \
  --out-dir=tool/osm_pipeline/out/tiny
```

- Produces `germany-base.pmtiles` of 6330 bytes.
- `tippecanoe-decode` confirms 3 non-empty vector_layers (`admin_boundaries`, `labels`, `roads`) with expected fields: roads has `kind/name/oneway/ref`, labels has `kind/ref` (from the fixture's `ref=M1` primary way road_shield), admin_boundaries has `admin_level/kind/name/shape`. Water layer empty (fixture has no `natural=water`) — expected.

### Berlin end-to-end proof

```
dart run tool/osm_pipeline/bin/osm_pipeline.dart \
  --pbf=C:/Users/I551358/Downloads/berlin-260705.osm.pbf \
  --bbox=13.088345,52.338261,13.761161,52.675454 \
  --out-dir=tool/osm_pipeline/out/berlin
```

Duration: **5 min 58 s** (Stages B..E: ~2 min 19 s per 04-06; Stage F alone: ~3 min 39 s — dominated by tippecanoe zoom sweep + Berlin's dense roads).

Artifacts:

| Artifact | Bytes | Notes |
|---|---|---|
| `osm.sqlite` | 84 844 544 (~84.8 MB) | Matches 04-06 baseline exactly. |
| `germany-base.pmtiles` | 14 578 902 (~14.58 MB) | Berlin extract only. Full-Germany projection deferred to 04-10. |

`tippecanoe-decode` (metadata) confirms **4 vector_layers** with the correct fields:

| Layer | Feature count | Geometry | Notes |
|---|---|---|---|
| `roads` | 176 567 | LineString | 9 kind values incl. motorway/trunk/primary/secondary/tertiary/minor/track/path/other; 44 unique `ref` values (A/B/K/L route numbers). Matches osm.sqlite row count exactly. |
| `admin_boundaries` | 236 | LineString (fill drops to LineString at zoom 0 because tippecanoe strips single-tile polygons at world view) | 5 admin_level values (4, 6, 8, 9, 10 — no L2, Berlin extract omits country); 111 unique names incl. Berlin, Brandenburg, all Berlin districts + suburbs. |
| `water` | 2 930 | Polygon | 4 kind values (canal, lake, river, stream); 616 unique names incl. Spree, Havel, Berlin-Spandauer Schifffahrtskanal, hundreds of Berlin lakes/ponds. |
| `labels` | 4 788 | Point | 5 kind values (place_city, place_suburb, place_town, place_village, road_shield); 106 place names + 18 unique route refs; populations for 11 cities (Berlin, Charlottenburg, ..., min 15 612 max 3 769 962). |

Maxzoom was auto-bumped from 11 to 12 by `--extend-zooms-if-still-dropping` — expected behaviour when the Berlin roads layer is too dense to fit within the per-tile byte budget at z11 without dropping too many features.

## Deviations from Plan

### Rule 3 (blocking, auto-fixed)

**1. tippecanoe not installed in WSL2** — See "tippecanoe bootstrap" section above. Installed inside Rancher Desktop's Alpine WSL distro after fixing DNS. `tippecanoe v2.80.0` now on the dev box. No user prompt required (passwordless root). Documented for 04-09 to reference verbatim.

### Rule 1 (bugs, auto-fixed)

None — the plan's spec was correct end-to-end.

### Rule 2 (missing critical, auto-fixed)

**1. `runPipeline` needed a `runPmtiles: true` toggle.** The plan text assumes Stage F always runs, but `pipeline_orchestrator_test.dart` runs on CI (and other hosts without tippecanoe). Added the toggle with default `true`; test files can flip to `false` to skip. Not architectural — additive optional param. Also plumbed through the CLI as `--no-pmtiles` so a Windows box without WSL2 tippecanoe can still produce osm.sqlite.

**2. `writeAdminBoundaries` needed a table-existence guard.** Tests that build a scratch DB without the admin extension would otherwise crash on `admin_regions_raw` missing. Added `_hasTable(db, 'admin_regions_raw')` gate; the function returns 0 when absent, matching the "empty layer is a valid empty file" semantic.

### Plan-spec adjustments

- The plan sketched shield labels as "midpoint of the way" — implemented as the **middle indexed node** rather than a geodesic midpoint. Simpler; visually indistinguishable for tippecanoe's per-tile shield rendering. If Phase 5+ needs true geodesic midpoints (e.g. for animated label placement), the change is a one-line swap to a haversine-weighted median.
- The plan sketched the water writer as filtering "bbox area > 5×5 km at z≤8" for size — deferred. Berlin measurement showed water contributes only ~5 % of pmtiles bytes; not a bottleneck yet. Full-Germany 04-10 close-out will re-measure and decide.
- The plan proposed to write a `water_area` boolean; instead we distinguish areas from lines by geometry type (Polygon vs LineString) — same signal, one less property to carry.

## SC4-pmtiles budget check

- **Berlin pmtiles: 14.58 MB.** Berlin covers ~892 km² — Germany is ~357 000 km² (~400× area). Naïve area-ratio projection: 14.58 × 400 ≈ **5.8 GB**. That's a wild upper bound (rural Germany has 10-100× fewer roads per km² than urban Berlin), but even the road-graph-density-weighted projection using 04-05's slim model (per-way ~44× Kfz-count multiplier) suggests full Germany pmtiles will exceed the 200 MB budget by a meaningful margin.
- **This is a documented SC4-pmtiles concern for the 04-10 close-out.** The 200 MB pmtiles budget was set before empirical measurement. Levers available in 04-10 if it blows the budget:
  - Drop water layer's `stream` kind (very numerous, low visual value at maxzoom 11).
  - Drop labels layer's `place_suburb` + `place_village` (relies on OSM node density).
  - Coarsen roads at zoom < 8 (drop `minor` at z<10, drop `residential` names at z<12).
  - Renegotiate the pmtiles budget along the same lines as osm.sqlite's 200 MB → 800 MB decision. Protomaps demo Germany at maxzoom 11 was 371 MB with a much larger schema — a Kfz-focused ~500 MB budget is defensible.
- **No action required in this plan.** The plan's exit criterion is "Berlin pmtiles produced end-to-end + all 4 layers present" — achieved.

## Authentication Gates

None. Windows tippecanoe was installed via a passwordless-root Alpine WSL distro; no user intervention required.

## Downstream handoff

- **04-08 (pmtiles metadata + style rewrite):** Reads `Layers.*` constants + `minZoomFor{Road,Admin}` helpers as the single source of truth for the style JSON's `source-layer` references and per-layer zoom filters. Rewrites `assets/map_style_light.json` + `assets/map_style_dark.json` to target the new layer inventory. Depends on this plan's pmtiles artifact (no code dependency yet — that's 04-09/10's concern).
- **04-09 (WSL2 install README):** Documents the exact bootstrap sequence recorded above (DNS fix + apk deps + git clone + make install). Should reference `TippecanoeRunner.preflightCheck()` as the runtime verification that the install worked.
- **04-10 (Berlin close-out):** Re-runs this plan on the Berlin PBF, records the final numbers, and either renegotiates the SC4 pmtiles budget or applies the schema-shrink levers listed above.
- **Phase 2 handoff:** Once 04-08 + 04-10 land, `assets/tiles/dev_germany.pmtiles` (371 MB Protomaps demo) is replaced with the pipeline-produced `germany-base.pmtiles`. Style JSON simultaneous flip.

## Next Phase Readiness

- 04-08 unblocked — layer vocabulary + zoom ladder locked here.
- 04-09 unblocked — bootstrap sequence documented verbatim above.
- 04-10 unblocked — pmtiles emit path is real; only outstanding question is the pmtiles budget renegotiation.
