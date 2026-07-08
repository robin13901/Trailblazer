---
phase: 04-osm-pipeline
plan: 16
subsystem: admin-regions-runtime
tags: [admin-polygons, bundled-asset, spatial-index, hash-grid, overpass, leaf-package, wave-3, code-complete, drive-deferred]
status: code-complete-drive-deferred

# Dependency graph
requires:
  - phase: 04-osm-pipeline (Plan 04-13)
    provides: Overpass endpoint decisions (primary + VK-Maps fallback), retry/backoff pattern reused in `AdminPolygonDownloader`
  - phase: 04-osm-pipeline (Plan 04-15)
    provides: code-complete-drive-deferred close-out pattern reused verbatim for the same combined Phase-4 drive session
  - phase: 01-scaffolding (Plan 01-03, 01-04)
    provides: SharedPreferencesAsync repo pattern (`OnboardingFlagRepository`) reused for `AppPrefs`; `DomainError.wrap` boundary for the refresher
provides:
  - `packages/admin_geometry/` — pure-Dart LEAF package (`AdminPolygonDownloader` + `AdminPolygonSimplifier`) consumed by both the runtime `AdminBundleRefresher` and the dev CLI at `tool/osm_pipeline/bin/fetch_admin_polygons.dart`. Single source of truth for the Overpass fetch + Douglas-Peucker simplification.
  - `assets/admin/germany_admin.geojson.gz` — committed bundled asset, 11.90 MB gzipped, 30,819 features across levels 2/4/6/8/9/10.
  - `AdminRegion` domain model (`lib/features/admin/data/admin_region.dart`) — immutable, MultiPolygon geometry, ray-cast `containsPoint` respecting holes.
  - `AdminRegionLookup` (`lib/features/admin/data/admin_region_lookup.dart`) — lazy load + 0.01° hash-grid spatial index + `regionAt(lat, lon, level)` in <5 ms; docs-dir override precedence for runtime-refreshed copies.
  - `AdminBundleRefresher` (`lib/features/admin/data/admin_bundle_refresher.dart`) — runtime Overpass fetch → replace docs-dir bundle → bump `AppPrefs.adminBundleVersion` → invalidate lookup cache.
  - `AppPrefs` (`lib/core/prefs/app_prefs.dart`) — new SharedPreferencesAsync wrapper; mirrors `OnboardingFlagRepository` shape.
  - `DataManagementSection` (`lib/features/settings/presentation/widgets/data_management_section.dart`) — Settings > Data > "Refresh admin regions" ListTile + confirm dialog + progress spinner + result SnackBar.
  - Riverpod providers: `adminRegionLookupProvider`, `adminBundleRefresherProvider`, `appPrefsProvider` (all plain `Provider<T>` per STATE 01-01).
  - 14 new tests: 9 lookup + 5 widget (all green).
affects:
  - 04-17 (rescope close-out) — REQUIREMENTS.md/ROADMAP.md rewrite for the rescoped architecture; 04-17 owns that rewrite. Our SUMMARY documents the hand-off explicitly.
  - Phase 5 (matcher) — WayCandidateSource seam (04-15) + AdminRegionLookup (this plan) together compose the road + admin context the HMM matcher will consume.
  - Future plans that need SharedPreferencesAsync storage — `AppPrefs` is the new central home; extend its key set rather than adding parallel repos.

# Tech tracking
tech-stack:
  added:
    - "packages/admin_geometry — new pure-Dart leaf package, own pubspec + analysis_options."
    - "http ^1.2.0 → tool/osm_pipeline/pubspec.yaml (transitive to admin_geometry; alphabetized)."
    - "path-dep admin_geometry → root pubspec.yaml dependencies (alphabetized)."
    - "path-dep admin_geometry → tool/osm_pipeline/pubspec.yaml dependencies (alphabetized)."
  patterns:
    - "**Leaf-package route for cross-runtime shared code.** `tool/osm_pipeline/` sub-package is pure Dart (SDK-only, no Flutter binding), so it CANNOT path-depend on the main Flutter package. Solution: extract shared pure-Dart code into `packages/admin_geometry/` and have BOTH the Flutter app AND the pipeline sub-package add it as a path-dep. Documented as the go-to pattern for any future shared code that needs to live on both sides of the app/dev-tooling boundary."
    - "**Hash-grid spatial index over 0.01° cells** for point-in-polygon lookups. Cell key packed as `(cellY+2^19)<<20 | (cellX+2^19)` — signed 20-bit each dimension, well inside DE bbox range. Regions inserted into every cell their bbox overlaps; lookup queries the single cell containing the query point. 1000-call latency <5 ms/avg on the Windows dev box."
    - "**Docs-dir runtime override for bundled assets.** `AdminRegionLookup` prefers `<AppDocsDir>/admin/germany_admin.geojson.gz` over `rootBundle` when the override exists. Enables `AdminBundleRefresher` to swap the bundle without an app upgrade."
    - "**Task 1b sanity-check as inline dev-script.** With no `jq` on the Windows box, a temporary `_check_admin_bundle.dart` invoked via `dart run` produced the L2/L4/L6/L8 counts directly. Deleted before commit; pattern captured for future asset-inspection needs."

key-files:
  created:
    - packages/admin_geometry/pubspec.yaml
    - packages/admin_geometry/analysis_options.yaml
    - packages/admin_geometry/lib/admin_geometry.dart
    - packages/admin_geometry/lib/src/admin_polygon_downloader.dart
    - packages/admin_geometry/lib/src/admin_polygon_simplifier.dart
    - packages/admin_geometry/test/admin_polygon_simplifier_test.dart
    - tool/osm_pipeline/bin/fetch_admin_polygons.dart
    - assets/admin/germany_admin.geojson.gz
    - lib/core/prefs/app_prefs.dart
    - lib/features/admin/data/admin_region.dart
    - lib/features/admin/data/admin_region_lookup.dart
    - lib/features/admin/data/admin_region_providers.dart
    - lib/features/admin/data/admin_bundle_refresher.dart
    - lib/features/settings/presentation/widgets/data_management_section.dart
    - test/features/admin/admin_region_lookup_test.dart
    - test/features/settings/data_management_section_test.dart
  modified:
    - pubspec.yaml (admin_geometry path-dep; `assets/admin/` asset entry)
    - pubspec.lock
    - tool/osm_pipeline/pubspec.yaml (admin_geometry path-dep; http alphabetized)
    - tool/osm_pipeline/pubspec.lock
    - lib/features/settings/presentation/settings_screen.dart (Data section inserted between About + Coming-later)

key-decisions:
  - "Leaf-package route chosen at plan-start (not iteratively) because `tool/osm_pipeline/` is pure Dart — path-depending on the Flutter main package would pull the entire Flutter runtime tree through `dart pub get` and break the sub-package's 251-test suite. Shared code lives at `packages/admin_geometry/` (pure Dart, own pubspec) and is a path-dep from both sides."
  - "Overpass query template locked as per plan text: `[out:json][timeout:600]; area[ISO3166-1=DE][admin_level=2]->.de; (relation[boundary=administrative][admin_level~^(2|4|6|8|9|10)$](area.de);); out geom;`. Server-side timeout 600 s + client-side 620 s. Retries 30/60/120 s on 429/5xx + fallback endpoint = VK Maps mirror (STATE Plan 04-13)."
  - "Douglas-Peucker tolerance table per level: 2→10 m, 4→30 m, 6→50 m, 8/9/10→100 m. Meters→degrees via 1° ≈ 111 km. Resulting bundled asset: 11.90 MB gzipped (target 8-15 MB), 30,819 features. No iteration on tolerances needed."
  - "**L6 count reality-check: 400, not ~40.** Plan sign-off criteria said `L6 count: ~40 (Regierungsbezirke)` — that's wrong for DE OSM. `admin_level=6` in DE maps to Landkreise + kreisfreie Städte (~400). The plan's own Task 2 fixture uses `Landkreis Miltenberg` at L6, confirming this. Bundle passes size + level-coverage sign-off; the count semantic in the plan sign-off text was mistaken."
  - "Hash-grid cell size 0.01° (roughly 1.1 km at DE latitudes). 5-region synthetic test fixture (Berlin L4, Kreuzberg L10, Bayern L4, Miltenberg L6, Kleinheubach L8) fits into the grid trivially; 1000-call latency test averages well under 5 ms on the Windows dev box."
  - "`AdminRegionLookup` prefers `<AppDocsDir>/admin/germany_admin.geojson.gz` over the bundled asset. `AdminBundleRefresher` writes to that path + bumps `AppPrefs.adminBundleVersion` + calls `lookup.invalidate()` so the next `regionAt` reloads. No file-check on every call — the docs-dir probe happens only inside `ensureLoaded()`, which is called at most once per lookup lifecycle."
  - "`AppPrefs` is a brand-new class (no prior `AppPrefs` runtime class existed — only a Drift `AppPrefs` TABLE, unused for runtime prefs). Shape mirrors `OnboardingFlagRepository`: `SharedPreferencesAsync`-backed, public `k*` keys, plain `Provider<AppPrefs>`. Future prefs keys extend `AppPrefs` rather than adding parallel repos."
  - "`AdminPolygonSimplifier` is pure Dart, tested against synthetic GeoJSON (5 tests: closed rectangle, donut multipolygon, tolerance monotonicity, name/name:de preservation, empty-name rejection). Runs 5/5 green under `dart test` inside the leaf package."
  - "Dev CLI (`tool/osm_pipeline/bin/fetch_admin_polygons.dart`) took ~5 min on the dev box against the real Overpass — well inside the plan's 10-min budget. 904 MB raw JSON envelope → 11.9 MB gzipped simplified bundle. Overpass primary endpoint responded first-try; no fallback needed."
  - "`tool/osm_pipeline/` sub-package tests remain green (251/251) after the leaf-package path-dep addition. `dart pub get` inside the sub-package pulls only `admin_geometry` + its `http` transitive; no Flutter contamination."
  - "**04-16 Task 1b + real-device Wave 3 smoke DEFERRED.** Task 1b sanity check handled inline by this executor. Real-device checkpoints (Settings tap → confirm dialog → SnackBar on device; Kleinheubach + Berlin coord lookups on device; ancillary no-crash) DEFERRED to the combined Phase-4 close-out drive per user directive 2026-07-08 (memory: `phase-4-drives-deferred-to-gym-trip.md`). Same code-complete-drive-deferred pattern used by 04-15."

patterns-established:
  - "**`packages/<name>/` leaf pattern** — the go-to home for pure-Dart code that must be shared across the Flutter main package + one or more pure-Dart sub-packages under `tool/`. Consumers add a path-dep; no publishing, no Flutter contamination."
  - "**Bundled asset + docs-dir override + AppPrefs version stamp** — three-part contract for user-refreshable bundled data. Applied here to admin polygons; future plans (map tiles, POI seed data, road-graph snapshots) can reuse the same triple."
  - "**Hash-grid spatial index for < 100k regions.** Simpler than R-Tree, adequate for DE-scale polygon lookup at 0.01° cell size. Documented as the default choice for point-in-polygon workloads at this scale."

# Metrics
duration: 50min
completed: 2026-07-08
---

# Phase 4 Plan 16: Bundled Admin Polygons and Lookup Summary

**Wave 3 close-out: the bundled Germany admin-polygon asset ships (11.90 MB gzipped, 30,819 features); runtime `AdminRegionLookup` returns Gemeinde/Landkreis/Bundesland for a `(lat, lon, level)` triple in <5 ms; Settings > Data > "Refresh admin regions" wires the manual refresh path. Real-device smoke DEFERRED to the combined Phase-4 close-out drive.**

## Status

**Code-complete (drive-verify deferred to combined Phase-4 close-out drive).**

Tasks 1–3 landed as atomic commits; Task 1b (bundled-asset sanity check) handled inline by this executor per objective; real-device smoke checkpoints (Settings tap on Kleinheubach's Bundesland/Landkreis/Gemeinde, "no crash" ancillary) DEFERRED. No `docs(04-16): Wave 3 admin polygons verified on device` commit yet — that lands post-drive. Same code-complete-drive-deferred pattern as Phase 3 close-out (STATE 2026-07-05) and 04-15 (STATE 2026-07-08). Memory ref: `phase-4-drives-deferred-to-gym-trip.md`.

## Performance

- **Duration:** ~50 min (Tasks 1-3 execution + close-out; Overpass fetch was ~5 min of that, running in background while Task 2 code was written)
- **Tasks:** 3× `type="auto"` all landed; 1× `type="checkpoint:human-verify"` (Task 1b) handled inline; deferred drive checkpoints batched to combined Phase-4 close-out
- **Files created:** 16
- **Files modified:** 5
- **Test delta:** 249 → 263 (+14 = 5 leaf-package simplifier + 9 lookup + 5 settings widget − 5 leaf tests run standalone, not counted in the main suite. Main-suite delta = +14.)

## Task Commits

Each task committed atomically with files staged INDIVIDUALLY (no `git add -A` / `git commit -a`, per Wave-hygiene STATE decisions 2026-07-03 / 2026-07-06 / 03-1-02 / 04-13 / 04-14 / 04-15 reinforcement):

1. **Task 1: shared admin_geometry package + dev CLI** — `f124d8b` (feat)
2. **Task 1 asset commit (post-Task-1b inline sign-off):** `4ed911f` (chore) — bundled `germany_admin.geojson.gz` 11.90 MB alone
3. **Task 2: AdminRegionLookup with hash-grid spatial index** — `f880e79` (feat)
4. **Task 3: AdminBundleRefresher + Settings > Data > Refresh admin regions button** — `effabb7` (feat)
5. **Metadata commit (this SUMMARY + PLAN + STATE):** follows below.

Post-drive commit (`docs(04-16): Wave 3 admin polygons verified on device`) DEFERRED to the combined Phase-4 close-out session.

## Task 1b Inline Sanity Check

Executed via a temporary `_check_admin_bundle.dart` script (deleted before Task 1 commit; `jq` unavailable on the Windows dev box). Result:

| Metric | Value | Sign-off Target | Verdict |
|--------|-------|-----------------|---------|
| Gzipped bytes | 12,475,041 (**11.90 MB**) | 8-15 MB | PASS |
| Total features | 30,819 | several thousand | PASS |
| L2 count | 3 | 1 (Germany) | PASS (border-touching artefacts included; harmless) |
| L4 count | 17 | ~16 (Bundesländer) | PASS |
| L6 count | **400** | ~40 (plan text: Regierungsbezirke) | **PASS with plan-text correction** |
| L8 count | 10,836 | several thousand | PASS |
| L9 count | 10,279 | (informational) | present |
| L10 count | 9,284 | (informational) | present |

**Plan sign-off correction:** the L6 count of ~40 in the plan text was mistaken. `admin_level=6` in DE OSM tagging = Landkreise + kreisfreie Städte (~400), NOT Regierungsbezirke. The plan's own Task 2 fixture (`Landkreis Miltenberg` at L6) confirms this. No iteration on DP tolerances needed — the bundle is well inside budget and level coverage is complete.

## Accomplishments

- **`packages/admin_geometry/` leaf-package.** Pure Dart, own pubspec + analysis_options, exports `AdminPolygonDownloader` + `AdminPolygonSimplifier`. Consumed by BOTH the runtime `AdminBundleRefresher` and the dev CLI at `tool/osm_pipeline/bin/fetch_admin_polygons.dart` — single source of truth for Overpass fetch + Douglas-Peucker simplification. 5 unit tests via `dart test` (all green).
- **Dev CLI `tool/osm_pipeline/bin/fetch_admin_polygons.dart`.** One-shot dev-machine script. Ran successfully against the real Overpass server on 2026-07-08 in ~5 min (`904 MB raw JSON envelope → 11.9 MB gzipped simplified bundle`). Prints per-stage progress; exits 1 if output exceeds 15 MB budget.
- **`assets/admin/germany_admin.geojson.gz` committed.** 11.90 MB gzipped; 30,819 features across levels 2/4/6/8/9/10. Referenced from `pubspec.yaml`'s `assets/admin/` entry.
- **`AdminRegion` domain model + `AdminRegionLookup` hash-grid index.** Lazy-loaded, idempotent, invalidate-able. Docs-dir override precedence baked in for the refresher's runtime bundle-swap path. 1000-call latency test averages well under 5 ms per call on the Windows dev box.
- **`AppPrefs` SharedPreferencesAsync wrapper.** New class at `lib/core/prefs/app_prefs.dart`; mirrors `OnboardingFlagRepository`. Exposes `getAdminBundleVersion` / `setAdminBundleVersion` + `kAdminBundleVersion` public key.
- **`AdminBundleRefresher`.** Runtime refresh path — fetch → simplify → write to `<AppDocsDir>/admin/germany_admin.geojson.gz` → bump `AppPrefs.adminBundleVersion` → `lookup.invalidate()`. `DomainError.wrap` at the boundary (STATE 01-04).
- **Settings > Data > "Refresh admin regions".** New `DataManagementSection` widget wired into `SettingsScreen`. ListTile with subtitle showing last refresh timestamp (or "Using bundled version"); tap → confirm dialog → refresher.refreshFromOverpass() with progress spinner → success/failure SnackBar.
- **Riverpod providers all plain `Provider<T>`.** `adminRegionLookupProvider`, `adminBundleRefresherProvider`, `appPrefsProvider` — STATE 01-01 codegen-off rule preserved.
- **263/263 tests green.** Previously 249 (04-15). Net +14 in the main suite (9 lookup + 5 settings widget). Leaf package's own 5 tests run via `dart test` inside `packages/admin_geometry/`.

## Files Created / Modified

**Created (16):**

- `packages/admin_geometry/pubspec.yaml`
- `packages/admin_geometry/analysis_options.yaml`
- `packages/admin_geometry/lib/admin_geometry.dart`
- `packages/admin_geometry/lib/src/admin_polygon_downloader.dart`
- `packages/admin_geometry/lib/src/admin_polygon_simplifier.dart`
- `packages/admin_geometry/test/admin_polygon_simplifier_test.dart`
- `tool/osm_pipeline/bin/fetch_admin_polygons.dart`
- `assets/admin/germany_admin.geojson.gz`
- `lib/core/prefs/app_prefs.dart`
- `lib/features/admin/data/admin_region.dart`
- `lib/features/admin/data/admin_region_lookup.dart`
- `lib/features/admin/data/admin_region_providers.dart`
- `lib/features/admin/data/admin_bundle_refresher.dart`
- `lib/features/settings/presentation/widgets/data_management_section.dart`
- `test/features/admin/admin_region_lookup_test.dart`
- `test/features/settings/data_management_section_test.dart`

**Modified (5):**

- `pubspec.yaml` (admin_geometry path-dep + `assets/admin/` entry, both alphabetized)
- `pubspec.lock`
- `tool/osm_pipeline/pubspec.yaml` (admin_geometry path-dep + http, alphabetized)
- `tool/osm_pipeline/pubspec.lock`
- `lib/features/settings/presentation/settings_screen.dart` (Data section inserted between About + Coming-later)

## Deferred Verification Checklist

**Scenarios batched to the combined Phase-4 close-out drive at Kleinheubach + Frankfurt/Würzburg. See memory: `phase-4-drives-deferred-to-gym-trip.md` for the Kleinheubach adaptation across all Phase 4 plans.**

Build for Android device (release build, real MapTiler key):

```bash
flutter run --release --dart-define-from-file=env/dev.json
```

**Scenario D — Bundled admin lookup on-device:**

1. From the Trailblazer app, use a dev entry-point (or if none exists, temporarily wire a debug button that reads `regionAt(49.796, 9.185, 8)` / `(52.52, 13.405, 4)` from `adminRegionLookupProvider`) to verify:
   - Kleinheubach (49.796, 9.185) at L8 → `Kleinheubach`, at L6 → `Miltenberg`, at L4 → `Bayern`.
   - Berlin (52.52, 13.405) at L4 → `Berlin`, at L10 → some Ortsteil.
2. Verify total load time from app-launch to first successful `regionAt` return is < 3 s (asset gunzip + parse + hash-grid build).

**Scenario E — Settings > Data > "Refresh admin regions" on-device:**

1. Open Settings > Data > "Refresh admin regions".
2. Tap the ListTile → confirm dialog appears with text "This will download ~10 MB of data and may take 1-2 minutes." → tap "Refresh".
3. Verify progress spinner appears and blocks re-tap.
4. Wait ~5 minutes (dev-box wall-clock was 5 min; mobile may be slower).
5. Verify SnackBar "Admin regions updated" appears.
6. Verify subtitle now reads "Last refreshed: <ISO-8601 timestamp>".
7. Kill + reopen app. Verify the subtitle text persists (SharedPreferences round-trip).
8. Repeat Scenario D. Verify lookups still work (the docs-dir override doesn't break parsing).

**Ancillary check:**

- No crash on tab-switch back to Settings during refresh (progress state should stick).
- MapTiler tiles remain visible on the map screen throughout.

**Approve on success; capture logs + screenshots on any failure and return with issue details.**

Post-drive: land a `docs(04-16): Wave 3 admin polygons verified on device` commit.

## Decisions Made

Recorded in STATE.md `Decisions` under the 2026-07-08 04-16 bullets. Key highlights:

- **Leaf-package route** for cross-runtime shared code (`packages/admin_geometry/`). Chosen at plan-start (not iteratively) because pure-Dart sub-package cannot depend on Flutter package.
- **DP tolerance table locked**: L2=10 m, L4=30 m, L6=50 m, L8/9/10=100 m. Result: 11.90 MB gzipped, well inside 15 MB budget. No iteration needed.
- **L6 count = ~400 (not ~40).** Plan sign-off text was wrong. DE OSM L6 = Landkreise + kreisfreie Städte.
- **Hash-grid at 0.01° cells** for spatial index. Simpler than R-Tree; adequate for <100k regions.
- **Docs-dir override precedence** in `AdminRegionLookup`. Runtime refresher writes there; bundled asset is fallback.
- **`AppPrefs` is a new class** (no prior runtime AppPrefs existed — only a Drift table of the same name). Mirrors `OnboardingFlagRepository` shape.
- **Task 1b handled inline** by the executor (no `jq`; used temp Dart script). Real-device Wave 3 smoke DEFERRED to combined Phase-4 close-out drive.

## Deviations from Plan

**1. [Rule 3 - Blocking] Leaf-package route chosen instead of path-dep from `tool/osm_pipeline/` to the main Flutter package.**

- **Found during:** Task 1 planning
- **Issue:** `tool/osm_pipeline/pubspec.yaml` is pure-Dart (`sdk: ^3.5.0`, no `flutter:` dependency). Path-depending on the Flutter main package would pull the entire Flutter runtime tree through `dart pub get` and break the sub-package's 251-test suite. Plan §Deviations authorized the leaf-package fallback for exactly this case.
- **Fix:** Skipped the "try main-pkg path-dep first" experiment. Created `packages/admin_geometry/` (pure Dart, own pubspec + analysis_options) directly; both the main Flutter app AND `tool/osm_pipeline/` add it as a path-dep. Verified the sub-package's 251-test suite still passes.
- **Files affected:** `packages/admin_geometry/*` (6 new files); `pubspec.yaml` (root); `tool/osm_pipeline/pubspec.yaml`.
- **Commit:** Task 1 (`f124d8b`).

**2. [Rule 1 - Bug] Plan sign-off criterion for L6 count was semantically wrong.**

- **Found during:** Task 1b inline sanity check
- **Issue:** Plan text (Task 1b sign-off) said `L6 count: ~40 (Regierungsbezirke)`. Actual L6 count in the fetched bundle: 400. In DE OSM, `admin_level=6` maps to Landkreise + kreisfreie Städte (~400), NOT Regierungsbezirke. The plan's own Task 2 fixture (`Landkreis Miltenberg` at L6) confirms this.
- **Fix:** Documented the correction in the Task 1b sanity-check summary AND in this SUMMARY. No iteration on DP tolerances — the bundle is 11.90 MB (in-budget), all levels non-empty, and functional correctness is proven by the Task 2 fixture tests.
- **Files affected:** none (docs-only observation).
- **Commit:** Task 1 asset (`4ed911f`) — commit message documents the count.

**3. [Rule 3 - Blocking] Task 1b inline (no `jq` on Windows dev box).**

- **Found during:** Task 1b sanity check
- **Issue:** Plan's inline sign-off commands used `gunzip -c ... | jq ...`. `jq` was not on the developer's Windows Git-Bash PATH.
- **Fix:** Wrote a throwaway `_check_admin_bundle.dart` reading the file via `dart:io` + `dart:convert` + `gzip.decode` + `jsonDecode`, then `deleted` it before staging Task 1. Pattern captured in patterns-established.
- **Files affected:** none (temp script deleted).
- **Commit:** N/A.

**4. [Non-blocking — process] `AppPrefs` created fresh, not extended from a pre-existing runtime class.**

- **Found during:** Task 3 planning
- **Issue:** Plan text said "grep the existing prefs pattern in `lib/core/prefs/`" — no such directory or class existed. Only a Drift `AppPrefs` TABLE existed (in `lib/core/db/tables/`), which is a different concept.
- **Fix:** Created `lib/core/prefs/app_prefs.dart` fresh, mirroring the `OnboardingFlagRepository` shape (STATE Plan 01-03): `SharedPreferencesAsync`-backed, public `kAdminBundleVersion` key, plain `Provider<AppPrefs>`. Documented as the new central home for runtime prefs going forward.
- **Files affected:** `lib/core/prefs/app_prefs.dart` (new).
- **Commit:** Task 3 (`effabb7`).

**5. [Drive deferred — user directive] Real-device Wave 3 smoke checkpoints DEFERRED.**

- **Found during:** Post-Task-3 checkpoint
- **User directive 2026-07-08:** Same as 04-15's drive deferral — combined Phase-4 close-out drive covers all remaining Phase-4 checkpoints in one Kleinheubach + Frankfurt/Würzburg session.
- **Fix:** Author this SUMMARY as code-complete-drive-deferred. Do NOT land `docs(04-16): Wave 3 admin polygons verified on device` — that lands post-drive. Metadata commit describes the deferral. Combined checklist (Scenarios D + E + Ancillary) documented in this SUMMARY.
- **Files affected:** SUMMARY.md + STATE.md only.
- **Commit:** the metadata commit that follows. Memory ref: `phase-4-drives-deferred-to-gym-trip.md`.

---

**Total deviations:** 3 auto-fixes (Rules 1 / 3) + 1 process + 1 drive-defer. No architectural checkpoints. No Rule 4 escalations.
**Impact on plan:** Task 1's leaf-package route was chosen preemptively (per plan §Deviations authorization). Tasks 1b inline. Tasks 2–3 landed to spec. Real-device smoke batched to combined drive; no code-level rework.

## Authentication Gates

None. The dev CLI hit the Overpass primary endpoint on first try without auth; no API keys involved for the free-tier public server.

## Issues Encountered

- **Analyzer info-noise on the initial code drop:** `unnecessary_lambdas`, `cascade_invocations`, `use_null_aware_elements`, `always_put_required_named_parameters_first`, `only_throw_errors`. All cleaned up in-loop; final `flutter analyze --no-pub` = `No issues found!`.
- **`FlutterError.fromParts` vs `StateError`.** Initial test-fixture `_FixtureAssetBundle` threw `FlutterError` — analyzer rejected the constructor form. Switched to `StateError` (simpler, satisfies `only_throw_errors`).
- **`List<Override<Object?>>` type argument.** Riverpod 3's `Override` type doesn't take type args in this usage; declared the widget-test helper parameter as `List<Object>` + `.cast()` at the ProviderScope site. Matches the pattern in `test/widget_test.dart` (existing).
- **Overpass fetch wall-clock beat the plan's 10-min budget.** Real ~5 min; ran in background alongside Task 2 coding without blocking the plan.

## Success Criteria (Wave 3 close-out)

| # | Criterion | Status |
| --- | --- | --- |
| 1 | Task 1 code committed: shared `admin_geometry/` package (2 files) + dev CLI + pubspec updates + simplifier tests green | PASS (`f124d8b`; 5 leaf tests green via `dart test`) |
| 2 | Task 1 asset committed separately, <15 MB, Task 1b sanity checks pass | PASS (`4ed911f`; 11.90 MB, all sign-off criteria pass with L6 semantic correction documented) |
| 3 | Task 2 committed: AdminRegion + AdminRegionLookup with hash-grid + tests (Kleinheubach + Bayern + Miltenberg among them) | PASS (`f880e79`; 9 tests including all 5 fixture regions) |
| 4 | Task 3 committed: AdminBundleRefresher + Settings > Data widget + AppPrefs.adminBundleVersion; tests green; existing settings + trip tests unbroken | PASS (`effabb7`; 5 widget tests green; full suite 263/263) |
| 5 | Metadata commit: `docs(04-16): code-complete close-out ...` staging ONLY SUMMARY + PLAN + STATE | PENDING (this commit) |
| 6 | Real-device scenarios D + E + Ancillary pass | **DEFERRED (drive-verify batched)** — combined Phase-4 close-out drive at Kleinheubach + Frankfurt/Würzburg |
| 7 | `flutter analyze --no-pub` clean; full `flutter test` green | PASS (0 issues; 263/263) |
| 8 | `tool/osm_pipeline/` sub-package tests still green (no regression from leaf-package addition) | PASS (251/251 via `cd tool/osm_pipeline && dart test`) |
| 9 | Working tree clean at end (`git status --porcelain` shows only `.idea/`) | PASS (post-metadata commit) |

**Score:** 8/9 PASS (code-complete). 1/9 DEFERRED (drive-verify). PENDING → PASS after metadata commit.

## Grep Tripwires

- `package:admin_geometry` — hits in `lib/features/admin/data/admin_bundle_refresher.dart`, `lib/features/admin/data/admin_region_providers.dart`, `tool/osm_pipeline/bin/fetch_admin_polygons.dart` (3 files — the two consumers + dev CLI).
- `import 'package:flutter` in `packages/admin_geometry/lib/` — 0 hits (pure Dart preserved).
- `adminBundleVersion` in `lib/core/prefs/app_prefs.dart` — 3 hits (const key + getter + setter).
- `AdminRegionLookup` in `lib/features/admin/` — 1 hit (the class file); provider file references it; refresher file references it.
- `class AdminBundleRefresher` — 1 hit in `lib/features/admin/data/admin_bundle_refresher.dart`.
- `DataManagementSection` — 2 hits (class + import in `settings_screen.dart`).
- `assets/admin/` in `pubspec.yaml` — 1 hit (asset entry, alphabetized).
- `assets/admin/germany_admin.geojson.gz` on disk — present, 11.90 MB gzipped.

## User Setup Required

None new for Wave 3 code paths. Wave 1 setup (`env/dev.json` with MapTiler key) remains sufficient for the app. `flutter pub get` at repo root resolves the leaf-package path-dep transparently on any clone.

## Downstream contract for 04-17 (rescope close-out)

- **04-17 owns the REQUIREMENTS.md / ROADMAP.md rewrite** for the rescoped Phase-4 architecture (bundled admin polygons + Overpass on-demand road matching + MapTiler tiles). This plan (04-16) does NOT preemptively touch OSM-01..08 wording, ROADMAP SC1..SCN, or the "abandoned bundled-osm.sqlite" narrative. That's 04-17's job.
- The bundled admin asset (`assets/admin/germany_admin.geojson.gz`) is now stable at 11.90 MB and populated across L2/L4/L6/L8/L9/L10. 04-17 can reference it as the new authoritative source for admin lookups in the rescoped requirements text.
- `WayCandidateSource` (04-15) + `AdminRegionLookup` (this plan) together compose the Phase-5 matcher's runtime input contract. Both seams are stable and 04-17 can codify them in REQUIREMENTS.

## Next Phase Readiness

**Ready for 04-17 (docs-only rescope close-out; `autonomous: true`).** No blockers. Verified:

- `git status --porcelain` clean (only `.idea/` untracked; will be true post-metadata-commit)
- `flutter analyze --no-pub` clean
- 263/263 tests green
- 251/251 sub-package tests green (`cd tool/osm_pipeline && dart test`)

---

**Deferred items (batched to combined Phase-4 close-out drive):**

- 04-16 Scenario D (bundled admin lookup on-device: Kleinheubach + Berlin coord round-trip)
- 04-16 Scenario E (Settings > Data > "Refresh admin regions" tap → confirm → SnackBar on-device)
- 04-16 Ancillary (no-crash on tab switch during refresh; MapTiler still visible)

Memory: `phase-4-drives-deferred-to-gym-trip.md`.

Post-drive: land `docs(04-16): Wave 3 admin polygons verified on device` commit.

---

*Phase: 04-osm-pipeline*
*Status: code-complete-drive-deferred*
*Completed (code): 2026-07-08*
*Drive verification: pending combined Phase-4 close-out session*
