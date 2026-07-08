---
phase: 04-osm-pipeline
plan: 12
subsystem: map
tags: [maptiler, maplibre, tile-server, pmtiles, style-rewrite, attribution, teardown]

# Dependency graph
requires:
  - phase: 04-osm-pipeline (Plan 04-11)
    provides: mapStyleUrlProvider Notifier + tileProviderConfigProvider + MAPTILER_KEY delivery + Settings About attribution
  - phase: 02-map-glass-shell
    provides: MapWidget style-fade seam + brightness-observer contract + MapScreen chrome layout
provides:
  - MapLibre reads the MapTiler-hosted style URL directly (styleString: mapStyleUrlProvider); no local asset load, no loopback HTTP
  - Native MapLibre attribution button restored on-map (bottom-left, native default margins) — the Point(-9999,-9999) hack from Phase-2 Wave-7 is gone
  - Loopback TileServer + pmtiles/shelf/shelf_router deps + fetch_pmtiles.{sh,ps1} + FakeTileServer test helper deleted
  - assets/map_style_light.json + assets/map_style_dark.json (obsolete custom-Trailblazer-schema style JSONs) deleted from disk and pubspec
  - assets/tiles/README.md rewritten as MapTiler provider notes (attribution, key delivery, deprecation of local pmtiles pipeline)
  - Root pubspec.yaml gained a `dependency_overrides: sqlite3: ^3.0.0` block to unblock `flutter pub get` after removing pmtiles/shelf transitively (surfaced pre-existing drift_flutter vs tool/osm_pipeline constraint conflict)
  - Wave 1 of Phase 4 rescope closed with on-device verification (Samsung Galaxy S24, Android 14, Berlin + Kleinheubach + dark-mode swap + Settings About links)
affects:
  - 04-13-overpass-client-and-payload-probe (Wave 2 starts here; MapTiler-only runtime is the stable base)
  - 04-14-drift-migration-v3-and-daos (schema v3 rides on the app-level sqlite3 3.x now-forced by the override)
  - 04-15-way-candidate-source-and-trip-flow (WayCandidateSource abstraction plugs on top of the MapTiler+Overpass runtime)
  - 04-16-bundled-admin-polygons-and-lookup
  - 04-17-rescope-close-out (owns REQUIREMENTS/ROADMAP rewrite + SC4 supersede for the abandoned bundled-osm.sqlite architecture)
  - Phase 5+ (MapTiler tiles are the sole runtime tile source going forward)

# Tech tracking
tech-stack:
  removed:
    - pmtiles ^2.2.0 (dep + runtime)
    - shelf ^1.4.2 (dep + runtime)
    - shelf_router ^1.1.4 (dep + runtime)
  overrides-added:
    - sqlite3 ^3.0.0 (root pubspec dependency_overrides — see Deviations)
  patterns:
    - "styleString: mapStyleUrlProvider (remote-URL-only; no local asset load path)"
    - "attributionButtonPosition: AttributionButtonPosition.bottomLeft (native default margins)"
    - "Delete-not-neuter: remove obsolete files entirely rather than leave dead stubs"

key-files:
  created: []
  deleted:
    - C:\SAPDevelop\Privat\Trailblazer\assets\map_style_light.json
    - C:\SAPDevelop\Privat\Trailblazer\assets\map_style_dark.json
    - C:\SAPDevelop\Privat\Trailblazer\lib\features\map\data\tile_server.dart
    - C:\SAPDevelop\Privat\Trailblazer\lib\features\map\data\tile_server_providers.dart
    - C:\SAPDevelop\Privat\Trailblazer\tool\fetch_pmtiles.sh
    - C:\SAPDevelop\Privat\Trailblazer\tool\fetch_pmtiles.ps1
    - C:\SAPDevelop\Privat\Trailblazer\test\helpers\fake_tile_server.dart
    - C:\SAPDevelop\Privat\Trailblazer\test\assets\map_styles_test.dart
  modified:
    - C:\SAPDevelop\Privat\Trailblazer\lib\features\map\presentation\widgets\map_widget.dart
    - C:\SAPDevelop\Privat\Trailblazer\lib\features\map\presentation\providers\map_style_provider.dart
    - C:\SAPDevelop\Privat\Trailblazer\lib\main.dart
    - C:\SAPDevelop\Privat\Trailblazer\pubspec.yaml
    - C:\SAPDevelop\Privat\Trailblazer\pubspec.lock
    - C:\SAPDevelop\Privat\Trailblazer\assets\tiles\README.md
    - C:\SAPDevelop\Privat\Trailblazer\test\features\map\glass_shell_layout_test.dart

key-decisions:
  - "MapTiler-hosted style URL is the sole map source — no local style JSON, no local pmtiles, no loopback HTTP shim"
  - "Attribution button restored on-map (bottom-left, native default margins). Point(-9999,-9999) push hack from Phase-2 Wave-7 deleted"
  - "Loopback TileServer stack (tile_server.dart + tile_server_providers.dart + FakeTileServer helper + fetch_pmtiles scripts) deleted wholesale; tool/osm_pipeline/ UNTOUCHED (stays as Phase-5 fixture generator)"
  - "Custom-Trailblazer-schema style JSONs (map_style_light/dark.json) obsolete after MapTiler swap — deleted from disk AND pubspec assets: section"
  - "HTTP tile-cache tuning parked as TODO(04-12) — maplibre_gl 0.26.2 does not expose setHttpCacheSize on the Dart controller; do NOT fork"
  - "sqlite3 ^3.0.0 dependency_override added to root pubspec.yaml — force-resolves drift_flutter (wants 3.x) vs tool/osm_pipeline (pins ^2.4.0); sub-package unaffected when invoked standalone"
  - "assets/tiles/dev_germany.pmtiles remains orphan on disk (gitignored, 371 MB) — no longer referenced by any code path; cleanup optional"

patterns-established:
  - "Pattern: styleString reads Notifier<String> directly (remote-URL provider), MapLibre resolves sources/sprites/glyphs from the URL — no client-side style JSON hosting"
  - "Pattern: TODO(<plan-id>) inline marker for parked upstream-API-gap improvements (e.g. HTTP cache tuning) — grep-locatable when the upstream API lands"

# Metrics
duration: ~55min (execution + on-device verify + orchestrator sqlite3 fix)
completed: 2026-07-08
---

# Phase 4 Plan 12: Style Rewrite and TileServer Teardown Summary

**MapLibre swapped to read the MapTiler-hosted style URL directly; loopback TileServer + pmtiles/shelf/shelf_router deps + fetch scripts + obsolete Trailblazer-schema style JSONs excised; native attribution restored on-map; verified end-to-end on Samsung Galaxy S24 Android 14 across Berlin, Kleinheubach, and dark-mode brightness swap.**

## Performance

- **Duration:** ~55 min (task execution + on-device verify + orchestrator sqlite3 unblock)
- **Started:** 2026-07-08T09:35Z (approx, Task 1)
- **Completed:** 2026-07-08T (approved on-device)
- **Tasks:** 3 (2× auto + 1× checkpoint:human-action)
- **Files created:** 0
- **Files deleted:** 8
- **Files modified:** 7
- **Wave 1 close:** on-device verified, Phase 4 Wave 1 sealed

## Accomplishments

- **MapLibre → MapTiler wiring:** `map_widget.dart` now passes `ref.watch(mapStyleUrlProvider)` straight to `MapLibreMap.styleString`. MapLibre resolves sources, sprites, and glyphs from the MapTiler-hosted style URL. No client-side JSON, no asset load, no loopback HTTP.
- **Attribution restored on-map:** `attributionButtonPosition: AttributionButtonPosition.bottomLeft` (native default margins). The `Point(-9999, -9999)` off-screen push from Phase-2 Wave-7 is gone. Free-tier MapTiler + OSM attribution now shows on-map AND in Settings > About (04-11's belt-and-braces).
- **Loopback stack excised:**
  - `lib/features/map/data/tile_server.dart` + `tile_server_providers.dart` deleted
  - `pmtiles ^2.2.0`, `shelf ^1.4.2`, `shelf_router ^1.1.4` removed from `pubspec.yaml`
  - `tool/fetch_pmtiles.sh` + `tool/fetch_pmtiles.ps1` deleted
  - `test/helpers/fake_tile_server.dart` deleted
  - 5 test files rewired to override `tileProviderConfigProvider` + `mapStyleUrlProvider` instead of the deleted `tileServerProvider` + `mapStyleAssetProvider`
- **Obsolete style JSONs deleted:** `assets/map_style_light.json` (429 lines) + `assets/map_style_dark.json` (429 lines) — both tuned for the abandoned custom Trailblazer 4-layer tippecanoe schema. Removed from disk AND `pubspec.yaml`'s `assets:` section. `test/assets/map_styles_test.dart` deleted alongside (its 4 assertions all guarded the now-deleted files).
- **`assets/tiles/README.md` rewritten as MapTiler provider notes:** documents free-tier limits (100k requests/month), `--dart-define-from-file=env/dev.json` delivery, MapTiler + OSM attribution requirements, and the standing role of `tool/osm_pipeline/` as Phase-5 fixture generator (not an authoring pipeline for the app map).
- **`tool/osm_pipeline/` UNTOUCHED:** grep-verified; sub-package remains dev-only Phase-5 golden-corpus tooling per the rescope decision (`memory: phase-4-rescope-decisions-2026-07-08`).
- **On-device verified on Samsung Galaxy S24 (Android 14):** Berlin (52.52, 13.405) at zoom 8/12/16/18 seamless, Kleinheubach (49.79, 9.19) at zoom 12/15/18 seamless, dark-mode swap loads dark style with attribution still visible, Settings > About tap on MapTiler + OSM rows launches external browser, Liquid Glass FAB unaffected during map animate-in (no Picture.toImageSync crash — RESEARCH §9 risk #3 not triggered).

## Task Commits

Each task committed atomically per project CLAUDE.md rules:

1. **Task 1: Point MapLibre at MapTiler style URL; delete loopback TileServer + deps + dev scripts** — `3991ed5` (feat)
2. **Task 2: Delete obsolete Trailblazer-schema style JSONs** — `9f9aa89` (chore)
3. **Task 3: Real-device MapTiler smoke test — Berlin + Kleinheubach + Liquid Glass composition** — checkpoint:human-action; on-device APPROVED 2026-07-08 (Samsung Galaxy S24, Android 14)

**Orchestrator sub-fix (during Task 3 build):** `e715d50` (fix) — added `dependency_overrides: sqlite3: ^3.0.0` block to root `pubspec.yaml` to unblock `flutter pub get` after `pmtiles`/`shelf`/`shelf_router` were removed in Task 1 (surfaced a pre-existing sqlite3 constraint conflict — see Deviations).

Plan metadata commit follows this SUMMARY: `docs(04-12): Wave 1 MapTiler swap verified on device`.

## Files Created/Modified

**Deleted (8):**
- `assets/map_style_light.json` — obsolete custom-Trailblazer-schema style
- `assets/map_style_dark.json` — obsolete custom-Trailblazer-schema style
- `lib/features/map/data/tile_server.dart` — loopback shelf server
- `lib/features/map/data/tile_server_providers.dart` — Riverpod plumbing for TileServer
- `tool/fetch_pmtiles.sh` — dev PMTiles fetch script (macOS/Linux)
- `tool/fetch_pmtiles.ps1` — dev PMTiles fetch script (Windows)
- `test/helpers/fake_tile_server.dart` — test double for the loopback server
- `test/assets/map_styles_test.dart` — 4 assertions guarding the now-deleted style JSONs

**Modified (7):**
- `lib/features/map/presentation/widgets/map_widget.dart` — `styleString: ref.watch(mapStyleUrlProvider)`; attribution restored bottom-left; TileServer lifecycle hooks removed; TODO(04-12) HTTP cache marker parked
- `lib/features/map/presentation/providers/map_style_provider.dart` — legacy `mapStyleAssetProvider` + `MapStyleAssetNotifier` + `assetForBrightness` helper deleted; only `mapStyleUrlProvider` survives
- `lib/main.dart` — removed any TileServer startup/lifecycle hooks (04-11 kept those; verified absent post-Task-1)
- `pubspec.yaml` — 3 deps removed (`pmtiles`, `shelf`, `shelf_router`) + 2 asset entries removed (`map_style_light.json`, `map_style_dark.json`) + `dependency_overrides: sqlite3: ^3.0.0` block added
- `pubspec.lock` — regenerated after resolution
- `assets/tiles/README.md` — rewritten as MapTiler provider notes
- `test/features/map/glass_shell_layout_test.dart` — updated provider overrides (one of 5 rewired test files, called out here as representative — see commit `3991ed5` diff for full list)

**Orphan on disk (gitignored, not deleted):**
- `assets/tiles/dev_germany.pmtiles` (371 MB) — no longer referenced by any code path; cleanup optional. `tool/fetch_pmtiles.*` scripts that populated it are gone.
- `assets/tiles/dev_berlin.pmtiles` (30 MB) — same status.

## Decisions Made

- **MapTiler-hosted style URL is the sole map source.** Alternative considered: ship a slim local style JSON that references MapTiler tile URLs directly (fallback per plan §Deviations). Rejected because MapTiler's hosted style is a complete, MapLibre-compliant style — reinventing it is a waste; brand overrides are Phase-7 territory (feature-state coverage overlay).
- **Attribution button restored to native bottom-left.** Alternative considered: keep the off-screen push and rely solely on Settings > About. Rejected — MapTiler free-tier TOS + ODbL require attribution to be VISIBLE on the map surface itself.
- **HTTP cache tuning dropped, not forked.** `maplibre_gl 0.26.2` does not expose `setHttpCacheSize` on the Dart controller (grep-verified against installed package). Per plan §Deviations, dropped quietly with a `TODO(04-12)` marker in `map_widget.dart`. OS-level tile cache is the only offline grace mechanism for Wave 1.
- **`assets/tiles/dev_germany.pmtiles` left as orphan on disk.** File is gitignored + no runtime reference. Deleting it is a 371 MB reclaim but affects only the developer's local disk; not blocking any code path.
- **`tool/osm_pipeline/` sub-package fully preserved.** Per rescope decision (`memory: phase-4-rescope-decisions-2026-07-08`), it stays as Phase-5 fixture generator. Grep-verified untouched; even the `pmtiles`/`sqlite3` hits inside the sub-package are left alone.
- **`sqlite3 ^3.0.0` dependency_override applied at root pubspec** (see Deviations for full analysis).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `flutter pub get` failed with sqlite3 constraint conflict during Task 3 on-device build**

- **Found during:** Task 3 (on-device smoke test build)
- **Issue:** With `pmtiles`, `shelf`, and `shelf_router` removed in Task 1, `flutter pub get` surfaced a pre-existing constraint conflict:
  - `drift_flutter ^0.3.0` (root pubspec, app-side) wants `sqlite3 ^3.0.0`
  - `tool/osm_pipeline` (path-imported dev dependency) pins `sqlite3 ^2.4.0` for Dart 3.5 SDK compat (04-03 decision)
  - Pre-04-12, `pmtiles ^2.2.0` transitively held sqlite3 3.x together via its own resolution — removing `pmtiles` exposed the underlying conflict
- **Fix:** Orchestrator added a `dependency_overrides:` block to root `pubspec.yaml`:
  ```yaml
  dependency_overrides:
    sqlite3: ^3.0.0
  ```
  This force-resolves the app-level resolution to sqlite3 3.x. The sub-package's own lockfile is unaffected when invoked standalone via `cd tool/osm_pipeline && dart run bin/osm_pipeline.dart`.
- **Files modified:** `pubspec.yaml`, `pubspec.lock`
- **Verification:** `flutter analyze` clean, `flutter test` 179/179 green, on-device build succeeds, on-device app boots and renders MapTiler tiles as expected.
- **Committed in:** `e715d50` (standalone fix commit, not part of any task commit)
- **Follow-up (Pending Todos):** Bump `tool/osm_pipeline/pubspec.yaml` sqlite3 pin from `^2.4.0` to `^3.0.0` and remove the root-pubspec override. Requires re-running the full sub-package test suite (233+ tests across the pipeline) — out of Wave-1 scope; do this before Phase 5 starts.

### Non-blocking watch-items (not auto-fixes; documented for future drives)

**2. Attribution button margins set to native default, not a positive `Point(x, y)`**

- **Decision:** Used `AttributionButtonPosition.bottomLeft` with the maplibre_gl default margin (no `attributionButtonMargins:` override).
- **Watch-item:** On subsequent drives, if the attribution button gets squashed under the bottom-nav pill or crowded by the recenter button, follow the Phase-2 Wave-7 pattern (STATE 2026-07-04) and add `attributionButtonMargins: const Point(8, 96)` in `map_widget.dart`.
- **Filed as:** Pending todo (see STATE.md).

**3. HTTP tile-cache tuning dropped (upstream API gap)**

- **Cause:** `maplibre_gl 0.26.2` Dart controller does not expose `setHttpCacheSize`.
- **Action:** Parked as `TODO(04-12): expose HTTP cache size tuning when maplibre_gl surfaces it` in `map_widget.dart`. OS-level tile cache is the sole offline grace mechanism for Wave 1.
- **Filed as:** Pending todo (see STATE.md).

---

**Total deviations:** 1 auto-fix (Rule 3 - Blocking) + 2 non-blocking watch-items.
**Impact on plan:** All items handled without derailing the wave. Plan executed as written; the sqlite3 override is a scoped unblock, not a scope change.

## Issues Encountered

- **`flutter pub get` sqlite3 conflict** (see Deviations #1) — resolved by orchestrator via `dependency_overrides`.
- **5 test files needed provider-override rewiring** — expected mechanical churn following the provider deletions in Task 1; landed alongside the Task 1 commit (`3991ed5`) so verification runs green in a single revert-unit if needed.

## Success Criteria (Wave 1 close-out)

| # | Criterion | Status |
|---|---|---|
| 1 | MapTiler tiles render seamlessly across zoom 0..22 in both light and dark themes on a real Android device | PASS (Samsung Galaxy S24, Android 14, 2026-07-08) |
| 2 | Loopback `TileServer` + `pmtiles`/`shelf`/`shelf_router` deps + `tool/fetch_pmtiles.*` scripts excised | PASS |
| 3 | `assets/tiles/README.md` documents the new MapTiler-provider workflow | PASS |
| 4 | Attribution visible on-map (MapLibre built-in button, bottom-left) | PASS (on-device verified) |
| 5 | Settings > About shows clickable MapTiler + OSM attribution | PASS (on-device: browser opens on copyright pages) |
| 6 | `tool/osm_pipeline/` is UNTOUCHED (grep-verified) | PASS |
| 7 | `flutter analyze` clean; `flutter test` green | PASS (179/179 tests green, analyze clean) |
| 8 | iOS smoke | DEFERRED — Phase 11 device gauntlet per plan text |

## User Setup Required

None new relative to 04-11. `MAPTILER_KEY` must still be present (via `env/dev.json` locally or GitHub Actions secret in CI). Empty-key path continues to warn + boot (04-11 decision preserved).

## Next Phase Readiness

**Wave 1 of Phase 4 rescope: CLOSED.** Ready for Wave 2 (04-13 → 04-14 → 04-15 serial-within-wave):

- MapTiler-only runtime is the stable base — no local pmtiles, no loopback shim, no local style JSON.
- `mapStyleUrlProvider` is the sole style seam; `tileProviderConfigProvider` is overridable in tests.
- App-level sqlite3 3.x is now the resolved constraint (via override) — Wave 2's Drift migration v3 (04-14) rides on this without further pubspec churn.
- `tool/osm_pipeline/` remains available for Phase-5 golden-corpus generation, decoupled from the app runtime.

**No blockers for Wave 2.** Grep tripwires:
- `TileServer` — 0 hits in `lib/`
- `pmtiles` — 0 hits in `lib/` and root `pubspec.yaml` `dependencies:` section (still present in `tool/osm_pipeline/` — expected)
- `shelf` — 0 hits in root `pubspec.yaml` `dependencies:` section
- `Point(-9999` — 0 hits in `lib/`
- `mapStyleAssetProvider` — 0 hits in `lib/` and `test/`
- `tool/osm_pipeline/` — directory present and untouched

**Superseded items (handled by 04-17 rescope close-out, not this plan):**
- ROADMAP SC4 (200 MB → 800 MB bundled-osm.sqlite target) — 04-17 owns the full REQUIREMENTS/ROADMAP rewrite for the abandoned bundled-osm.sqlite architecture.

---
*Phase: 04-osm-pipeline*
*Completed: 2026-07-08*
