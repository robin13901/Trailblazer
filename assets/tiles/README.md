# Tile provider notes — MapTiler Cloud

## Runtime tile source

Trailblazer's basemap is served by **MapTiler Cloud** (https://cloud.maptiler.com).
No PMTiles archive is bundled with the app. MapLibre fetches vector tiles + styles
directly from the MapTiler-hosted style URL at runtime.

- **Provider:** MapTiler Cloud (free tier: 100k tile requests / month, 5k map sessions / month).
- **Default styles:** `dataviz` (light) and `dataviz-dark` (dark) — see
  `.planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md` for the spike results
  and fallback (`streets-v2` / `streets-v2-dark`) if MapTiler ever gates dataviz on
  a fresh account.
- **Selection lives in Dart:** `TileProviderConfig` (`lib/features/map/data/tile_provider_config.dart`)
  owns the enum + URL formatter. The Riverpod plumbing (`tileProviderConfigProvider`
  + `mapStyleUrlProvider`) is in `lib/features/map/presentation/providers/map_style_provider.dart`.

## API key delivery

The MapTiler API key is injected at build/run time via one of:

```
flutter run --dart-define=MAPTILER_KEY=<your-key>
flutter run --dart-define-from-file=env/dev.json
```

`env/dev.json.example` documents the JSON shape; the real `env/dev.json` is
gitignored (see `.gitignore`). Never check the key in.

CI reads the key from a GitHub Actions secret (`MAPTILER_KEY`) and forwards
it as `--dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }}` in both
`.github/workflows/ci.yml` and `.github/workflows/ios-build.yml`.

Empty-key path: fork PRs without secret access boot with a warning log line
(`MAPTILER_KEY not set — map will render blank tiles`) and the map renders blank
tiles. The diagnostics HUD surfaces the resulting HTTP 401 chain.

## Attribution

Free-tier MapTiler + OSM licensing requires both credits to be reachable from
the map view:

- **On-map:** MapLibre's built-in attribution button (bottom-left) opens the
  MapTiler + OSM copyright popup.
- **In-app:** `Settings > About` surfaces clickable full-attribution links —
  see `lib/features/settings/presentation/widgets/about_section.dart`.

## Legacy PMTiles workflow (deprecated 2026-07-08)

Prior Wave-7 setup bundled a `dev_germany.pmtiles` archive served by a loopback
`TileServer` (Dart shelf + pmtiles). Plan 04-12 removed:

- `lib/features/map/data/tile_server.dart` + its providers
- `tool/fetch_pmtiles.sh` / `tool/fetch_pmtiles.ps1`
- `pmtiles` / `shelf` / `shelf_router` dependencies from `pubspec.yaml`
- `assets/map_style_light.json` / `assets/map_style_dark.json` (obsolete
  custom-schema styles — MapTiler serves the style JSON now)

`assets/tiles/dev_germany.pmtiles` and `assets/tiles/dev_berlin.pmtiles`
remain on disk but are gitignored and no longer referenced by the app.
They may be deleted locally without impact.

## Phase 5+ role of `tool/osm_pipeline/`

The Phase 4 OSM pipeline (`tool/osm_pipeline/`) stays intact as dev tooling —
it generates the `osm.sqlite` fixtures used by Phase 5's HMM matcher golden
corpus. It is **not** an authoring pipeline for the runtime basemap anymore.
Do not delete `tool/osm_pipeline/` when cleaning up the legacy PMTiles workflow.
