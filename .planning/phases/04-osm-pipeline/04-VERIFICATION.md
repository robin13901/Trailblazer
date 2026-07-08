---
status: human_needed
---

# Phase 4 (Rescoped): Map & Matching Data Sources — Verification

**Verified:** 2026-07-08 (code-complete; drive-verify pending)
**Rescoped:** 2026-07-08 (from original bundled-`osm.sqlite` architecture — see `.planning/PROJECT.md` Key Decisions)
**Plans:** 04-11, 04-12, 04-13, 04-14, 04-15, 04-16, 04-16-1, 04-17 (8 plans, 4 waves + one polish plan)
**Status:** `human_needed` — code-complete across all 8 rescope plans; one real-device drive-verify pending on 04-15/04-16/04-16-1 items (batched to a combined Kleinheubach + Frankfurt/Würzburg drive per user directive 2026-07-08). 04-12 (Wave 1 MapTiler smoke) was device-verified on the same date.

---

## Rescoped Success Criteria

### SC1 — Map screen renders MapTiler tiles seamlessly at all zoom levels; attribution visible in Settings > About; light + dark styles both work

**Status:** **PASS** (device-verified)

**Evidence:**
- **Style spike:** `04-11-STYLE-SPIKE.md` — all 9 candidate MapTiler style IDs curl-verified against a free-tier account on 2026-07-08; every ID returned HTTP 200 + `application/json`, no paywall gates. Locked-in defaults: `dataviz` (light) + `dataviz-dark` (dark); fallback pair `streets-v2` / `streets-v2-dark` retained in the `MapTilerStyle` enum.
- **Key delivery:** `main.dart` uses `String.fromEnvironment('MAPTILER_KEY')` at top level; injected via `--dart-define=MAPTILER_KEY=...` or `--dart-define-from-file=env/dev.json`. `env/dev.json` is gitignored; `env/dev.json.example` checked in. CI workflows inject via `${{ secrets.MAPTILER_KEY }}`. Empty-key path emits a warning and continues booting (fork PRs without secret access must not fail).
- **Attribution (Settings > About):** `AboutSection` widget in `lib/features/settings/presentation/widgets/about_section.dart` renders three clickable license rows — `© MapTiler` → https://www.maptiler.com/copyright/, `© OpenStreetMap contributors` → https://www.openstreetmap.org/copyright, `MapLibre`. Each wrapped in `Semantics(label:, link: true)`.
- **On-map attribution:** Deliberately pushed off-screen via `attributionButtonMargins: const Point(-9999, -9999)` in 04-16-1 Task 2 per user UX feedback (reverts the 04-12 native bottom-left placement). Legal attribution is still reachable via Settings > About.
- **Device verification (04-12):** Samsung Galaxy S24, Android 14, 2026-07-08. Berlin (52.52, 13.405) at zoom 8/12/16/18 seamless in light theme. Kleinheubach (49.79, 9.19) at zoom 12/15/18 seamless (rural + village + river). Dark-mode brightness swap loads dark style correctly. Settings > About tap on MapTiler + OSM rows launches external browser on the copyright pages. Liquid Glass FAB unaffected during map animate-in (no `Picture.toImageSync` crash — RESEARCH §9 risk #3 not triggered).

**Tests:** 9 `TileProviderConfig` tests green (enum-ID mapping, URL formatting, hasKey guard, language localization default de + override en + resolver branch coverage). `flutter analyze --no-pub` clean.

---

### SC2 — Loopback `TileServer` and its deps are gone; `flutter analyze` clean

**Status:** **PASS** (code-verified)

**Evidence:**
- **Files deleted in 04-12** (verified `git log` + `grep`):
  - `lib/features/map/data/tile_server.dart`
  - `lib/features/map/data/tile_server_providers.dart`
  - `test/helpers/fake_tile_server.dart`
  - `tool/fetch_pmtiles.sh`
  - `tool/fetch_pmtiles.ps1`
  - `assets/map_style_light.json` (429 lines — obsolete custom Trailblazer schema)
  - `assets/map_style_dark.json` (429 lines — obsolete custom Trailblazer schema)
  - `test/assets/map_styles_test.dart` (4 assertions guarded the deleted styles)
- **Deps removed** from root `pubspec.yaml`: `pmtiles ^2.2.0`, `shelf ^1.4.2`, `shelf_router ^1.1.4`. Sub-package `tool/osm_pipeline/` keeps its own pins (dev-only, out-of-runtime).
- **Grep tripwires post-Wave-1** (04-12 SUMMARY): `TileServer` = 0 hits in `lib/`; `Point(-9999` = 0 hits in `lib/` (later reintroduced by 04-16-1 Task 2 for attribution off-screen push, intentionally); `mapStyleAssetProvider` = 0 hits in `lib/` and `test/`; `pmtiles` = 0 hits in root `pubspec.yaml` dependencies.
- **Analyzer + tests:** `flutter analyze --no-pub` clean at each task landing across Waves 1–4a. Full suite 266/266 green after 04-16-1 (was 184 pre-04-12; -5 obsolete assertions removed, +20 way-source/coordinator/tile-math tests via 04-15, +14 admin lookup + widget tests via 04-16, +3 tile-provider-config tests via 04-16-1).
- **`sqlite3 ^3.0.0` dependency_override** added to root `pubspec.yaml` as a Rule 3 blocking auto-fix in 04-12 (removing `pmtiles` exposed a pre-existing drift_flutter ^0.3.0 vs sub-package ^2.4.0 constraint conflict). Sub-package pin bump to ^3.0.0 is a pending todo before Phase 5 starts.

---

### SC3 — Trip finished online → fully-cached Overpass response within 30 s; trip finished offline → `pendingRoadData` state, picked up on reconnect

**Status:** **CODE-COMPLETE (drive-verify PENDING)** — combined Phase-4 close-out drive

**Evidence:**
- **Payload probe (04-13):** `04-13-PAYLOAD-PROBE.md` — Nuremberg 100×100 km bbox (`49.00, 10.50, 49.90, 11.60`) returned HTTP 200 in 67.37 s with **294.76 MiB uncompressed / 45.22 MiB gzipped / 422 318 raw ways → 107 879 Kfz ways after parser filter / 3.7 s Dart parse on dev box (est. 12–25 s on mid-tier mobile)**. Full Berlin→Munich (~550×200 km) and A9 corridor (~280×60 km) both failed with HTTP 504 "server too busy" — confirming the shared free-tier server cannot handle wide-corridor queries at all.
- **Verdict:** MANDATORY tile-splitting for v1. Both plan thresholds (≤ 5 MB uncompressed, ≤ 3 s parse) fail by ~60× and ~1.2× on dev box.
- **Coalescing path implemented in 04-15:** PER-TILE (z12 slippy tiles) with concurrency=2. NO coalescing branch was built — the 04-13 MANDATORY verdict eliminated the OPTIONAL coalescing sketch from the plan text.
- **Tile granularity:** Slippy z12 (~9.8 km × 6.5 km at latitude ~49°) via `TileBboxMath` (`lib/features/matching/data/tile_bbox_math.dart`, 164 lines pure math — no `dart:io`, no async). 6 unit tests including Berlin z12 (2200, 1343), round-trip tolerance, adjacent-tile union.
- **Overpass client (04-13):** `OverpassClient` with primary → primary (retry) → fallback attempt schedule; retryable statuses 429 + 5xx + `TimeoutException`; non-retryable 4xx fails fast; default backoff 2s/5s/10s. `User-Agent: Trailblazer/0.1 (github.com/I551358/Trailblazer)`. Fallback endpoint locked to VK Maps mirror `maps.mail.ru/osm/tools/overpass/api/interpreter` (probed live 2026-07-08 with a 3-node motorway query, returned HTTP 200 with valid Overpass JSON envelope; both plan-suggested fallbacks `overpass.kumi.systems` and `overpass.private.coffee` timed out on `/api/interpreter`).
- **Cache schema (04-14):** Drift v3 → `overpass_way_cache` composite PK (tileZ, tileX, tileY), gzipped payload BLOB + `payloadBytes` for cheap `SUM()`, `fetchedAt` with `currentDateAndTime` default. LRU high water 50 MB / low water 40 MB, oldest-`fetchedAt`-first eviction. 30-day TTL via `sweepTtl({DateTime? now})`.
- **Retry queue (04-14):** `pending_road_fetches` with `IntColumn tripId => integer().references(Trips, #id, onDelete: KeyAction.cascade)()` mirroring the `TripPoints → Trips` policy.
- **Trip lifecycle (04-15):** `TripStatus.pendingRoadData` inserted between `recording` and `pending`. Persisted via `TripStatusConverter.name` (TEXT), not ordinal — schema-v3 dump byte-identical to 04-14. State flow: `recording → pendingRoadData → pending → matched → confirmed`.
- **Coordinator (04-15):** `TripRoadFetchCoordinator` — fire-and-forget from `TrackingService.stopActive`; `AppLifecycleState.resumed` in `lib/app.dart` (root `App` now implements `WidgetsBindingObserver`) fires `unawaited(ref.read(tripRoadFetchCoordinatorProvider).drainQueue())`. Exponential backoff 5m/30m/2h/12h/24h → abandon at 5 attempts.
- **Connectivity:** `ConnectivitySeam` over `connectivity_plus ^7.0.0` (alphabetized dep hygiene held). Production adapter reads the plugin; tests inject a fake.
- **Test coverage:** 8 coordinator tests + 6 overpass-way-source tests + 5 OverpassWayCacheDao tests + 5 PendingRoadFetchesDao tests, all green.

**Drive-verify pending:** `<pending combined Phase-4 close-out drive — see memory: phase-4-drives-deferred-to-gym-trip.md>`
- Scenario A (online): trip finish → cache row + trip transitions to `pending` within 30 s.
- Scenario B (offline-drain): offline trip finish → `pendingRoadData` + `pending_road_fetches` row; reconnect + relaunch → drain within 60 s → trip flips to `pending`.
- Scenario C (cache-hit): second trip in same area → no new Overpass network request; immediate transition to `pending`.

---

### SC4 — `WayCandidateSource` interface has two working impls; test suite uses the fixture impl; runtime uses Overpass impl

**Status:** **PASS** (code-verified)

**Evidence:**
- **Abstract interface:** `lib/features/matching/data/way_candidate_source.dart` — single method `Future<List<WayCandidate>> fetchWaysInBbox({minLat, minLon, maxLat, maxLon, throwOnError})`.
- **Runtime impl:** `lib/features/matching/data/overpass_way_candidate_source.dart` — cache-first via `OverpassWayCacheDao`. Flow per tile: `cacheDao.getByTile(z,x,y)` → if hit + within TTL, decode + continue; on miss, `OverpassClient.fetchRawJson(bbox)`, gzip the raw response, `cacheDao.put(z, x, y, gzipped, wayCount)`; gunzip + parse via `OverpassResponseParser`; union results, dedupe by wayId, bbox-clip via `geometry.any(point-in-bbox)`. `throwOnError: false` returns partial cached-only results on network failure.
- **Test impl:** `test/helpers/fixture_way_candidate_source.dart` (NOT imported from `lib/`) — deterministic, offline, backed by the 04-13 gzipped Overpass fixtures (`urban_kreuzberg_5x5km.json.gz` 5.7 MB raw → 726 KB gz; `rural_grebenhain_5x5km.json.gz` 384 KB raw → 60 KB gz).
- **Kfz allowlist enforced at both impls:** `kfzHighwayClasses` 14-tag Set in `way_candidate.dart` (motorway/trunk/primary/secondary/tertiary + `*_link` variants + unclassified/residential/living_street/road; `service` intentionally absent per STATE Plan 04-01 OSM-02 decision).
- **WayCandidate model:** immutable, `@immutable`, wayId-based equality. Shape mirrors `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart:488-505` ways-row schema so Phase 5 golden corpora can be produced by either pipeline output or live Overpass responses with zero adapter code in the matcher.
- **OverpassClient split (04-15):** `fetchRawJson({bbox})` transport-only for cache-write; `fetchWaysInBbox` composes `fetchRawJson` + parser. Cache-write calls `fetchRawJson` directly so the parser can be revved without invalidating the cache.
- **Test coverage:** 6 overpass-way-source tests (cache miss/hit/TTL/dedupe/partial-on-error/bbox-clip), 24 parser tests, 5 query-builder tests, 7 client tests. 249/249 tests green post-Wave-2 code-complete.

---

### SC5 — Admin polygons L2..L10 bundled at `assets/admin/germany_admin.geojson.gz` (<15 MB), loaded at first-use, `regionAt(lat, lng, level)` correct for 5 known coordinates

**Status:** **PASS** (code-verified; drive-verify PENDING)

**Evidence:**
- **Bundle:** `assets/admin/germany_admin.geojson.gz` — **11.90 MB gzipped** (target 8–15 MB, PASS; no iteration on Douglas-Peucker tolerances needed).
- **Feature counts:** **30 819 features total** across L2..L10:
  - L2 = 3 (Germany + relations at country-level)
  - L4 = 17 (Bundesländer)
  - L6 = **400** (Landkreise + kreisfreie Städte — NOT Regierungsbezirke as the plan text originally guessed; corrected in 04-16 Task 1 commit)
  - L8 = 10 836 (Gemeinden)
  - L9 = 10 279 (Stadtteile)
  - L10 = 9 284 (Ortsteile)
- **Overpass query template:** `[out:json][timeout:600]; area["ISO3166-1"="DE"][admin_level=2]->.de; (relation["boundary"="administrative"]["admin_level"~"^(2|4|6|8|9|10)$"](area.de);); out geom;`. Server-side timeout 600s + client-side 620s. Attempt schedule primary → primary → fallback (VK Maps mirror, same as 04-13); backoff 30s/60s/120s. `User-Agent: Trailblazer-AdminPolyFetch/0.1`. Dev-CLI run 2026-07-08 succeeded on the primary endpoint in ~5 min (well inside 10-min budget). Raw envelope 904 MB → simplified bundle 11.90 MB gzipped.
- **Douglas-Peucker tolerances** (per admin_level, meters): L2=10, L4=30, L6=50, L8/L9/L10=100. Meters→degrees via 1° ≈ 111 km.
- **Lookup:** `AdminRegionLookup` — hash-grid at 0.01° cells; cell key packed as `((cellY+2^19) << 20) | (cellX+2^19)`. Runtime-refreshed copy at `<AppDocsDir>/admin/germany_admin.geojson.gz` takes precedence over the bundled asset. GeoJSON `[lon, lat]` transposed to `[lat, lon]` at parse time so the runtime hot-path skips the swap.
- **Latency:** mean regionAt() **<5 ms/avg on the Windows dev box** across 1000 calls (04-16 Task 2 test 7).
- **Fixture coordinates round-trip correctly** (9 lookup tests): Berlin at L4 → `Berlin`; Kreuzberg at L10 → `Kreuzberg`; Kleinheubach at L8 → `Kleinheubach`; Miltenberg at L6 → `Landkreis Miltenberg`; Bayern at L4 → `Bayern`; ocean point → null; 1000-call latency; ensureLoaded idempotent; invalidate re-parse.
- **Refresh:** `AdminBundleRefresher` boundary in Settings > Data > "Refresh admin regions": tap → confirm dialog → refresher → SnackBar (success/failure). Bumps `AppPrefs.adminBundleVersion` (ISO-8601 timestamp) + calls `lookup.invalidate()`. `DomainError.wrap(e, st)` on the outer try.
- **Leaf-package route locked:** `packages/admin_geometry/` is a pure-Dart leaf package (own pubspec + analysis_options, `sdk: ^3.5.0`, `http` dep) exporting `AdminPolygonDownloader` + `AdminPolygonSimplifier`. Both the main Flutter app AND `tool/osm_pipeline/` add it as a path-dep. Sub-package's 251-test suite unaffected by the leaf.
- **Test coverage:** 9 lookup tests + 5 widget tests + 5 leaf-package tests (all green standalone via `dart test`).

**Drive-verify pending:** `<pending combined Phase-4 close-out drive — see memory: phase-4-drives-deferred-to-gym-trip.md>`
- Scenario D (bundled admin lookup on-device): Kleinheubach L8=`Kleinheubach`, L6=`Miltenberg`, L4=`Bayern`; Berlin L4=`Berlin`, L10=an Ortsteil; asset load-to-first-lookup < 3 s.
- Scenario E (Settings > Data > "Refresh admin regions"): tap → confirm dialog → progress spinner → SnackBar "Admin regions updated" (~5 min wall-clock); subtitle updates to "Last refreshed: <ISO-8601>"; kill/reopen persists; post-refresh lookups still work.

---

## UX polish (04-16-1)

Wave 4a folded 5 user-observed UI fixes into the rescope before the docs close-out. Status: **CODE-COMPLETE; drive-verify PENDING (batched with SC3 + SC5 drive)**.

| # | Fix | Status |
|---|------|--------|
| 1 | FGB `LICENSE VALIDATION FAILURE` toast suppressed via `bg.Config(reset: true)` on `bg.BackgroundGeolocation.ready(...)` (Option A per plan spec). If Option A fails on the drive, Option B is a dummy `<meta-data android:name="com.transistorsoft.locationmanager.license" android:value=""/>` in AndroidManifest.xml. | Code-complete; drive-verify PENDING |
| 2 | Attribution `(i)` icon pushed off-screen via `Point(-9999, -9999)` (reverts 04-12 native bottom-left placement per user UX feedback). Legal MapTiler + OSM attribution remains reachable in Settings > About. | Code-complete + widget-test asserts off-screen Point |
| 3 | Default map zoom unified to **15** — `CameraState.initial.zoom = 15` (was 16) + `MapWidget.initialZoom = 15` (was 11). Kleinheubach with individual streets + village label now visible on cold start. | Code-complete + `camera_state_test` + `map_widget_test` assert 15 |
| 4 | MapTiler style URL localized via `&language=<code>` query param, default `'de'`. New `resolveMapLanguage(platformLocale)` helper + `kMapTilerSupportedLanguages` set of 14 codes. `main.dart` reads `Platform.localeName` and threads into bootstrap `TileProviderConfig`. | Code-complete + 3 new tile-provider-config tests |
| 5 | Top-chrome vertical inset **44 → 12** — new `_chromeRowTopInset = 12` constant mirrors `_navRowBottomInset`. Both top-chrome `Positioned` widgets in `map_screen.dart` (settings button, focus pill) now sit at 12 dp below `SafeArea`. | Code-complete; drive-verify PENDING (symmetric alignment vs bottom-nav pill) |

Test count 263 → 266 (+3 net); `flutter analyze --no-pub` clean.

---

## Not in Phase 4 (deferred to Phase 5)

- HMM matcher (consumes `WayCandidateSource`).
- Golden corpus generation via `tool/osm_pipeline` fixture PBFs.
- `driven_way_intervals` table.
- Matcher's in-memory R-Tree built per-trip from the ways returned by the source (adaptive radius, top-5 candidates).
- `MatcherIsolate` warm long-lived worker.

---

## Legacy Artifacts On Disk (not deleted, unless noted)

- `04-01..04-09-*-PLAN.md` + `04-01..04-09-SUMMARY.md` (7 plans of the original Phase 4 bundled-pipeline architecture — pipeline is retained as dev-only fixture generator; the SUMMARY docs remain the source of truth for how `tool/osm_pipeline/` works). Superseded 2026-07-08 for **runtime** purposes; retained for **dev tooling**.
- `04-10-1-01..04-10-1-04-*-PLAN.md` + SUMMARYs (Sub-Phase 04-10.1 Waves 1-4 — dev-only pipeline improvements: ProgressLogger, Feldweg-drop, perWay R-Tree, Stage D isolate parallelization). Retained as `tool/osm_pipeline/` still exists as dev tooling.
- `04-10-1-05-germany-close-out-PLAN.md`: **DELETED at session start (commit `e475ad8` 2026-07-08)** — was superseded by the rescope before ever executing. Do not recreate.
- `04-10-full-germany-close-out-PLAN.md`: **DELETED at the same commit `e475ad8`** — was the original Phase-4 close-out plan.
- `04-11..04-17` + `04-16-1` PLAN + SUMMARY docs are the ACTIVE rescope-plan artifacts. `04-16-1-ux-polish-PLAN.md` was slotted in AFTER 04-16 during execution to fold 5 user-observed UI fixes (adds an 8th plan to the rescope; ROADMAP.md Phase 4 block reflects this).

---

## Human Verification Checklist

The following on-device verification is REQUIRED to advance the phase from `human_needed` → `passed`. Consolidated into a single actionable list per user directive 2026-07-08 (memory: `phase-4-drives-deferred-to-gym-trip.md`) — a combined Kleinheubach + Frankfurt/Würzburg drive covers everything at once.

**(a) 04-15 SC3 scenarios — road-data fetch + retry queue**
- [ ] Scenario A (online): drive somewhere new (not previously cached) → tap Stop → within 30 s the trip transitions from `recording` → `pendingRoadData` → `pending`. Verify via the tracking diagnostics HUD (Settings > Debug HUD) or by inspecting the trip in the Trips tab.
- [ ] Scenario B (offline-drain): enable airplane mode → drive somewhere new → tap Stop → trip lands in `pendingRoadData` with a `pending_road_fetches` row (visible in HUD). Disable airplane mode → relaunch app → within 60 s (or on `AppLifecycleState.resumed`) the queue drains, the fetch succeeds, and the trip flips to `pending`.
- [ ] Scenario C (cache-hit): drive the same corridor a second time → tap Stop → no new Overpass network request (HUD network counter unchanged) → immediate transition to `pending`.

**(b) 04-16 SC5 scenarios — bundled admin lookup on-device**
- [ ] Scenario D: bundled admin lookup — Kleinheubach (49.796, 9.185) at L8 → `Kleinheubach`; at L6 → `Miltenberg`; at L4 → `Bayern`. Berlin (52.52, 13.405) at L4 → `Berlin`; at L10 → an Ortsteil. Asset load-to-first-lookup < 3 s on cold start.
- [ ] Scenario E (Settings > Data > "Refresh admin regions"): tap → confirm dialog → progress spinner → SnackBar "Admin regions updated" (~5 min wall-clock). Subtitle updates to "Last refreshed: <ISO-8601>". Kill + reopen app → subtitle persists. Post-refresh lookups still work (docs-dir override doesn't break parsing).

**(c) 04-12 SC1 tile smoke** *(device-verified 2026-07-08 on Samsung Galaxy S24; re-verify in the combined drive)*
- [ ] Pan/zoom around Kleinheubach + Frankfurt or Würzburg (closest urban areas) in light + dark modes.
- [ ] Attribution icon NO LONGER visible on-map (04-16-1 Task 2 pushed it off-screen). About-link taps in Settings launch external browser on the copyright pages.

**(d) 04-16-1 UX polish visual checks**
- [ ] Task 1 — FGB `LICENSE VALIDATION FAILURE` toast NOT shown on cold start. If it still appears, fall back to Option B (AndroidManifest dummy meta-data).
- [ ] Task 3 — default zoom = 15 on cold start; Kleinheubach individual street labels + village label visible.
- [ ] Task 4 — map labels render in German; at least "München" appears in German across the tiles.
- [ ] Task 5 — top-chrome settings button + focus pill sit at 12 dp below safe-area top, mirroring the bottom-nav pill's 12 dp inset above the system nav bar. Should look symmetric on Galaxy S24.

**(e) Ancillary — regressions to guard against**
- [ ] Liquid Glass FAB not regressed (renders correctly during map animate-in).
- [ ] No-crash on tab switch during admin-refresh (progress state sticks; refresh survives tab moves).
- [ ] MapTiler tiles remain visible throughout the drive (no blank / gray tile blocks on backgrounded resume).

**After the drive:** land the deferred `docs(04-1X): ... verified on device` commit(s) — either one per plan (04-15, 04-16, 04-16-1) OR one combined `docs(04): Phase 4 rescope verified on device`. Replace the "pending combined Phase-4 close-out drive" markers in this document with the actual verification date + device + observed results, and flip the top-of-file `status:` from `human_needed` to `passed`.

---

## Deviations from Original Plan

1. **`04-10-1-05-germany-close-out-PLAN.md` SUPERSEDED-marker step SKIPPED** — the file was already DELETED at session start (commit `e475ad8` 2026-07-08, alongside `04-10-full-germany-close-out-PLAN.md`) at a prior orphan-handling AskUserQuestion prompt. PROJECT.md Key Decisions + this file's "Legacy Artifacts On Disk" section note the deletion by commit hash instead of recreating the file to add a marker.
2. **`04-16-1-ux-polish-PLAN.md` slotted in mid-execution** — added AFTER 04-16 to fold 5 user-observed UI fixes (FGB toast, off-screen attribution, default zoom 15, German localization, top-chrome margin). Plan count went from 7 to 8; ROADMAP.md Phase 4 block includes 04-16-1 in the plan list.
3. **Coalescing branch NOT built (04-15)** — 04-13 MANDATORY payload-probe verdict eliminated the OPTIONAL coalescing sketch from the 04-15 plan text. PER-TILE with concurrency=2 is the only code path.
4. **Fallback endpoint = VK Maps mirror** (04-13) — both plan-suggested fallbacks (`overpass.kumi.systems`, `overpass.private.coffee`) timed out on `/api/interpreter` on 2026-07-08. `maps.mail.ru/osm/tools/overpass/api/interpreter` was probed live and locked in per plan §Deviations.
5. **L6 count** — plan text said "~40 (Regierungsbezirke)"; actual count is 400 (Landkreise + kreisfreie Städte). Corrected in 04-16 Task 1 commit; no iteration on Douglas-Peucker tolerances (bundle in-budget).
6. **`sqlite3 ^3.0.0` dependency_override** — added to root `pubspec.yaml` in 04-12 as a Rule 3 blocking auto-fix. Removing `pmtiles` exposed a pre-existing drift_flutter ^0.3.0 vs sub-package ^2.4.0 constraint conflict. Bumping the sub-package pin to ^3.0.0 (and removing the override) is a pending todo before Phase 5 starts.
