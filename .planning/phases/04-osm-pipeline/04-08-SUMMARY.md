---
id: 04-08
phase: 04-osm-pipeline
plan: 08
title: pmtiles Metadata + Style JSON Rewrite
status: complete
subsystem: osm-pipeline
tags: [pmtiles, metadata, maplibre, style-json, vector-tiles, phase-2-handoff]
requires: [04-07]
provides:
  - PMTiles v3 metadata patcher (Dart, no external deps)
  - Stage F.3 wired into pipeline_orchestrator (metadata patch after tippecanoe)
  - trailblazer-germany-base metadata block (9 keys + vector_layers array)
  - map_style_light.json rewritten for 4-layer schema
  - map_style_dark.json rewritten for 4-layer schema
  - test/assets/map_styles_test.dart (4-assertion style contract)
affects: [04-09, 04-10, 05, 10]
tech-stack:
  added: []
  patterns:
    - PMTiles v3 metadata patch via atomic .tmp + rename (safe under crash)
    - full-file rewrite when metadata section grows/shrinks (offsets updated)
    - gzip roundtrip via dart:io built-in codec (no `archive` dep needed)
    - MapLibre v8 expression syntax (`['get', key]`, `['literal', [...]]`) —
      required for both string filters (`kind`) and number filters
      (`to-number` on `admin_level`, `population`)
    - identical dark/light layer id list preserves brightness swap (no relayout)
    - test/assets/**_test.dart hosts pure-JSON contract tests (no Flutter
      binding needed) — lightweight guard against style drift
key-files:
  created:
    - tool/osm_pipeline/lib/pmtiles/pmtiles_metadata_patcher.dart
    - tool/osm_pipeline/test/pmtiles/pmtiles_metadata_patcher_test.dart
    - test/assets/map_styles_test.dart
  modified:
    - tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart
    - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
    - assets/map_style_light.json
    - assets/map_style_dark.json
metrics:
  duration: ~12 min
  completed: 2026-07-06
  tests_added: 11 (7 pipeline + 4 flutter)
  tests_total_pipeline: 211
  tests_total_flutter: 145
  commits: 3
---

# Phase 4 Plan 08: pmtiles Metadata + Style JSON Rewrite Summary

**One-liner:** Hand-rolled Dart PMTiles v3 metadata patcher stamps `germany-base.pmtiles` with the same 9-key version block as `osm.sqlite` (via `VersionStamp`) plus a 4-entry `vector_layers` array; both app style JSONs (light + dark) rewritten from scratch to target the tippecanoe layer inventory (roads/admin_boundaries/water/labels) with 24 identically-keyed layers; guarded by 4 pure-JSON contract tests + 7 patcher unit tests.

## Objective

Close the OSM-pipeline output loop:

1. Stamp the pmtiles metadata block with the same identity fields as `osm.sqlite` so Phase 5's runtime integrity check can confirm both artifacts came from the same source PBF via `pbf_sha256`.
2. Rewrite the app's Phase-2-era style JSONs (Protomaps v4 schema) to target the 4-layer schema tippecanoe emits, so Phase 2's map widget renders our pipeline output correctly.

## Tasks completed

### Task 1 — PMTiles metadata patcher + Stage F.3 wiring

Commit: `bf91a6b feat(04-08): pmtiles metadata patcher + Stage F.3 wiring`

**`tool/osm_pipeline/lib/pmtiles/pmtiles_metadata_patcher.dart`** (~280 LOC).

Strategy: full-file rewrite via sibling `.tmp` + rename.

- **`patch(File pmtiles, Map<String, dynamic> patch)`**: reads the 127-byte v3 header, extracts existing metadata (gzip-decodes if `internal_compression=Gzip(2)`), JSON-decodes it, merges the caller's patch on top, recomputes section offsets (root_dir @ 127, metadata after root_dir, leaf_dirs after metadata, tile_data after leaf_dirs), and writes header + all 4 sections to a sibling `.tmp` file that atomically replaces the original via `rename()`.
- **`readMetadata(File pmtiles)`**: public helper returning the parsed metadata JSON — used for manual debugging + tests.
- **Compression support**: handles `None(1)` and `Gzip(2)`; falls back to `raw` on `Unknown(0)` if gzip decode fails (some older tippecanoe builds).
- **Endianness**: little-endian u64 for all 8 offset/size fields, per PMTiles v3 spec §3.1.
- **Bytes 72..126 preserved verbatim**: `num_addressed_tiles` + zoom + bounds + centre — none of which we edit.

**`pmtiles_pipeline.dart`** now accepts `VersionStamp? versionStamp` in `runPmtilesStage`. When supplied (production path — orchestrator always supplies), calls `PmtilesMetadataPatcher.patch(pmtiles, _buildMetadataPatch(stamp))` as **Stage F.3** immediately after intermediate `.geojsonl` cleanup.

**`_buildMetadataPatch(VersionStamp stamp)`**: constructs the 9-key + `vector_layers` metadata dict:

```json
{
  "name": "trailblazer-germany-base",
  "version": "1",
  "pbf_date": "2026-07-05T...",
  "pbf_source": "berlin-260705.osm.pbf",
  "pbf_sha256": "<64-char hex>",
  "bbox": "13.088,52.338,13.761,52.675",
  "pipeline_schema_version": "1",
  "pipeline_git_sha": "<git rev>",
  "generated_at": "2026-07-06T...",
  "vector_layers": [ 4 entries with id/description/fields/minzoom/maxzoom ]
}
```

Every key mirrors the `osm.sqlite` metadata table (04-RESEARCH §9). `pbf_sha256` is the runtime cross-check field.

**`kTrailblazerVectorLayers`** — top-level constant listing the 4 vector layers with their field types (`String`/`Number`/`Boolean`) per PMTiles v3 spec. This is the second source of truth for the schema (first is `Layers.*` constants used by tippecanoe's `-L` invocations); a future refactor could unify them.

**Tests (`test/pmtiles/pmtiles_metadata_patcher_test.dart`)** — 7 assertions covering:

1. Gzip-compressed metadata round-trip
2. Uncompressed (`None`) metadata round-trip
3. Bogus (non-PMTiles) file rejected with `FormatException`
4. Patch merges: caller keys override, existing keys preserve
5. `vector_layers` array survives as JSON array (not stringified)
6. Growing metadata beyond original size correctly shifts offsets — asserts the tile-data + root-dir sections are byte-identical at their new offsets
7. Idempotency — `patch(X)` twice produces the same read-back metadata

Fixture builder in the test file hand-assembles a valid PMTiles v3 header + gzip'd JSON metadata + dummy sections; no tippecanoe dependency needed to test the patcher.

**Pipeline suite:** 211/211 green (was 204/204 in 04-07; +7 patcher). Tiny-fixture end-to-end test produces a real pmtiles that goes through Stage F.3 metadata patch — logged as "Stage F.3: patch pmtiles metadata..." in the test output.

**`pipeline_orchestrator.dart`** — one-line change: passes `versionStamp: stamp` into `runPmtilesStage` so metadata patching happens on every real pipeline run.

### Task 2 — Rewrite `map_style_light.json`

Commit: `61327fd feat(04-08): rewrite map_style_light.json for 4-layer schema`

Full file rewrite from Protomaps v4 (`earth`/`landcover`/`landuse`/`pois`/`places`/`transit`/`boundaries`) to Trailblazer's 4-layer schema.

**24 layers**, in draw order:

| Group | Layer ids |
|---|---|
| Background | `background` |
| Water | `water-fill`, `waterway-{river,canal,stream}` — split on `kind` via `['get','kind']` |
| Admin | `admin-fill-l4`, `admin-line-l{2,4,6,8}` — filter on `shape` + `to-number(admin_level)` |
| Roads | `road-{path,track,minor-casing,minor,tertiary,secondary,primary,trunk,motorway}` — minor-casing/fill pair for the double-drawn cased effect Phase 2 established |
| Labels | `label-place-{city,town,village,suburb}`, `label-road-shield` |

Key style-spec choices:

- **MapLibre v8 expression syntax** used throughout: `['get', 'kind']` instead of legacy `['==', 'kind', 'x']` (the legacy form works too, but expressions handle typed fields more predictably).
- **`['to-number', ['get', 'admin_level'], 0]`** — guards against `admin_level` coming back as string after MVT roundtrip (tippecanoe can preserve number type, but be defensive).
- **`['literal', ['minor', 'other']]`** — required for `['in', ...]` with an inline array of values (v8 spec requirement).
- **`interpolate` expressions** carry the `['linear']` type argument as MapLibre 0.26.x requires (documented divergence in the plan's Deviation Handling).
- **`sprite: null`** — no shield glyphs in v1 (Protomaps demo sprites removed); road_shield rendered as plain text via the labels layer.
- **`glyphs`** still points at Protomaps CDN for Noto Sans — bundling glyphs is a follow-up (see "Known cosmetic gaps" below).
- **Source URL:** `http://127.0.0.1:7070/{z}/{x}/{y}.pbf` — preserves Phase 2's loopback TileServer contract (STATE.md decision from Plan 02-02: MapLibre 0.26.2 doesn't resolve `pmtiles://` on Android natively, so a Dart shelf loopback serves XYZ from the bundled pmtiles asset).
- **Population-based label sort key**: `place_city` labels use `symbol-sort-key: ['-', 100000000, ['to-number', ['get', 'population'], 0]]` so denser cities render first when tile-level label collisions kick in.

Palette matches Phase 2's warm-cartoon light theme (`#f2f1ef` background, `#ffd280` primary roads, `#eda04a` motorways).

### Task 3 — Rewrite `map_style_dark.json` + smoke tests

Commit: `879528c feat(04-08): rewrite map_style_dark.json + style contract smoke tests`

Dark style mirrors the light style structure exactly — same 24 layer ids in the same order, same filters, same zoom gates. Only paint blocks differ. This preserves Phase 2's brightness-swap contract: `map_style_fade` widget assumes the two styles are structurally identical so it can cross-fade paint without re-laying out geometries.

Dark palette (excerpt):
- `background`: `#0a1728` (deep navy)
- `water-fill`: `#061024`
- roads: cool-blue minor → warm-orange trunk (`#3a4d6b` → `#f0b040`)
- admin lines: warm gray taper (`#78715a` → `#3a3628`)
- labels: light warm gray (`#cfd8e0`), road_shield in `#e8a038`, halo `#0a1728` for contrast

**`test/assets/map_styles_test.dart`** — 4 pure-JSON contract tests:

1. `map_style_light.json` parses as MapLibre v8 with a `trailblazer` source + required layer ids
2. `map_style_dark.json` parses as MapLibre v8 with a `trailblazer` source
3. Dark shares the identical ordered layer id list with light — guard against structural drift
4. Every non-background layer targets one of the 4 allowed source-layers (`roads`/`admin_boundaries`/`water`/`labels`) with source `trailblazer` — guard against accidental Protomaps-v4 name leaks

These tests live in `test/assets/` because they don't need a Flutter binding — pure `dart:io` + `dart:convert`. This keeps them fast (< 1 s) and reduces the risk of masking real regressions behind Flutter test overhead.

**Full flutter test suite: 145/145 green** (was 141 in 03-07 baseline; +4 from this plan's smoke tests). All 8 existing map_widget_test cases still pass — style asset paths are still `assets/map_style_{light,dark}.json`, no code change in `lib/features/map/` needed.

**flutter analyze: clean.**

## Verification

### Pipeline sub-package

```bash
cd tool/osm_pipeline && dart analyze
# No issues found!

cd tool/osm_pipeline && dart test
# 211/211 tests passed
```

### App

```bash
flutter analyze
# No issues found!

flutter test
# 145/145 tests passed
```

Style JSON validity (Python parsed for cross-check since Windows lacks `jq`):

```bash
python -c "import json; print(len(json.load(open('assets/map_style_light.json'))['layers']))"
# 24
python -c "import json; l=json.load(open('assets/map_style_light.json')); d=json.load(open('assets/map_style_dark.json')); print([x['id'] for x in l['layers']] == [x['id'] for x in d['layers']])"
# True
```

### End-to-end pipeline (tiny fixture)

Existing `pipeline_orchestrator_test.dart` end-to-end test now exercises Stage F.3 as part of every run — logs `Stage F.3: patch pmtiles metadata...` and produces a 6625-byte pmtiles carrying the full metadata block. The test asserts the pipeline result but does NOT yet assert the pmtiles metadata contents — that assertion is a plausible add for 04-09/04-10 if the runtime integrity check needs stricter guarantees.

## Deviations from Plan

### Rule 1 — bugs auto-fixed

None. Patch spec was correct end-to-end.

### Rule 2 — missing critical, auto-fixed

**1. `dart:io` `gzip` codec is enough — no `archive` package needed.** The plan suggested `archive.GZipDecoder`. Instead used the built-in `gzip` codec from `dart:io`, which handles both encode and decode with zero deps. Kept `pubspec.yaml` untouched.

**2. `readMetadata()` helper added.** Not strictly required by the plan, but useful for tests + eventual runtime integrity checks. Purely additive.

**3. `kTrailblazerVectorLayers` exposed as a top-level `const`.** The plan sketched the vector_layers list inline in the orchestrator call site. Lifting it to a named `const` in `pmtiles_pipeline.dart` makes it grep-able from the app side (future Phase 5 runtime cross-check code path can `import` it) without needing to re-derive.

### Rule 3 — blockers, auto-fixed

None.

### Rule 4 — architectural

None. All choices stayed within the plan's action envelope.

### Plan-spec adjustments

- **Metadata patching strategy:** the plan sketched two options — write-in-place with offset shift OR full-file rewrite. Chose **full-file rewrite via `.tmp` + rename**. Rationale: safer under crash (either old or new file survives, never a torn write), simpler code, ~100 ms overhead on a 14.58 MB Berlin pmtiles (negligible next to tippecanoe's 3-4 min). If full-Germany pmtiles balloons to 400 MB the rewrite becomes several seconds — still acceptable, not a bottleneck.
- **`pmtiles://` URL scheme NOT used in the style JSON.** Plan sketched `"pmtiles://asset/germany-base.pmtiles"`. Real Phase 2 setup uses `http://127.0.0.1:7070/{z}/{x}/{y}.pbf` via a Dart shelf loopback because MapLibre 0.26.2 on Android doesn't resolve `pmtiles://` natively. Kept the loopback URL verbatim per STATE.md decision from Plan 02-02. The app's `TileServer` (in `lib/features/map/data/tile_server.dart`) is unchanged — it still reads `assets/tiles/dev_germany.pmtiles`, which 04-10 will replace with the pipeline-produced `germany-base.pmtiles` in one atomic swap.
- **Glyphs source:** plan asked to check `assets/glyphs/` bundling; none exists. Kept the Protomaps CDN URL for `Noto Sans Regular/Medium` — this means text renders on Android **only when online**. Documented as a known cosmetic gap below.
- **Style JSON is 24 layers, not the 13-layer sketch in the plan.** Plan sketched a minimal 13-layer style. Expanded to 24 to properly split the 9 road kinds, 4 water kinds, 5 admin outline levels, and 5 label kinds — matching what 04-07 actually emitted (motorway/trunk/primary/secondary/tertiary/minor/track/path/other × river/canal/stream/lake × L2/4/6/8/9/10 × place_city/town/village/suburb + road_shield). Style completeness bought at the cost of a longer JSON file; still trivially maintainable and well within MapLibre's per-style layer budget (thousands).

## Known cosmetic gaps (not regressions)

1. **Label text won't render offline until glyphs are bundled.** The `glyphs` field still points at `https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf`. When offline, place labels + road shields silently disappear (MapLibre draws no fallback text). Follow-up: bundle Noto Sans Regular + Medium under `assets/glyphs/` and switch the URL to `asset://assets/glyphs/{fontstack}/{range}.pbf`. Out of Phase 4 scope.
2. **Road shields are text-only.** No shield sprites in this rewrite (`sprite: null`). Autobahn `A100` renders as bare orange text on white halo rather than a proper shield graphic. Follow-up: v1.1 sprite pack under `assets/sprites/`. Out of Phase 4 scope.
3. **Deep-zoom (z >= 13) rendering only meaningful at z <= 12.** Berlin pmtiles maxzoom is 12; the style covers z 5..18 but tippecanoe over-zooms tiles for z 13..18. Not a bug — MapLibre handles over-zoom natively — but visual sharpness plateaus at z 12.

## Authentication Gates

None. All work was file-writing + local test execution.

## Downstream handoff

- **04-09 (Berlin smoke + WSL2 install README):** Can now render the pipeline-produced pmtiles in the app — swap `dev_germany.pmtiles` → `germany-base.pmtiles` at asset load time. In-car checkpoint owns the visual verification (drive through Berlin, confirm 4 layers render, brightness swap toggles cleanly).
- **04-10 (Germany close-out):** Runs pipeline on full Germany PBF → produces `germany-base.pmtiles` at final scale → atomically swaps into `assets/tiles/dev_germany.pmtiles` → style JSONs already point at the right layer inventory (this plan's contribution). Also owns re-measuring pmtiles size against the SC4 budget flagged in 04-07-SUMMARY.
- **Phase 5 (integrity check):** Reads the pmtiles metadata block via `PmtilesMetadataPatcher.readMetadata()` — the reader is already exposed as public API. Cross-checks `pbf_sha256` against `osm.sqlite`'s metadata table; on mismatch, forces user to redownload.
- **Phase 10 (extract-swap):** Compares `pbf_date` field in the incoming download's metadata block to the installed one to decide whether to prompt for update. Same public reader.

## Next Phase Readiness

- 04-09 unblocked — pmtiles now carries full identity + layer schema; app style JSONs consume the schema.
- 04-10 unblocked — swap-in path is a byte replacement of the asset, style JSONs already correct.
- Phase 5 integrity check has a stable reader API (`PmtilesMetadataPatcher.readMetadata`) it can wire to.
