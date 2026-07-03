# Dev Tile: dev_berlin.pmtiles

## What This File Is

A bundled PMTiles v3 vector tile archive covering the Berlin metropolitan area. Used for offline map rendering during development and CI. This is the tile source for `MapWidget` in debug builds.

## Source

- **Provider:** Protomaps demo planet (https://demo-bucket.protomaps.com/v4.pmtiles)
- **Schema:** Protomaps Version 4 (basemaps v4 flavors)
- **Download date:** 2026-07-03
- **Planet build date:** 2026-07-03 (latest stable planet from demo-bucket.protomaps.com)

## Extraction Command

```bash
# Requires pmtiles CLI v1.30.3+ (https://github.com/protomaps/go-pmtiles/releases)
pmtiles extract \
  https://demo-bucket.protomaps.com/v4.pmtiles \
  assets/tiles/dev_berlin.pmtiles \
  --bbox=13.088,52.338,13.761,52.677 \
  --maxzoom=14
```

- **Bounding box:** 13.088°E, 52.338°N to 13.761°E, 52.677°N (Berlin + ring)
- **Zoom range:** z0–z14 (regional overview through walking-detail zoom)
- **Tile count:** 1,175 tiles extracted

## Approximate Size + Zoom Range

| Property | Value |
|----------|-------|
| File size | ~29.4 MB |
| Zoom min | 0 |
| Zoom max | 14 |
| Coverage | Berlin city + immediate ring |

At z15 (app default zoom), z14 tiles are downsampled by MapLibre — detail is sufficient for street-level navigation. For higher precision add `--maxzoom=15` (roughly doubles size).

## How to Regenerate

1. Download the pmtiles CLI binary for your platform from [go-pmtiles releases](https://github.com/protomaps/go-pmtiles/releases)
2. Run the extraction command above (requires network access; uses HTTP range requests — only downloads the tile data needed)
3. Verify magic bytes: `python -c "open('assets/tiles/dev_berlin.pmtiles','rb').read(7)"` should print `b'PMTiles'`

## Source Layers (Protomaps v4 schema)

`earth`, `water`, `landcover`, `landuse`, `buildings`, `roads`, `transit`, `places`, `pois`, `boundaries`

## Attribution

Protomaps data © [Protomaps](https://protomaps.com) | Map data © [OpenStreetMap contributors](https://openstreetmap.org/copyright) (ODbL)

## Git Policy

This file **is committed to git** — at ~29.4 MB it is comfortably below the recommended 50 MB per-file limit for GitHub repos and enables fully offline CI runs without any external tile download step. If the file grows (higher maxzoom or larger bbox), consider moving it to Git LFS.
