---
phase: 10-coverage-recompute-region-totals
plan: 04
subsystem: regions
tags: [dart, flutter, riverpod, sqlite, gzip, regions, coverage, bundled-totals, refactor]

# Dependency graph
requires:
  - phase: 10-coverage-recompute-region-totals
    plan: 03
    provides: Stage H pipeline code (region_totals.json.gz emitter); asset deferred pending PBF

provides:
  - RegionTotalsLookup: off-isolate gzip loader for bundled per-region totals
  - coverage_cache.real_total_length_m populated from bundled table during recompute
  - Zero runtime Overpass calls for region totals (Decision 8)
  - No per-region spinner / pending state anywhere in the UI

affects:
  - 10-05: focus pill reads real_total_length_m from coverage_cache
  - future PBF run: drops assets/admin/region_totals.json.gz; loader picks it up at runtime

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Bundled-totals lookup: main-isolate bytes + compute() off-isolate parse (mirrors AdminRegionLookup)
    - Single-flight guard on RegionTotalsLookup._loading (same pattern as AdminRegionLookup)
    - StreamProvider-on-.watch() for reactive region browser (preserved; frozen-spinner fix)

key-files:
  created:
    - lib/features/regions/data/region_totals_lookup.dart
  modified:
    - lib/features/regions/data/coverage_compute_service.dart
    - lib/features/regions/data/coverage_compute_providers.dart
    - lib/features/coverage/data/coverage_cache_dao.dart
    - lib/features/regions/domain/region_coverage.dart
    - lib/features/regions/presentation/providers/region_browser_provider.dart
    - lib/features/regions/presentation/widgets/region_card.dart
    - lib/features/regions/presentation/widgets/region_detail_sheet.dart
    - lib/app.dart
    - test/features/regions/data/coverage_compute_service_test.dart
    - test/features/regions/presentation/region_browser_provider_test.dart
    - test/features/map/router_shell_test.dart
    - test/features/trips/trips_repository_inbox_extensions_test.dart
  deleted:
    - lib/features/regions/data/region_total_length_service.dart
    - lib/features/regions/domain/region_tiling.dart
    - test/features/regions/data/region_total_length_service_test.dart
    - test/features/regions/domain/region_tiling_test.dart

key-decisions:
  - "Decision 8 executed: runtime Overpass totals tiler replaced by bundled region_totals.json.gz lookup"
  - "pubspec assets/admin/ already declared as directory — no pubspec change needed"
  - "kCurrentSchemaVersion = 6 unchanged (no schema bump)"
  - "real_total_progress_json DB column left in place (no schema change; stop reading/writing from runtime)"

patterns-established:
  - "RegionTotalsLookup mirrors AdminRegionLookup posture exactly (bytes on main isolate, compute() off-isolate)"

# Metrics
duration: ~21min
completed: 2026-07-17
---

# Phase 10 Plan 04: Wire Bundled Totals + Delete Tiler Summary

**RegionTotalsLookup created (off-isolate gzip loader); recompute() now writes real_total_length_m from the bundled table; RegionTotalLengthService + region_tiling + spinner/progress UI deleted**

## Performance

- **Duration:** ~21 min
- **Started:** 2026-07-17T13:07:47Z
- **Completed:** 2026-07-17T13:09:19Z
- **Tasks:** 2/2 complete
- **Files created:** 1 | **Modified:** 12 | **Deleted:** 4

## Accomplishments

### Task 1: RegionTotalsLookup + populate coverage_cache

- Created `lib/features/regions/data/region_totals_lookup.dart` mirroring `AdminRegionLookup`'s load posture exactly: `rootBundle.load` bytes on main isolate → `compute()` off-isolate → `gzip.decode` → `utf8.decode` → `jsonDecode` → `Map<String,double>`. Lazy one-time load with single-flight guard. Exposes `totalFor(String osmId)` → O(1) lookup.
- `regionTotalsLookupProvider` plain `Provider<RegionTotalsLookup>` (no codegen).
- Injected `RegionTotalsLookup` into `CoverageComputeService`; `recompute()` now sets `real_total_length_m = totalsLookup.totalFor(regionId)` — the bundled value is authoritative for the displayed denominator, fixing Bayern==Miltenberg.
- Added optional `realTotalLengthM` param to `CoverageCacheDao.upsert()` (single write per row — no two-phase upsert needed).
- Removed `regionTotalLengthServiceProvider` from `coverage_compute_providers.dart`.
- Removed `_computeMissingRegionTotals()` from `app.dart` startup chain.
- Updated `coverage_compute_service_test.dart`: added `_FakeRegionTotalsLookup` + Tests 8+9 asserting `real_total_length_m` is populated from the bundled table (or written as null when absent).
- Fixed `router_shell_test.dart` (removed `_FakeRegionTotalLengthService` import/class/override).
- Fixed `trips_repository_inbox_extensions_test.dart` (`_NoopComputeService` now passes `totalsLookup`).
- **pubspec.yaml**: `assets/admin/` is already declared as a directory entry — no change needed. Confirmed explicitly.

### Task 2: Delete runtime Overpass totals path + spinner UI

- **DELETED** `lib/features/regions/data/region_total_length_service.dart` and its test.
- **DELETED** `lib/features/regions/domain/region_tiling.dart` and its test.
- `region_coverage.dart`: removed `totalPending`, `progressCellsDone`, `progressCellsPlanned` fields. No pending state — totals are instant from the bundle.
- `region_browser_provider.dart`: simplified `_buildRegionList` to use `real_total_length_m ?? total_length_m`; removed pending/progress logic; **PRESERVED** the `StreamProvider<List<CoverageCacheData>>` → `async*` join pattern (MEMORY: frozen-spinner bug was a one-shot FutureProvider; async*+yield* on raw stream HANGS in tests).
- `region_card.dart`: removed spinner + "N/M Kacheln" progress count. Always renders `percentLabel`.
- `region_detail_sheet.dart`: removed "wird berechnet …" spinner row and the `totalPending` branch in the km-stats row. Always renders `percentLabel` + full km stats.
- `region_browser_provider_test.dart`: updated the reactivity test to assert `totalLengthM` switches from haversine fallback to bundled real total on DB write (instead of asserting `totalPending` toggle).

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | RegionTotalsLookup + populate coverage_cache from bundled totals | `8b2bb8f` | region_totals_lookup.dart (new), coverage_compute_service.dart, coverage_compute_providers.dart, coverage_cache_dao.dart, app.dart, tests |
| 2 | Delete runtime Overpass totals path and spinner UI | `5c6d4d3` | region_coverage.dart, region_browser_provider.dart, region_card.dart, region_detail_sheet.dart, region_totals_lookup.dart (comment fix); deleted: region_total_length_service.dart, region_tiling.dart, tests |

## Deleted/Emptied Symbols

| Symbol | File | Status |
|--------|------|--------|
| `RegionTotalLengthService` | `region_total_length_service.dart` | FILE DELETED |
| `_Cell` | `region_total_length_service.dart` | FILE DELETED |
| `plannedCellCount()` | `region_tiling.dart` | FILE DELETED |
| `completedCellCount()` | `region_tiling.dart` | FILE DELETED |
| `kRegionTileDegrees` | `region_tiling.dart` | FILE DELETED |
| `kRegionProgressBlobVersion` | `region_tiling.dart` | FILE DELETED |
| `regionTotalLengthServiceProvider` | `coverage_compute_providers.dart` | REMOVED |
| `_computeMissingRegionTotals()` | `app.dart` | REMOVED |
| `RegionCoverage.totalPending` | `region_coverage.dart` | FIELD REMOVED |
| `RegionCoverage.progressCellsDone` | `region_coverage.dart` | FIELD REMOVED |
| `RegionCoverage.progressCellsPlanned` | `region_coverage.dart` | FIELD REMOVED |

## Schema Change Confirmation

**NO schema change.** `kCurrentSchemaVersion = 6` in `drift_backup_service.dart` — unchanged. The `real_total_progress_json` DB column is left in place (no schema bump); it is no longer read or written from the runtime path. The `real_total_length_m` column (already in schema v5) is now written by `recompute()` via the existing `upsert()` method.

## Deferred Data Dependency

`assets/admin/region_totals.json.gz` is a **deferred data dependency**. The physical file does not exist on the dev machine — its generation requires `germany-latest.osm.pbf` which is absent (see 10-03-SUMMARY.md checkpoint).

**What happens without the asset:**
- `RegionTotalsLookup.ensureLoaded()` catches the `FlutterError` from `rootBundle.load` gracefully and leaves `_totals` null.
- `totalFor()` returns null for all region IDs.
- `recompute()` writes `real_total_length_m = null` for all rows.
- `region_browser_provider` falls back to `total_length_m` (haversine sum of fetched ways near trips) as the denominator — correct lower bound, understates true total for large regions.
- Region card shows `percentLabel` based on haversine total (same as pre-Phase-10 behavior).

**When the asset arrives (deferred PBF checkpoint from 10-03):**
- Drop `assets/admin/region_totals.json.gz` into the `assets/admin/` directory.
- Next recompute triggers load (or app restart + recompute): `RegionTotalsLookup` parses the file and populates the map.
- `real_total_length_m` is written correctly for all regions, including Bundesländer.
- **Zero code change required.** The loader, provider, and DAO are all in place.

## pubspec.yaml Change

**NO CHANGE.** `assets/admin/` was already declared as a directory entry in `pubspec.yaml` (confirmed at line 83). No explicit filename entry added (an explicit missing-file entry would fail `flutter pub get`/build).

## Test Results

- `flutter analyze`: **No issues found**
- `flutter test`: **881/881 tests passed** (893 baseline − 14 deleted tests + 2 new = 881)
  - Deleted: 5 `region_total_length_service_test.dart` + 9 `region_tiling_test.dart` = 14
  - Added: Tests 8+9 in `coverage_compute_service_test.dart` = 2

## Deviations from Plan

### Auto-fix: app.dart removal triggered by Task 1's provider deletion

**Rule 3 (Blocking):** Removing `regionTotalLengthServiceProvider` from `coverage_compute_providers.dart` (Task 1) immediately broke `app.dart` which called `ref.read(regionTotalLengthServiceProvider).computeMissingTotals()`. This was classified as a Task 2 deletion, but was required for `flutter analyze` to be clean after the Task 1 commit. Applied within Task 1's commit scope.

**Rule 3 (Blocking):** `router_shell_test.dart` had `regionTotalLengthServiceProvider.overrideWithValue(_FakeRegionTotalLengthService())` — also broken immediately. Fixed in Task 1's scope.

### No other deviations

- Tasks executed exactly as specified.
- No architectural changes.
- No schema bump.
- No new deps.

---

*Phase: 10-coverage-recompute-region-totals*
*Completed: 2026-07-17 (code-complete; region_totals.json.gz data deferred pending PBF download)*
