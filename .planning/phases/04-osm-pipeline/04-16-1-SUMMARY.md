---
id: 04-16-1
phase: 04-osm-pipeline
plan: 16-1
subsystem: map-ui
tags: [ux, map, maptiler, fgb, layout, localization]
wave: 4a
autonomous: true
status: code-complete-drive-deferred
requires: [04-11, 04-12, 04-16]
provides:
  - fgb-toast-suppression
  - off-screen-attribution-restore
  - default-zoom-15
  - de-localized-map-labels
  - symmetric-top-chrome-inset
affects: [04-17]
tech-stack:
  added: []
  patterns:
    - "Injectable language field on immutable config: string-based ISO-639-1 code threaded through MapTiler style URL as &language=<code>"
    - "Symmetric chrome inset constant pair (_chromeRowTopInset / _navRowBottomInset) mirroring bottom-chrome offset from top-chrome"
key-files:
  created: []
  modified:
    - lib/features/trips/data/fgb_background_geolocation_facade.dart
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/domain/camera_state.dart
    - lib/features/map/presentation/map_screen.dart
    - lib/features/map/data/tile_provider_config.dart
    - lib/features/map/presentation/providers/map_style_provider.dart
    - lib/main.dart
    - test/features/map/tile_provider_config_test.dart
    - test/features/map/map_widget_test.dart
    - test/features/map/camera_state_test.dart
    - test/features/map/map_style_provider_test.dart
decisions:
  - "FGB toast suppression via bg.Config.reset: true — drops persisted config on cold start (Option A; Option B AndroidManifest meta-data left as fallback if drive shows toast persists)"
  - "Attribution off-screen via Point(-9999, -9999) restored — reverts 04-12 Task 1 per user UX feedback 2026-07-08"
  - "Default zoom 15 across CameraState.initial + MapWidget.initialZoom (was 16 + 11 respectively — divergent pre-04-16-1; now unified)"
  - "MapTiler style URL localized via `?key=<key>&language=<code>` (default 'de'); resolveMapLanguage(Platform.localeName) chooses from 14-code kMapTilerSupportedLanguages set, falls back to 'de' when unsupported"
  - "Top-chrome inset _chromeRowTopInset = 12 mirrors _navRowBottomInset = 12 — symmetric chrome distances from safe-area top/bottom"
metrics:
  duration: 15 min
  completed: 2026-07-08
  test-delta: 263 → 266 (net +3)
---

# Phase 4 Plan 16-1: UX Polish Summary

**One-liner:** Five user-observed UI fixes folded into Phase 4 rescope pre-close-out — FGB toast suppression via `reset: true`, on-map attribution icon pushed off-screen (reverts 04-12), default zoom 15, MapTiler labels in German, top-chrome inset mirrors bottom-chrome (12 dp).

## Status

**Code-complete (drive-verify deferred to combined Phase 4 close-out drive)** — mirrors 04-15 / 04-16 pattern. On-device visual confirmation of Task 1 (no toast on cold start) and Task 5 (top chrome no longer offset from status bar) batched to the Kleinheubach-adapted combined drive per user directive 2026-07-08 (memory: `phase-4-drives-deferred-to-gym-trip.md`).

## Task Table

| # | Name | Commit | Files changed | What changed |
|---|------|--------|---------------|--------------|
| 1 | Suppress FGB license toast | `bbcbb0d` | fgb_background_geolocation_facade.dart | Added `reset: true` to `bg.Config` in `ready()`. FGB re-applies the full config every cold start anyway; dropping the persisted copy suppresses the "LICENSE VALIDATION FAILURE" toast without changing tracking behavior. Verified against FGB 5.3.0 `Config` field (config.dart:552). |
| 2 | Off-screen attribution icon | `8444308` | map_widget.dart, map_widget_test.dart | Restored `attributionButtonMargins: const Point(-9999, -9999)` (kept `attributionButtonPosition: bottomLeft`). Added `dart:math` import. Widget test asserts the `Point(-9999, -9999)` margins are wired through to `MapLibreMap`. |
| 3 | Default zoom 11 → 15 | `3b6d04b` | camera_state.dart, map_widget.dart, camera_state_test.dart, map_widget_test.dart | `CameraState.initial.zoom = 15` (was 16) + `MapWidget.initialZoom = 15` (was 11). Both defaults unified. `spike_g1_screen.dart` (zoom 12) intentionally untouched. |
| 4 | German-localized map labels | `c00865a` | tile_provider_config.dart, map_style_provider.dart, main.dart, tile_provider_config_test.dart, map_style_provider_test.dart | Immutable `TileProviderConfig.language` field (default `'de'`); `styleUrl` appends `&language=<code>`. New `resolveMapLanguage(platformLocale)` helper + `kMapTilerSupportedLanguages` set (14 codes: en/de/es/fr/it/ja/ko/nl/pt/ru/tr/uk/vi/zh). `main.dart` reads `Platform.localeName`, resolves the code, threads into bootstrap `TileProviderConfig`. |
| 5 | Top-chrome margin 44 → 12 | `8b159c5` | map_screen.dart | Introduced `const double _chromeRowTopInset = 12` next to `_navRowBottomInset = 12`. Both `Positioned` widgets (settings button + focus pill) now use the constant. Permission denial banner untouched (already at 12 dp via `Padding`). |

## Deviations from Plan

### Task 3 zoom unification (minor scope creep)

**Plan text said:** "was 11 (in `CameraState.initial.zoom` and `MapWidget.initialZoom`)".

**Actual pre-04-16-1 state:** `CameraState.initial.zoom = 16` (post-Wave-7 legacy), `MapWidget.initialZoom = 11` (pre-Wave-7 default). Two divergent zoom levels.

**Applied:** unified BOTH to 15 for consistency + assertion in `camera_state_test.dart`. Rule 1 auto-fix — the divergence was a latent bug.

### Test tolerance: 3 style-URL exact-match tests survived

Two test files (`glass_shell_layout_test.dart`, `map_widget_follow_mode_test.dart`) hardcode `?key=test-key` URLs that DON'T include `&language=<code>`. These are `_FixedMapStyleUrlNotifier` fixture URLs, NOT reads of the real config resolver — so appending `&language=` is unnecessary. Left untouched. All 76 map tests still green.

### No architectural changes

None. Rule 4 not triggered. All 5 tasks were config-level / cosmetic per plan §Context.

## Authentication Gates

None encountered — no CLI / API auth needed for this plan.

## Deferred Verification

**Combined Phase 4 close-out drive (Kleinheubach + Frankfurt/Würzburg):**
- **#1 FGB toast:** cold-start the app; observe NO "LICENSE VALIDATION FAILURE" toast in the first 5s. If toast reappears, apply Option B (AndroidManifest dummy `<meta-data>` entry per plan §Task 1 fallback).
- **#5 Top-chrome alignment:** verify settings button + focus pill visually sit at the same distance below the status bar as the bottom-nav pill sits above the system nav bar (~12 dp each side). Should look symmetric on Samsung Galaxy S24 (Android 14) status-bar height.
- **#2 Attribution:** confirm the `(i)` icon is no longer visible on-map at any zoom / theme. Settings > About still shows the clickable MapTiler + OSM attribution rows (04-11).
- **#3 Zoom:** cold-start → observe zoom-level ~15 (individual streets + village labels visible for Kleinheubach).
- **#4 Language:** confirm map labels render in German for Kleinheubach / Frankfurt / Würzburg (verify at least one bilingual place like "München / Munich" appears in German).

Batched per user directive 2026-07-08 — memory ref: `phase-4-drives-deferred-to-gym-trip.md`. Same code-complete-drive-deferred pattern as Phase 3 (STATE 2026-07-05) and 04-15 / 04-16 (STATE 2026-07-08).

## Cross-References

- **Reverses 04-12 Task 1** (`8ea3ad9` restored on-map attribution). Task 2 of THIS plan pushes it off-screen again per user UX feedback 2026-07-08. Full trail: Phase-2 Wave-7 (2026-07-04) off-screen → 04-12 (2026-07-08) restored → 04-16-1 (2026-07-08) off-screen again. Legal attribution remains reachable via Settings > About (04-11 AboutSection, unchanged).
- **Test-count downstream contract for 04-17:** 04-17 is docs-only. Its close-out bullet list must reference `04-11..04-17 + 04-16-1 UX polish` as the Phase-4 rescope landing set.
- **Watchlist for future drives:** router shell tap tests (`test/features/map/router_shell_test.dart`, 4 tests marked `TODO(I551358)` per STATE 2026-07-03+) — the 12 dp top offset MAY unblock them but not attempted here. Left as pending todo.

## Verification

- `flutter analyze --no-pub`: clean after each task
- `flutter test test/features/trips/`: 70/70 green (post-Task 1)
- `flutter test test/features/map/`: 76/76 green (post-Tasks 2-5)
- **`flutter test` full suite: 266/266 green** (net +3 tests: 3 new tile-provider-config tests)
- `git status --porcelain`: shows only `.idea/` (out-of-scope IDE metadata)

## Commit Trail

```
bbcbb0d fix(04-16-1): suppress FGB license validation toast via reset:true
8444308 fix(04-16-1): hide on-map attribution icon (reverts 04-12 restore per UX feedback)
3b6d04b feat(04-16-1): default map zoom 11 → 15 (neighborhood-street detail)
c00865a feat(04-16-1): localize map labels to German (system-locale-aware fallback)
8b159c5 fix(04-16-1): top-chrome margin 44 → 12 (mirror bottom-chrome)
<metadata>       docs(04-16-1): code-complete UX polish (Wave 4a drive-verify deferred)
```
