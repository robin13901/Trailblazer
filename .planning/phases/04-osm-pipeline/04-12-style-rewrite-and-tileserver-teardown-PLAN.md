---
id: 04-12
phase: 04-osm-pipeline
plan: 12
type: execute
wave: 1
wave_ordering: serial-within-wave
wave_serial_order: 2  # runs after 04-11
depends_on: [04-11]
files_modified:
  - assets/map_style_light.json
  - assets/map_style_dark.json
  - lib/features/map/data/tile_server.dart
  - lib/features/map/data/tile_server_providers.dart
  - lib/features/map/presentation/providers/map_style_provider.dart
  - lib/features/map/presentation/widgets/map_widget.dart
  - lib/main.dart
  - pubspec.yaml
  - tool/fetch_pmtiles.sh
  - tool/fetch_pmtiles.ps1
  - assets/tiles/README.md
autonomous: false
requirements: [OSM-01, OSM-08]

must_haves:
  truths:
    - "The map screen renders MapTiler vector tiles seamlessly at zoom 0..22 on both light and dark theme."
    - "The loopback `TileServer` class, its providers, and its lifecycle hooks in main.dart are gone; `lib/features/map/data/tile_server.dart` no longer exists."
    - "`pubspec.yaml` no longer lists `pmtiles`, `shelf`, or `shelf_router`; the deletions land alphabetized (project rule)."
    - "`tool/fetch_pmtiles.sh` and `tool/fetch_pmtiles.ps1` no longer exist; `assets/tiles/README.md` is rewritten as MapTiler-provider notes."
    - "`assets/tiles/dev_germany.pmtiles` is not referenced from pubspec.yaml (the file itself is gitignored — leave on disk)."
    - "MapLibre's built-in attribution button is visible on-map (bottom-left), replacing the off-screen `Point(-9999, -9999)` hack."
    - "The `tool/osm_pipeline/` sub-package is UNTOUCHED — it remains as dev-only fixture-generation tooling for Phase 5."
  artifacts:
    - path: "assets/map_style_light.json"
      provides: "MapTiler-backed light style — either a thin wrapper pointing at the MapTiler style URL, or a full local copy of the MapTiler dataviz style with brand overrides."
    - path: "assets/map_style_dark.json"
      provides: "Same for dark."
    - path: "assets/tiles/README.md"
      provides: "Rewritten as: `Tile provider notes — MapTiler Cloud`. Explains --dart-define=MAPTILER_KEY and free-tier attribution requirements. Removes all references to fetch_pmtiles + dev_germany.pmtiles as an authoring pipeline."
  key_links:
    - from: "lib/features/map/presentation/widgets/map_widget.dart"
      to: "MapTiler style URL"
      via: "reads `mapStyleUrlProvider` and passes the URL directly as `styleString`; no local asset loading, no loopback HTTP"
      pattern: "styleString:"
    - from: "lib/features/map/presentation/widgets/map_widget.dart"
      to: "MapLibre built-in attribution button"
      via: "attributionButtonPosition set to bottom-left visible coordinates (NOT Point(-9999, -9999))"
      pattern: "attributionButtonPosition"
---

## Goal

Complete the MapTiler swap: point MapLibre at the MapTiler style URL, delete the loopback tile server + its deps + its dev-fetch scripts, restore visible attribution, and validate on a real device that Berlin + Kleinheubach both render seamlessly. `tool/osm_pipeline/` is explicitly OUT OF SCOPE for deletion — it stays as dev tooling for Phase 5.

## Context

- Research: `.planning/phases/04-osm-pipeline/04-RESEARCH.md` §1 (attribution requirements, MapTiler HTTP style URL, OpenMapTiles schema layer names).
- Wave 1's prior plan: `04-11-maptiler-provider-and-key-plumbing-PLAN.md` and its `04-11-STYLE-SPIKE.md` — read the spike doc for the confirmed style IDs before rewriting the JSON.
- Locked decision: MapTiler + OSM attribution + free-tier logo. Fastest path is MapLibre's built-in attribution button restored on-map at bottom-left. Custom-styled attribution chip is a later polish pass (deferred).
- Deletion inventory: `pmtiles`, `shelf`, `shelf_router` from `pubspec.yaml`; `lib/features/map/data/tile_server.dart`; `lib/features/map/data/tile_server_providers.dart`; `tool/fetch_pmtiles.sh`; `tool/fetch_pmtiles.ps1`.
- Existing off-screen attribution hack: `lib/features/map/presentation/widgets/map_widget.dart:184-187` sets `attributionButtonPosition: Point(-9999, -9999)`. Reverse this.
- **Wave-1 serial ordering:** 04-11 and 04-12 are BOTH `wave: 1` but MUST run serially. 04-12 depends on `mapStyleUrlProvider` created in 04-11. Execute in plan-number order: 04-11 first, then 04-12. The `wave_ordering: serial-within-wave` frontmatter annotation makes this explicit for the orchestrator.

## Tasks

<task type="auto">
  <name>Task 1: Point MapLibre at MapTiler style URL; delete loopback TileServer + deps + dev scripts</name>
  <files>
    lib/features/map/presentation/widgets/map_widget.dart
    lib/features/map/presentation/providers/map_style_provider.dart
    lib/features/map/data/tile_server.dart
    lib/features/map/data/tile_server_providers.dart
    lib/main.dart
    pubspec.yaml
    tool/fetch_pmtiles.sh
    tool/fetch_pmtiles.ps1
    assets/tiles/README.md
  </files>
  <intent>Swap the map to remote MapTiler tiles; excise the loopback shim.</intent>
  <action>
    **`lib/features/map/presentation/widgets/map_widget.dart`:**
    - Replace `styleString: <asset-path-or-loopback-url>` with `styleString: ref.watch(mapStyleUrlProvider)` (from 04-11).
    - Remove `attributionButtonPosition: Point(-9999, -9999)`. Set to `attributionButtonPosition: AttributionButtonPosition.bottomLeft` (or whichever enum value maplibre_gl exposes for on-screen bottom-left).
    - Remove any lifecycle hooks that started/stopped `TileServer` (e.g. `initState` calls to `tileServerProvider.start()` or `dispose` teardown).

    **`lib/features/map/presentation/providers/map_style_provider.dart`:**
    - Delete any provider still returning a bundled asset path.
    - `mapStyleUrlProvider` (created in 04-11) is the only surviving style provider. Confirm it reads `TileProviderConfig` and returns the MapTiler URL for the active brightness.

    **`lib/main.dart`:**
    - Delete any startup code that instantiates/starts `TileServer`. Delete any imports referring to `tile_server.dart` / `tile_server_providers.dart`.

    **Delete files (git rm):**
    ```bash
    git rm lib/features/map/data/tile_server.dart
    git rm lib/features/map/data/tile_server_providers.dart
    git rm tool/fetch_pmtiles.sh
    git rm tool/fetch_pmtiles.ps1
    ```

    **`pubspec.yaml`:**
    - Remove three deps: `pmtiles`, `shelf`, `shelf_router`.
    - Ensure remaining deps are still alphabetized (project rule `sort_pub_dependencies`).
    - Remove any `assets/tiles/dev_germany.pmtiles` entry from `assets:` section (the file itself is gitignored — do not `git rm` it).
    - `flutter pub get` after the edit.

    **`assets/tiles/README.md`:**
    - Rewrite as MapTiler provider notes. Include:
      - Tile provider: MapTiler Cloud (free tier: 100k requests/month, 5k map sessions/month).
      - API key delivery: `--dart-define=MAPTILER_KEY=…` or `--dart-define-from-file=env/dev.json`.
      - Attribution: MapTiler + OSM (see Settings > About).
      - Old `dev_germany.pmtiles` workflow is deprecated; `tool/osm_pipeline/` stays as fixture-generator for Phase 5 golden-corpus tests, not as an authoring pipeline for the app map.

    **DO NOT TOUCH:** `tool/osm_pipeline/` — that entire sub-package stays as dev tooling. Grepping `pmtiles` there will find hits inside the pipeline — LEAVE THEM.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test
    ! test -f lib/features/map/data/tile_server.dart
    ! test -f lib/features/map/data/tile_server_providers.dart
    ! test -f tool/fetch_pmtiles.sh
    ! test -f tool/fetch_pmtiles.ps1
    ! grep -E '^\s*(pmtiles|shelf|shelf_router):' pubspec.yaml
    test -d tool/osm_pipeline    # STILL exists
    grep -q "MapTiler" assets/tiles/README.md
    ```
    Analyze clean; tests green; deletions confirmed; `tool/osm_pipeline` untouched.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Rewrite style JSONs (or delegate to MapTiler remote style) + tune HTTP cache</name>
  <files>
    assets/map_style_light.json
    assets/map_style_dark.json
    lib/features/map/presentation/widgets/map_widget.dart
  </files>
  <intent>Either point at MapTiler's remote style URL directly (simplest) or ship a light brand-override style layered on top.</intent>
  <action>
    **Recommended approach (simplest — RESEARCH §1 endorses this):**
    - Do NOT ship a hand-rewritten style JSON. Instead: `mapStyleUrlProvider` (from 04-11) already returns the MapTiler-hosted style URL. MapLibre resolves everything (sources, sprites, glyphs) from that URL. `assets/map_style_light.json` and `assets/map_style_dark.json` become empty/stub files or are deleted entirely.

    **Decision:** delete both `assets/map_style_light.json` and `assets/map_style_dark.json` from disk (they were tuned for the abandoned custom Trailblazer schema and are obsolete). Remove their entries from `pubspec.yaml`'s `assets:` section. Update `assets/tiles/README.md` to reflect that styles are now served remotely.

    **MapLibre HTTP cache tuning:**
    - In `map_widget.dart`, after MapLibre initialization, set the HTTP tile cache size to something generous for offline grace. MapLibre GL Native exposes this via `mapController.setHttpCacheSize(200 * 1024 * 1024)` (~200 MB) — check the exact API in `maplibre_gl` docs (grep the installed package).
    - If the API isn't exposed via `maplibre_gl` at this version, log a `TODO(04-12): expose HTTP cache size tuning when maplibre_gl surfaces it` and move on. Do NOT introduce a fork.

    **DO NOT rewrite `assets/map_style_*.json` from scratch.** The MapTiler-hosted style is a complete, MapLibre-compliant style — reinventing it is a waste. If we later want brand overrides (custom colors on the roads layer), do that via a small style-transform provider in a future polish pass.

    **Brand override note (deferred):** Trailblazer's future coverage overlay (Phase 7) adds a `driven_ways` source layer on top of the base style. That's Phase 7's concern; Phase 4 doesn't need any brand tweaks yet.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test
    ! test -f assets/map_style_light.json
    ! test -f assets/map_style_dark.json
    grep -E 'map_style_(light|dark)\.json' pubspec.yaml && exit 1 || echo "clean"
    ```
    Analyze clean; tests green; obsolete style JSONs gone from disk AND pubspec.
  </verify>
</task>

<task type="checkpoint:human-action">
  <name>Task 3: Real-device MapTiler smoke test — Berlin + Kleinheubach + Liquid Glass composition</name>
  <files></files>
  <what-built>
    Wave 1 delivers: MapTiler key wired, TileProviderConfig model, loopback TileServer + pmtiles/shelf/shelf_router deps deleted, MapLibre reading remote MapTiler style URL, on-screen attribution restored, Settings > About with clickable MapTiler + OSM links.
  </what-built>
  <how-to-verify>
    1. Build for Android device:
       ```bash
       flutter run --release --dart-define-from-file=env/dev.json
       ```
    2. Grant location permission.
    3. Pan/zoom to **Berlin (52.52, 13.405)** — verify at zoom 8, 12, 16, 18 the map renders seamlessly. No blank tiles, no gray placeholders. Light theme.
    4. Switch device to dark mode — verify dark style loads. Attribution still visible.
    5. Switch back to light. Pan/zoom to **Kleinheubach (49.79, 9.19)** at zoom 12, 15, 18. Rural + village + river both render.
    6. Verify Settings > About shows "© MapTiler © OpenStreetMap contributors" — tap each link — confirms external browser opens on the copyright pages.
    7. Verify the Liquid Glass FAB is still visible + tappable while the map is animating in — no black square, no `Picture.toImageSync` crash (see RESEARCH §9 risk #3). If a Liquid Glass regression appears, capture the stack trace before signing off.
    8. Airplane mode: fresh cold-cache map should show gray tiles (no offline base yet — this is EXPECTED for Wave 1; the "offline grace" is only the HTTP cache from prior sessions). Confirm the app does not crash on network failure — a diagnostic banner or empty map is acceptable.
    9. If MAPTILER_KEY was NOT set at build time, the `AppLogger.warn` line should appear in `flutter logs` OR a diagnostic banner appears; the app should still boot.

    **Approve on success. If any step fails, capture screenshots + logs and return with issue details for a follow-up.**
  </how-to-verify>
  <resume-signal>Type "approved" or describe issues seen on device.</resume-signal>
</task>

## Success Criteria (Wave 1 close-out)

- MapTiler tiles render seamlessly across zoom 0..22 in both light and dark themes on a real Android device (iOS smoke deferred to Phase 11's device gauntlet).
- Loopback `TileServer` + `pmtiles`/`shelf`/`shelf_router` deps + `tool/fetch_pmtiles.*` scripts are excised.
- `assets/tiles/README.md` documents the new MapTiler-provider workflow.
- Attribution visible on-map (MapLibre built-in button, bottom-left).
- Settings > About shows clickable MapTiler + OSM attribution.
- `tool/osm_pipeline/` is UNTOUCHED (grep-verify).
- `flutter analyze` clean; `flutter test` green.

## Ralph Loop

- Tight loop: `flutter analyze`
- Behavior-sensitive: `flutter test` after Task 1 (map_widget rewiring can break widget tests) and Task 2 (style-provider changes).
- Real-device smoke IS in this plan (Task 3) — not deferred.

## Deviations

- If the MapLibre HTTP cache tuning API isn't exposed at the installed `maplibre_gl` version, drop the tuning quietly with a TODO. Not a blocker.
- If MapTiler's remote-hosted style refuses to load on-device (CORS or auth quirk), fall back to embedding a minimal MapLibre style that references MapTiler tile URLs directly (source: `{"type":"vector","url":"https://api.maptiler.com/tiles/v3/tiles.json?key=..."}` + hand-written layer array using OpenMapTiles schema layer names — see RESEARCH §1). Document the fallback in the plan's SUMMARY.
- If the real-device smoke reveals a Liquid Glass regression, DO NOT commit the wave. Isolate the issue in a follow-up gap-closure plan.

## Commit Strategy

- Task 1 commit: `feat(04-12): swap MapLibre to MapTiler remote style + delete loopback TileServer`
- Task 2 commit: `chore(04-12): delete obsolete Trailblazer-schema style JSONs`
- Task 3 (checkpoint): no commit — approval gate only.
- Post-approval close-out commit: `docs(04-12): Wave 1 MapTiler swap verified on device`
