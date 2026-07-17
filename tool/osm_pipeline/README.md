# Trailblazer OSM Pipeline

Dev-machine Dart CLI that turns a Geofabrik `germany-latest.osm.pbf` into two
slim runtime artifacts:

- `osm.sqlite` — Kfz + Feldweg way geometries, R-Tree, `way_admin` join, version stamp
- `germany-base.pmtiles` — offline vector base map (roads, admin_boundaries, water, labels)

Consumed by Phase 5 (matcher isolate) and Phase 2/7 (map rendering + coverage overlay).

## Prerequisites

- Dart SDK ≥ 3.5 (already installed for the app)
- **tippecanoe** — required for pmtiles authoring (Stage D). See below for install.
- ~30 GB free disk (scratch DB for full Germany run)
- ~4 GB free RAM

### Installing tippecanoe

| Platform | Install |
|----------|---------|
| macOS    | `brew install tippecanoe` |
| Linux    | Distro package or build from source (github.com/felt/tippecanoe) |
| **Windows (this dev box)** | Install under WSL2. The pipeline shells out to `wsl.exe -- tippecanoe ...`. See [`tippecanoe/README.md`](tippecanoe/README.md) for step-by-step install (Ubuntu-in-WSL2 and Rancher-Desktop-Alpine paths, DNS fix, troubleshooting). |

## Running

**One-command Berlin smoke** (recommended first run — downloads the PBF from
Geofabrik, runs the pipeline, asserts both artifacts exist, ~60 s):

```bash
# macOS / Linux / Git Bash
./tool/osm_pipeline/smoke.sh

# Windows PowerShell
pwsh tool\osm_pipeline\smoke.ps1
```

**Manual Berlin bbox** (fast dev iteration, ~60 s):

```bash
dart run tool/osm_pipeline \
  --pbf=/path/to/berlin-latest.osm.pbf \
  --bbox=13.0,52.3,13.8,52.7
```

Full Germany (~30–90 min):

```bash
dart run tool/osm_pipeline --pbf=/path/to/germany-latest.osm.pbf
```

## Pipeline shape

The pipeline is pure-Dart end-to-end except for Stage D, which shells out to
`tippecanoe` for the pmtiles authoring pass.

```
Stage A: PBF stream parse + filter              (pure Dart, plan 04-02/04-03/04-04)
Stage B: segmented intersection + way_admin     (pure Dart, plan 04-05)
Stage C: osm.sqlite write + R-Tree build        (pure Dart, plan 04-06)
Stage D: GeoJSONSeq emit + tippecanoe           (subprocess, plan 04-07)
Stage E: pmtiles metadata + style rewrite       (pure Dart, plan 04-08)
Stage H: admin bundle + per-region totals       (pure Dart, plan 10-03)
```

## Stage H — Admin bundle + region totals (Plan 10-03)

Stage H reads the final `osm.sqlite` (produced by Stage E) and emits two
bundled assets that are keyed by the **same `osm_relation_id`** set:

- `germany_admin.geojson.gz` — admin boundary polygon bundle including
  admin_level=9 Ortsteil regions (L2 excluded; L9 included).
- `region_totals.json.gz` — `Map<String,double>` of `osm_id → total Kfz road
  length in meters` for every region at levels 4/6/8/9/10.

Enable Stage H by passing both flags to the pipeline CLI:

```bash
cd tool/osm_pipeline
dart run bin/osm_pipeline.dart \
  --pbf=/path/to/germany-latest.osm.pbf \
  --no-pmtiles \
  --emit-admin-bundle=../../assets/admin/germany_admin.geojson.gz \
  --emit-totals=../../assets/admin/region_totals.json.gz
```

If the admin bundle exceeds the 15 MB gzipped budget, add
`--stage-h-tolerance=150` to tighten L8/L9/L10 simplification.

### Verifying the key-set invariant (invariant 5)

After any regeneration, run the build-time assertion to confirm both assets
share the same `osm_id` key-set:

```bash
cd tool/osm_pipeline
dart run bin/verify_bundle_totals_keys.dart
# exits 0 on match; exits 1 with a diff on mismatch; exits 2 on I/O error
```

This CLI reads the shipped assets from `assets/admin/` by default. Pass
`--assets-dir=<path>` to point at a different directory.

## Testing

The pipeline lives under `tool/` and is not part of the Flutter app package.
Run its unit tests directly:

```bash
cd tool/osm_pipeline
dart test
```

The repo's pre-push hook runs `flutter test` for the app package.
Pipeline tests are run manually today; a CI job may pick them up later.

## Skipped-log

Stages A–D write malformed geometries, orphan tags, and self-intersecting
multipolygons to `<out-dir>/skipped.log` and continue. See 04-RESEARCH.md §12
for the enumerated pitfalls.

## Version stamp

`lib/schema.dart` exports `pipelineSchemaVersion` — bump when the on-disk
schema of `osm.sqlite` or the pmtiles layer inventory changes in a way that
breaks Phase 5's integrity check. Phase 5 reads this value from
`PRAGMA user_version`; Phase 10 reads the same integer from pmtiles metadata.
