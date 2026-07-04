# Dev Tile: dev_germany.pmtiles

## What This File Is

A bundled PMTiles v4 vector tile archive covering all of Germany. Used for offline
map rendering during development. This is the tile source for `MapWidget` in debug builds.

**Git policy:** This file **is gitignored**. Run `tool/fetch_pmtiles.sh` (Unix/Git Bash)
or `tool/fetch_pmtiles.ps1` (Windows PowerShell) after cloning to fetch.
Phase 4 replaces this with a custom-built `germany-base.pmtiles` from the OSM pipeline.

## Source

- **Provider:** Protomaps demo planet (https://demo-bucket.protomaps.com/v4.pmtiles)
- **Schema:** Protomaps Version 4 (basemaps v4 flavors)
- **Download date:** 2026-07-04
- **Planet build date:** 2026-07-03 (latest stable planet from demo-bucket.protomaps.com)

## Extraction Command

```bash
# Requires pmtiles CLI v1.30.3+ (https://github.com/protomaps/go-pmtiles/releases)
pmtiles extract \
  https://demo-bucket.protomaps.com/v4.pmtiles \
  assets/tiles/dev_germany.pmtiles \
  --bbox=5.866,47.270,15.042,55.058 \
  --maxzoom=11
```

Note: maxzoom 14 (~3.2 GB) and maxzoom 13 (~1.8 GB) were both attempted but exceeded
the 500 MB practical limit for APK debug bundling. maxzoom 11 produces 371 MB (5125 tiles)
which MapLibre renders by overzooming at higher zoom levels. Detail is sufficient for
Phase 2 smoke testing. Phase 4 replaces this with a leaner custom-built schema.

Or use the provided fetch script:

```bash
bash tool/fetch_pmtiles.sh          # Unix / Git Bash
pwsh tool/fetch_pmtiles.ps1         # Windows PowerShell
```

- **Bounding box:** 5.866°E, 47.270°N to 15.042°E, 55.058°N
  (Konstanz to Sylt, Aachen to Görlitz — full Germany)
- **Zoom range:** z0–z11 (national overview through district-level zoom)

## Approximate Size + Zoom Range

| Property | Value |
|----------|-------|
| File size | 371 MB (5125 tiles, gzip compressed) |
| Zoom min | 0 |
| Zoom max | 11 |
| Coverage | Full Germany (Konstanz → Sylt, Aachen → Görlitz) |

At z14–z15 (app default zoom), z11 tiles are upsampled by MapLibre. Roads and settlements
are visible and navigable; building outlines and POI icons become less precise.
Adequate for Phase 2 smoke testing and the user-location fix.

**Phase 4 target:** < 200 MB Germany-wide with a leaner Kfz-focused schema.

## Why Germany Instead of Berlin

Replaced `dev_berlin.pmtiles` (30 MB, Berlin bbox only) to fix empty-map issue when the
user's device is outside the Berlin extract bbox. The full-Germany extract renders
correctly regardless of where the user is located within Germany.

## How to Regenerate

1. Download the pmtiles CLI binary for your platform from [go-pmtiles releases](https://github.com/protomaps/go-pmtiles/releases)
2. Run `bash tool/fetch_pmtiles.sh` (or `pwsh tool/fetch_pmtiles.ps1`)
3. Verify magic bytes: first 7 bytes should equal ASCII `PMTiles`

## Source Layers (Protomaps v4 schema)

`earth`, `water`, `landcover`, `landuse`, `buildings`, `roads`, `transit`, `places`, `pois`, `boundaries`

## Attribution

Protomaps data © [Protomaps](https://protomaps.com) | Map data © [OpenStreetMap contributors](https://openstreetmap.org/copyright) (ODbL)
