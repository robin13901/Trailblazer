---
id: 04-08
phase: 04-osm-pipeline
plan: 08
type: execute
wave: 6
depends_on: [04-07]
files_modified:
  - tool/osm_pipeline/lib/pmtiles/pmtiles_metadata_patcher.dart
  - tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart
  - assets/map_style_light.json
  - assets/map_style_dark.json
  - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
  - tool/osm_pipeline/test/pmtiles/pmtiles_metadata_patcher_test.dart
autonomous: true
requirements: []

must_haves:
  truths:
    - "germany-base.pmtiles carries a JSON metadata block with name=trailblazer-germany-base, version=<pipelineSchemaVersion>, pbf_date, pipeline_schema_version, generated_at, and a vector_layers array reflecting the 4 layers (roads, admin_boundaries, water, labels) with their field definitions"
    - "pmtiles metadata pbf_date + pipeline_schema_version match the corresponding rows in osm.sqlite metadata table (04-RESEARCH §9 requirement)"
    - "assets/map_style_light.json is rewritten from scratch to reference source-layer names roads, admin_boundaries, water, labels — matching 04-07's tippecanoe -L invocations"
    - "assets/map_style_dark.json is rewritten with the same layer structure but dark-mode colors — style JSONs render smoothly on MapLibre GL v0.26.2 (the app's pinned version) with the new pmtiles"
    - "flutter test at repo root remains green — the app's map_widget_test still opens both style JSONs without JSON schema errors"
  artifacts:
    - path: "tool/osm_pipeline/lib/pmtiles/pmtiles_metadata_patcher.dart"
      provides: "Rewrites the metadata JSON block inside a .pmtiles file after tippecanoe emission"
    - path: "assets/map_style_light.json"
      provides: "MapLibre style JSON pointing at Trailblazer's 4-layer vector schema (light)"
    - path: "assets/map_style_dark.json"
      provides: "MapLibre style JSON pointing at Trailblazer's 4-layer vector schema (dark)"
  key_links:
    - from: "assets/map_style_light.json"
      to: "germany-base.pmtiles vector_layers"
      via: "source-layer references match layer names (roads, admin_boundaries, water, labels)"
      pattern: "source-layer"
    - from: "tool/osm_pipeline/lib/pmtiles/pmtiles_metadata_patcher.dart"
      to: "tool/osm_pipeline/lib/output/version_stamp.dart"
      via: "consumes VersionStamp fields for consistency with osm.sqlite metadata"
      pattern: "VersionStamp"
---

## Goal

Stamp `germany-base.pmtiles` with a full version-metadata block matching osm.sqlite, and rewrite the app's two style JSONs to target the new 4-layer vector schema.

## Context

- 04-RESEARCH §9 requires the pmtiles-side metadata to mirror osm.sqlite's metadata table (name, version, pbf_date, pipeline_schema_version, generated_at) + PMTiles v3 spec's `vector_layers` field for MapLibre style rendering.
- tippecanoe writes basic metadata into the pmtiles it produces (name, minzoom, maxzoom, bounds, vector_layers). Whatever it emits is a good baseline — 04-08 REWRITES the metadata block to add our custom keys, not append. Use the `pmtiles` CLI tool OR a Dart implementation of PMTiles v3 metadata read/write.
- App's current style JSONs (`assets/map_style_light.json`, `assets/map_style_dark.json`) were rewritten from Protomaps v4 samples during Phase 2. They target Protomaps' layer names (`roads`, `earth`, `land`, `pois`, `places`, `water`, `natural`, etc.). They will NOT render against our schema (which lacks `earth`, `pois`, `natural`, `land`).
- 04-CONTEXT locks the style rewrite: "Rewrite Phase 2 style JSONs" — no attempt to keep the old Protomaps-derived styles working.
- **THIS PLAN TOUCHES `lib/`-adjacent code path** (styles are in `assets/`, but the app's `lib/features/map/` reads them and asserts layer shape at boot). Per project CLAUDE.md's tiered Ralph Loop: run `flutter test` (not just `flutter analyze`) after this plan's changes.
- MapLibre GL version: pinned via `maplibre_gl: ^0.26.2` in root `pubspec.yaml`. Style JSON must match MapLibre 0.26.x's style spec (based on MapLibre spec v8 with a couple of divergences). Executor consults context7's `resolve-library-id` for `maplibre_gl` if unsure about specific style keys.

## Tasks

<task type="auto">
  <name>Task 1: pmtiles metadata patcher</name>
  <files>
    tool/osm_pipeline/pubspec.yaml
    tool/osm_pipeline/lib/pmtiles/pmtiles_metadata_patcher.dart
    tool/osm_pipeline/lib/pmtiles/pmtiles_pipeline.dart
    tool/osm_pipeline/test/pmtiles/pmtiles_metadata_patcher_test.dart
  </files>
  <intent>Write a full metadata JSON block into germany-base.pmtiles that Phase 5 + Phase 10 can read.</intent>
  <action>
    PMTiles v3 header (127 bytes) contains offsets for the metadata section. The metadata is a compressed (or uncompressed) JSON object. To patch it, we can:

    - **Option A:** Use the `pmtiles` CLI tool (github.com/protomaps/go-pmtiles) — subprocess call. Adds another external binary dependency.
    - **Option B:** Hand-write a minimal PMTiles metadata patcher in Dart. The spec is at github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md. Reading the 127-byte header + finding the metadata section + rewriting it (adjusting the header's offsets if size changed) is ~150 LOC.

    **Choose Option B.** Reasons:
    - Windows dev box already needs tippecanoe via WSL2; adding another native binary is friction we don't want.
    - We only need to touch the metadata section — not tile data. The header math is simple.
    - PMTiles v3 spec is stable since 2023.

    **`pmtiles_metadata_patcher.dart`**:
    ```dart
    /// Reads the PMTiles v3 header at offset 0..127, extracts the current
    /// metadata JSON, merges/replaces the provided keys, and writes back —
    /// adjusting the header's directory-block offsets if the metadata size
    /// changed.
    class PmtilesMetadataPatcher {
      static Future<void> patch(File pmtiles, Map<String, dynamic> patch) async {
        // 1. Read 127-byte header.
        // 2. Parse header (magic bytes, spec version, offsets, sizes,
        //    compression enums — see spec §3.1).
        // 3. Read metadata section using offset + size from header.
        // 4. Decompress (if internal-compression flag = gzip, use archive.GZipDecoder).
        // 5. jsonDecode → merge `patch` on top → jsonEncode → recompress.
        // 6. If new size > old size, rewrite the whole file with adjusted
        //    root-directory offset. If equal or smaller, write in place +
        //    pad with zeros.
        // 7. Update header bytes and rewrite the 127-byte prefix.
      }
    }
    ```

    Key spec bits:
    - Magic: `PMTiles\x03` (8 bytes, `\x03` = version 3).
    - Header layout: little-endian u64 offsets/sizes for root_dir, metadata, leaf_dirs, tile_data.
    - `internal_compression` field (u8) at byte 22: 0=Unknown, 1=None, 2=Gzip, 3=Brotli, 4=Zstd. tippecanoe defaults to Gzip.
    - Metadata JSON structure (`vector_layers` is a top-level array; each element is `{id, description?, fields: {fieldname: 'String'|'Number'|'Boolean'}, minzoom, maxzoom}`).

    **`pmtiles_pipeline.dart`** — after `TippecanoeRunner.run` completes, call:
    ```dart
    await PmtilesMetadataPatcher.patch(out, {
      'name': 'trailblazer-germany-base',
      'version': '${pipelineSchemaVersion}',
      'pbf_date': versionStamp.pbfDate.toIso8601String(),
      'pipeline_schema_version': '${pipelineSchemaVersion}',
      'pipeline_git_sha': versionStamp.gitSha,
      'generated_at': versionStamp.generatedAt.toUtc().toIso8601String(),
      'vector_layers': [
        {
          'id': 'roads',
          'fields': {'kind': 'String', 'name': 'String', 'ref': 'String', 'oneway': 'Boolean'},
          'minzoom': 5, 'maxzoom': 11,
        },
        {
          'id': 'admin_boundaries',
          'fields': {'admin_level': 'Number', 'kind': 'String', 'name': 'String', 'shape': 'String'},
          'minzoom': 0, 'maxzoom': 11,
        },
        {
          'id': 'water',
          'fields': {'kind': 'String', 'name': 'String'},
          'minzoom': 0, 'maxzoom': 11,
        },
        {
          'id': 'labels',
          'fields': {'kind': 'String', 'name': 'String', 'ref': 'String', 'population': 'Number'},
          'minzoom': 0, 'maxzoom': 11,
        },
      ],
    });
    ```

    **`pmtiles_metadata_patcher_test.dart`**:
    - Given a minimal synthetic pmtiles file (hand-written header + short gzip'd JSON metadata + a fake 1-tile root directory): call `patch({'name': 'foo'})`. Reopen and verify the metadata JSON has `name=foo` plus all prior keys.
    - Adding a large new field (grows metadata size by > current padding) → header offsets shift correctly; the file's root-dir + tile-data offsets are still valid.
    - Test replaces `vector_layers` and verifies the array is preserved as an array (not stringified).
    - Round-trip determinism: `patch(X)` then `patch(X)` twice with the same input produces byte-identical files.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test test/pmtiles/pmtiles_metadata_patcher_test.dart` — green.
    Manual on tiny fixture: after full run, `dart run tool/osm_pipeline/bin/dump_pmtiles_metadata.dart out/germany-base.pmtiles` (add a tiny dump-metadata bin/ tool if useful for debugging) prints all 7 top-level keys + the 4-entry vector_layers array.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Rewrite map_style_light.json for the 4-layer schema</name>
  <files>
    assets/map_style_light.json
  </files>
  <intent>Emit a MapLibre style JSON pointing at Trailblazer's 4 layers, light theme.</intent>
  <action>
    Consult context7 for `maplibre_gl` (or `maplibre-gl-js` — the underlying spec is identical) style-spec docs. Confirm layer types: `line`, `fill`, `symbol` are all we need.

    Structure the style JSON as (schematic — expand with concrete colors):

    ```json
    {
      "version": 8,
      "name": "Trailblazer Light",
      "sprite": null,
      "glyphs": "asset://assets/glyphs/{fontstack}/{range}.pbf",
      "sources": {
        "trailblazer": {
          "type": "vector",
          "url": "pmtiles://asset/germany-base.pmtiles",
          "attribution": "© OpenStreetMap contributors"
        }
      },
      "layers": [
        { "id": "background", "type": "background", "paint": { "background-color": "#f5f5f2" } },
        {
          "id": "water-fill", "type": "fill", "source": "trailblazer", "source-layer": "water",
          "filter": ["!=", "kind", "river"],
          "paint": { "fill-color": "#a8d5f0" }
        },
        {
          "id": "water-river", "type": "line", "source": "trailblazer", "source-layer": "water",
          "filter": ["==", "kind", "river"],
          "paint": { "line-color": "#8dc3e6", "line-width": ["interpolate", ["linear"], ["zoom"], 7, 0.5, 12, 2.5] }
        },
        {
          "id": "admin-fill-l4", "type": "fill", "source": "trailblazer", "source-layer": "admin_boundaries",
          "filter": ["all", ["==", "shape", "fill"], ["==", "admin_level", 4]],
          "paint": { "fill-color": "#f0ede8", "fill-opacity": 0.1 }
        },
        {
          "id": "admin-line-l4", "type": "line", "source": "trailblazer", "source-layer": "admin_boundaries",
          "filter": ["all", ["==", "shape", "outline"], ["==", "admin_level", 4]],
          "paint": { "line-color": "#c0b8a8", "line-width": 1.2, "line-dasharray": [3, 2] }
        },
        {
          "id": "admin-line-l6", "type": "line", "source": "trailblazer", "source-layer": "admin_boundaries",
          "filter": ["all", ["==", "shape", "outline"], ["==", "admin_level", 6]],
          "paint": { "line-color": "#c8c0b0", "line-width": 0.8, "line-dasharray": [2, 2] }
        },
        {
          "id": "road-minor", "type": "line", "source": "trailblazer", "source-layer": "roads",
          "minzoom": 11,
          "filter": ["in", "kind", "minor", "track", "path"],
          "paint": { "line-color": "#dddad0", "line-width": ["interpolate", ["linear"], ["zoom"], 11, 0.5, 15, 3] }
        },
        {
          "id": "road-tertiary", "type": "line", "source": "trailblazer", "source-layer": "roads",
          "minzoom": 10,
          "filter": ["==", "kind", "tertiary"],
          "paint": { "line-color": "#e8e2c8", "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.6, 15, 4] }
        },
        {
          "id": "road-secondary", "type": "line", "source": "trailblazer", "source-layer": "roads",
          "minzoom": 9,
          "filter": ["==", "kind", "secondary"],
          "paint": { "line-color": "#f2e9b8", "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.8, 15, 5] }
        },
        {
          "id": "road-primary", "type": "line", "source": "trailblazer", "source-layer": "roads",
          "minzoom": 7,
          "filter": ["==", "kind", "primary"],
          "paint": { "line-color": "#f2d795", "line-width": ["interpolate", ["linear"], ["zoom"], 7, 0.8, 15, 6] }
        },
        {
          "id": "road-trunk", "type": "line", "source": "trailblazer", "source-layer": "roads",
          "minzoom": 6,
          "filter": ["==", "kind", "trunk"],
          "paint": { "line-color": "#f5c26a", "line-width": ["interpolate", ["linear"], ["zoom"], 6, 1, 15, 7] }
        },
        {
          "id": "road-motorway", "type": "line", "source": "trailblazer", "source-layer": "roads",
          "minzoom": 5,
          "filter": ["==", "kind", "motorway"],
          "paint": { "line-color": "#e88f4a", "line-width": ["interpolate", ["linear"], ["zoom"], 5, 1, 15, 8] }
        },
        {
          "id": "label-place-city", "type": "symbol", "source": "trailblazer", "source-layer": "labels",
          "minzoom": 5,
          "filter": ["==", "kind", "place_city"],
          "layout": { "text-field": ["get", "name"], "text-size": 14, "text-font": ["Noto Sans Regular"] },
          "paint": { "text-color": "#333", "text-halo-color": "#fff", "text-halo-width": 1.2 }
        },
        {
          "id": "label-place-town", "type": "symbol", "source": "trailblazer", "source-layer": "labels",
          "minzoom": 9,
          "filter": ["==", "kind", "place_town"],
          "layout": { "text-field": ["get", "name"], "text-size": 12, "text-font": ["Noto Sans Regular"] },
          "paint": { "text-color": "#555", "text-halo-color": "#fff", "text-halo-width": 1.2 }
        }
      ]
    }
    ```

    Match the palette to what Phase 2 already had (warm-cartoon vibe). Cross-check against the app's `MapWidget` initialization (`lib/features/map/**`) — the `styleUrl` currently points at `asset://assets/map_style_light.json`, no code change needed. The pmtiles URL format `pmtiles://asset/germany-base.pmtiles` may vary depending on the app's protocol handler — check what Phase 2's `pmtiles_base_map` plan used and MATCH IT verbatim.

    Consult `lib/features/map/pmtiles_source.dart` (or wherever the pmtiles source is wired) for the exact URL scheme.

    The `sprite` field is null in this rewrite (no shields in v1); road-shield rendering is stubbed in the labels layer with `text-field=ref` — style adds shield sprites in a v1.1 polish pass.

    Glyphs asset: `asset://assets/glyphs/{fontstack}/{range}.pbf` requires the app to bundle Noto Sans glyphs. Check if Phase 2 already bundles them at `assets/glyphs/`. If NOT, add a comment to STATE.md tracking that the label layer will fall back to system-font text UNTIL a follow-up ships the glyph PBFs. The `text-font` value should probably match whatever Phase 2 was using — inspect the existing style JSONs BEFORE rewriting.
  </action>
  <verify>
    `cat assets/map_style_light.json | jq . > /dev/null` — valid JSON (or Dart's `jsonDecode` — the executor does not have `jq` on Windows).
    `flutter test test/features/map/` — passes (the app's map_widget_test should smoke-open the style JSON at test time; if there's no such test, this is not a regression).
  </verify>
</task>

<task type="auto">
  <name>Task 3: Rewrite map_style_dark.json + repo-level flutter test</name>
  <files>
    assets/map_style_dark.json
  </files>
  <intent>Dark-mode variant using same layer structure, dark palette.</intent>
  <action>
    Duplicate the light-mode structure from Task 2 with dark-appropriate colors:

    - background: `#1a1a1a`
    - water fills: `#12324a`
    - water rivers: `#22506e`
    - admin fills: `#26241f` at low opacity
    - admin lines: darker warm gray (`#5a5240`)
    - roads: darker warm/orange progression for the class hierarchy
    - label text-color: light warm gray (`#c8c0a8`), halo `#000` for contrast

    Keep every layer id and filter identical to `map_style_light.json` — only palette differs. This ensures the app's dark/light switch (Phase 2's `dark_mode_style_switch`) toggles cleanly without map re-layout.

    Cross-check the two files with a diff after writing — filter arrays and layer ids MUST match; only `paint` blocks differ.

    After both style JSONs are in place, run `flutter test` at repo root. Any test that loads the styles (e.g. `test/features/map/map_widget_test.dart`) must still pass.

    If a map-widget test does NOT exist, add a small smoke test:

    ```dart
    // test/assets/map_styles_test.dart
    test('map_style_light.json is valid MapLibre style JSON', () async {
      final txt = await File('assets/map_style_light.json').readAsString();
      final json = jsonDecode(txt) as Map<String, dynamic>;
      expect(json['version'], 8);
      expect(json['sources']?.containsKey('trailblazer'), isTrue);
      final layerIds = (json['layers'] as List)
        .map((l) => (l as Map)['id']).toSet();
      expect(layerIds, contains('road-motorway'));
      expect(layerIds, contains('admin-line-l4'));
    });

    test('map_style_dark.json shares layer ids with light', () async {
      final lightTxt = await File('assets/map_style_light.json').readAsString();
      final darkTxt = await File('assets/map_style_dark.json').readAsString();
      final lightIds = ((jsonDecode(lightTxt) as Map)['layers'] as List)
        .map((l) => (l as Map)['id']).toSet();
      final darkIds = ((jsonDecode(darkTxt) as Map)['layers'] as List)
        .map((l) => (l as Map)['id']).toSet();
      expect(darkIds, equals(lightIds));
    });
    ```

    Add this test to guard against future style-JSON drift.
  </action>
  <verify>
    Both style JSONs parse as valid JSON.
    `flutter test test/assets/map_styles_test.dart` (or the equivalent) — green.
    `flutter test` at repo root — green.
    `flutter analyze` clean.
  </verify>
</task>

## Verification

- `cd tool/osm_pipeline && dart test test/pmtiles/pmtiles_metadata_patcher_test.dart` — green.
- After end-to-end run on tiny fixture: `germany-base.pmtiles` metadata JSON contains all 7 top-level keys + 4-entry vector_layers array.
- `assets/map_style_light.json` and `assets/map_style_dark.json` parse as valid JSON.
- `flutter test` at repo root — green.
- `flutter analyze` clean.

## Deviation Handling

- If PMTiles v3 metadata patching turns out to require more than the spec suggests (compression flag mismatch, endianness surprise), the fallback is to build the pmtiles from scratch via `pmtiles convert` (Go CLI) after tippecanoe — but that's another external binary and 04-09's WSL2 doc doesn't cover it. Prefer sticking with the hand-written patcher and iterating on any bugs.
- If MapLibre GL 0.26.x style spec has divergences from mainline (map style spec v8), consult context7 for `maplibre_gl` before shipping surprising expressions. Known divergence: `interpolate` expressions require the type argument (`["linear"]`) before the input.
- If tippecanoe's default gzip compression on the pmtiles' tile data conflicts with the app's `maplibre_gl` decoder, revisit 04-07's `--no-tile-compression` flag decision (may need to flip).
- Glyphs: if the app doesn't have Noto Sans PBFs bundled, label text won't render. This is a KNOWN cosmetic gap; document in the plan's SUMMARY. Follow-up shipping glyphs is out of Phase 4 scope.
- Iterate up to 3 times per task; if blocked, report failing output verbatim.
