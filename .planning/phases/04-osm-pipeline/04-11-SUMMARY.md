---
phase: 04-osm-pipeline
plan: 11
subsystem: infra
tags: [maptiler, tile-provider, api-key, riverpod, ci, attribution]

# Dependency graph
requires:
  - phase: 02-map-glass-shell
    provides: mapStyleAssetProvider brightness-observer contract + MapWidget style-fade seam
  - phase: 04-osm-pipeline (Plan 04-RESCOPE decisions)
    provides: locked "MapTiler Cloud + fetched-tiles" rescope decision (STATE 2026-07-08)
provides:
  - TileProviderConfig immutable model + MapTilerStyle enum (spike-verified against MapTiler free tier)
  - tileProviderConfigProvider + mapStyleUrlProvider (Riverpod plumbing for MapTiler URLs)
  - kMaptilerKey injection path via --dart-define=MAPTILER_KEY / --dart-define-from-file=env/dev.json
  - Settings > About attribution with clickable, screen-reader focusable MapTiler + OSM links
  - CI wiring: --dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }} on flutter test + flutter build ipa
  - env/dev.json.example + README MapTiler-setup section + .gitignore for env/dev.json
affects:
  - 04-12-style-rewrite-and-tileserver-teardown (consumes mapStyleUrlProvider; deletes mapStyleAssetProvider + TileServer)
  - 04-13-overpass-client (unrelated key plumbing pattern precedent)
  - Phase 5+ (MapTiler URL is the runtime tile source going forward)

# Tech tracking
tech-stack:
  added: []  # zero new pubspec deps; url_launcher already present
  patterns:
    - "String.fromEnvironment('MAPTILER_KEY') at main.dart top-level → ProviderContainer override injection"
    - "TileProviderConfig immutable + hasKey guard + debug-only assertion (fail-loud on empty key)"
    - "Attribution links wrapped in Semantics(label:, link: true) for screen-reader focus"
    - "Old provider retained one commit; downstream plan owns deletion (parallel-safe swap)"

key-files:
  created:
    - lib/features/map/data/tile_provider_config.dart
    - lib/features/settings/presentation/widgets/about_section.dart
    - test/features/map/tile_provider_config_test.dart
    - env/dev.json.example
    - .planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md
  modified:
    - lib/main.dart
    - lib/features/map/presentation/providers/map_style_provider.dart
    - lib/features/settings/presentation/settings_screen.dart
    - .gitignore
    - README.md
    - .github/workflows/ci.yml
    - .github/workflows/ios-build.yml

key-decisions:
  - "MapTiler defaults: dataviz (light) + dataviz-dark (dark) — muted grayscale per RESEARCH; fallback pair streetsV2/streetsV2Dark kept in enum for future account-drift safety"
  - "Empty-key path tolerated (warning logged, app boots) — fork PR CI without the secret must not fail"
  - "Debug-mode assert on TileProviderConfig.styleUrl when hasKey=false — fails loud during dev, silent in release"
  - "New MapStyleUrlNotifier is a Notifier<String> (not Provider<String>) so the map widget's WidgetsBindingObserver.didChangePlatformBrightness can push updates on system-brightness flips"
  - "AboutSection refactored to its own file at the plan-mandated path; old inline _AboutTile deleted; MapTiler + OSM rows required by free-tier TOS + ODbL"
  - "Old mapStyleAssetProvider kept intact — 04-12 owns its deletion. Prevents a broken map bootstrap if 04-11 lands but 04-12 slips."

patterns-established:
  - "Pattern: pure-Dart config model + Riverpod override at ProviderContainer level for --dart-define delivery"
  - "Pattern: separate attribution rows per free-tier license (MapTiler + OSM), each wrapped in Semantics(link: true)"
  - "Pattern: dev.json.example checked in, real dev.json gitignored, CI reads from GitHub Actions secret"

# Metrics
duration: 15min
completed: 2026-07-08
---

# Phase 4 Plan 11: MapTiler Provider and Key Plumbing Summary

**End-to-end MapTiler API key wiring — pure-Dart TileProviderConfig + Riverpod overrides + CI secret injection + Settings About attribution — landed atomically alongside the legacy asset-based style provider for a parallel-safe handoff to 04-12.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-07-08T09:17:05Z
- **Completed:** 2026-07-08T09:32:23Z
- **Tasks:** 3 (all `type="auto"`; no checkpoints)
- **Files created:** 5
- **Files modified:** 7

## Accomplishments

- **Spike closed:** All 9 candidate MapTiler style IDs curl-verified against a free-tier account (HTTP 200 + `application/json`). Chosen defaults `dataviz` / `dataviz-dark` documented in `04-11-STYLE-SPIKE.md`.
- **Pure-Dart tile-provider model:** `TileProviderConfig` + `MapTilerStyle` enum + 6 unit tests covering enum-ID mapping, URL formatting, hasKey false/true, and the empty-key debug assertion.
- **Runtime key delivery:** `kMaptilerKey = String.fromEnvironment('MAPTILER_KEY')` in `main.dart` → `TileProviderConfig` constructor → `ProviderContainer(overrides: [tileProviderConfigProvider.overrideWithValue(...)])`. Empty-key path emits a `Logger('main').warning(...)` and continues booting.
- **New MapTiler URL provider:** `mapStyleUrlProvider` (Notifier<String>) resolves the current MapTiler `style.json` URL from the injected config + system brightness. Coexists with the legacy `mapStyleAssetProvider` for one commit — 04-12 will delete the legacy provider.
- **Settings > About attribution:** `AboutSection` widget extracted to `lib/features/settings/presentation/widgets/about_section.dart` per plan's mandated path. Ships MapTiler + OSM rows, each wrapped in `Semantics(link: true)` for screen-reader focus. Free-tier TOS + ODbL satisfied.
- **CI wired:** Both `ci.yml` and `ios-build.yml` inject `--dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }}` into every `flutter test` / `flutter build ipa` invocation. Fork PRs without the secret run the empty-key path intentionally.
- **Dev-workflow docs:** `env/dev.json.example` documents the JSON shape; `env/dev.json` remains gitignored and untracked (verified via `git check-ignore env/dev.json` after every commit); README gains a MapTiler-key setup section between Prerequisites and Quickstart.

## Task Commits

Each task committed atomically per project CLAUDE.md rules:

1. **Task 1: MapTiler style-ID spike + document confirmed IDs** — `37ca3a6` (docs)
2. **Task 2: TileProviderConfig model + MapTilerStyle enum + unit tests** — `f843e29` (feat)
3. **Task 3: Wire MAPTILER_KEY through main + provider + CI + attribution** — `0a1f370` (feat)

Plan metadata commit follows this SUMMARY: `docs(04-11): complete maptiler-provider-and-key-plumbing plan`.

## Files Created/Modified

**Created:**
- `.planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md` — 9-row style-ID table, chosen defaults, RESEARCH-cited justification.
- `lib/features/map/data/tile_provider_config.dart` — `TileProviderConfig` immutable model + `MapTilerStyle` enum + `styleUrl(...)` resolver with debug-assert guard.
- `lib/features/settings/presentation/widgets/about_section.dart` — Standalone About-section widget with MapTiler + OSM + MapLibre credits, all wrapped in `Semantics(link: true)`.
- `test/features/map/tile_provider_config_test.dart` — 6 unit tests (enum-ID mapping, URL formatting for dataviz + streetsV2Dark, hasKey false/true, empty-key assertion trip).
- `env/dev.json.example` — JSON shape for `--dart-define-from-file`; real `env/dev.json` remains gitignored.

**Modified:**
- `lib/main.dart` — Reads `kMaptilerKey` at top-level; constructs `TileProviderConfig(dataviz, datavizDark, kMaptilerKey)`; overrides `tileProviderConfigProvider` on the `ProviderContainer`. Warning logged on empty key.
- `lib/features/map/presentation/providers/map_style_provider.dart` — Added `tileProviderConfigProvider` (Provider<TileProviderConfig>) + `mapStyleUrlProvider` (Notifier<String>). Deprecation notice added to legacy `mapStyleAssetProvider`.
- `lib/features/settings/presentation/settings_screen.dart` — Replaced inline `_AboutTile` with `AboutSection()` import.
- `.gitignore` — Added `env/dev.json` entry.
- `README.md` — Added "MapTiler key setup" section; step 6 in Quickstart updated to use `--dart-define-from-file=env/dev.json`.
- `.github/workflows/ci.yml` — Test step gains `--dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }}`.
- `.github/workflows/ios-build.yml` — Build step gains `--dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }}`.

## Decisions Made

- **Defaults `dataviz` / `dataviz-dark` chosen** — RESEARCH's muted-grayscale recommendation, empirically confirmed to load on the free tier. `streets-v2` / `streets-v2-dark` retained in the enum as fallback in case the free-tier catalog shifts on a future account.
- **Empty key = warn + continue, not fail** — Fork PRs run CI without access to the GitHub Actions secret. Failing hard would block outside contributors; the empty-key path produces blank tiles + a `Logger('main').warning(...)` line that the diagnostics HUD picks up.
- **New provider `mapStyleUrlProvider` is a `Notifier<String>`, not a plain `Provider<String>`** — the map widget's existing `WidgetsBindingObserver.didChangePlatformBrightness` pattern (STATE Plan 02-04 line 97) requires an imperative update path. A `Notifier` mirrors the legacy `MapStyleAssetNotifier` API so 04-12's rewire is a drop-in swap.
- **AboutSection is a new file at the plan-mandated path**, not an edit of the inline widget — the plan spec (`files_modified` frontmatter) explicitly lists `lib/features/settings/presentation/widgets/about_section.dart`. The `_AboutTile` was inlined in Phase 2; extracting it lets 04-12 own further attribution refinements without touching `settings_screen.dart` again.
- **Old `mapStyleAssetProvider` retained for one commit** — per plan §Tasks.Task 3 note. Downstream 04-12 owns deletion. Prevents a broken map bootstrap if 04-11 ships but 04-12 slips (map widget still consumes the old asset paths until then).

## Deviations from Plan

None — plan executed exactly as written. The `AppLogger.warn` call sketched in the plan text was translated to `Logger('main').warning(...)` per STATE Plan 02-03 decision (no `AppLogger` class exists in the codebase — `core/logging/app_logger.dart` provides `setupLogging()` only). Sub-decision made inline; not a deviation from the plan's intent.

**Total deviations:** 0.
**Impact on plan:** None.

## Issues Encountered

- **`unintended_html_in_doc_comment` lint fired on `main.dart`** — the doc comment for `kMaptilerKey` used `<key>` as a placeholder inside a code fence, which very_good_analysis interprets as an HTML tag hazard. Fixed by wrapping the placeholder in backticks: `` `your-key` ``. First `flutter analyze` run flagged it; second run clean. Not a deviation — a routine analyze-fix loop iteration per Ralph Loop tight-cycle rules.

## User Setup Required

**Developer setup (per-clone, one-time):**

1. Get a personal free-tier key from https://cloud.maptiler.com/account/keys/
2. `cp env/dev.json.example env/dev.json`
3. Paste the key into `env/dev.json` (already gitignored)
4. Run with `flutter run --dart-define-from-file=env/dev.json`

**CI setup (already assumed configured in the GitHub Actions secrets store):**

- Repo secret `MAPTILER_KEY` — used by both `ci.yml` and `ios-build.yml` workflows.

The empty-key path is intentionally tolerated so fork PRs without secret access can still run tests. The map renders blank tiles under an empty key; a warning is logged and the diagnostics HUD will surface the resulting HTTP 401 chain once the map widget's tile request lands.

## Next Phase Readiness

**Ready for 04-12 (style-rewrite-and-tileserver-teardown):**

- `mapStyleUrlProvider` in place and returning valid MapTiler URLs when `MAPTILER_KEY` is present.
- `tileProviderConfigProvider` overridable at `ProviderContainer` level — 04-12 tests can override with a fixture config for offline widget tests.
- Old `mapStyleAssetProvider` still present with a deprecation notice. 04-12 must delete:
  - `mapStyleAssetProvider` + `MapStyleAssetNotifier` from `map_style_provider.dart`
  - `assetForBrightness` helper
  - `lib/features/map/data/tile_server.dart`, `lib/features/map/data/tile_server_providers.dart`
  - `assets/tiles/*.pmtiles` + `assets/map_style_*.json`
  - `pubspec.yaml` deps: `pmtiles`, `shelf`, `shelf_router`
  - MapWidget's `tileServerProvider.watch(...)` gate
- Berlin/Germany PMTiles bootstrapping is now dead code — pipeline artifacts remain useful for 04-13+ (Overpass) but the runtime no longer needs them.

**No blockers.** SC verified:

- `flutter analyze` clean.
- `flutter test` all 184 tests green.
- Grep tripwires: `String.fromEnvironment('MAPTILER_KEY')` present in `lib/main.dart`; `MAPTILER_KEY` present in both CI workflow files.
- `env/dev.json` gitignored (verified via `git check-ignore` post-commit).
- Old asset-path provider still present (verified via grep count = 3 references in the provider file).

---
*Phase: 04-osm-pipeline*
*Completed: 2026-07-08*
