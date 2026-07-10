---
phase: 08-regions-focus-area
plan: 05
subsystem: ui
tags: [flutter, riverpod, drift, region-browser, liquid-glass, maplibre]

# Dependency graph
requires:
  - phase: 08-01
    provides: RegionCoverage value type + coveragePercent/formatPercent
  - phase: 08-02
    provides: CoverageComputeService + CoverageCacheDao.getAllWithCoverage()
  - phase: 04-16
    provides: AdminRegionLookup with regionAt + bundle parsing
provides:
  - RegionLevelBadge + levelLabel() shared widget helpers (region_card.dart)
  - RegionCard: flat card with level tag + name + % + km stats
  - showRegionDetailSheet: draggable Liquid Glass bottom sheet; stats-only + Jump-to-map
  - regionBrowserProvider: FutureProvider coverage-gated list, %-desc, level 2 excluded
  - regionSearchQueryProvider: NotifierProvider<String> search text
  - regionBrowserFilteredProvider: ranked fuzzy search (starts-with > contains)
  - RegionsScreen: replaced stub with searchable lazy ListView.builder
  - AdminRegionLookup.regionByOsmId(): reverse lookup additive method
affects: [08-06, 09-vehicles]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "NotifierProvider<String> for search query state (StateProvider removed in Riverpod 3.x)"
    - "FutureProvider joining DB rows with in-memory AdminRegionLookup"
    - "ref.listenManual for off-tab controller await in Jump-to-map"
    - "StatefulNavigationShell.maybeOf(context) for nullable shell access"
    - "0-dim guard LayoutBuilder in DraggableScrollableSheet (mirrors GlassPill)"

key-files:
  created:
    - lib/features/regions/presentation/providers/region_browser_provider.dart
    - lib/features/regions/presentation/widgets/region_card.dart
    - lib/features/regions/presentation/widgets/region_detail_sheet.dart
    - test/features/regions/presentation/region_browser_provider_test.dart
    - test/features/regions/presentation/regions_screen_test.dart
  modified:
    - lib/features/admin/data/admin_region_lookup.dart
    - lib/features/regions/presentation/regions_screen.dart

key-decisions:
  - "NotifierProvider<String> used for search query (StateProvider not in flutter_riverpod 3.x)"
  - "StatefulNavigationShell.maybeOf() preferred over .of() to avoid null-safety analyzer warning"
  - "regionByOsmId added as additive linear scan — consistent with existing regionAt memory posture"
  - "Level 2 excluded from browser (same reason as CoverageComputeService — accumulates whole DE road network)"
  - "DraggableScrollableSheet expand:false default used (minChildSize 0.25 is default)"
  - "levelLabel() and RegionLevelBadge are public — reused by both RegionCard and RegionDetailSheet"

patterns-established:
  - "FutureProvider + derived Provider<List<T>> filter pattern: load full list once, apply sync filter on top"
  - "ref.listenManual + sub?.close() for one-shot async observation in void callbacks"

# Metrics
duration: 16min
completed: 2026-07-11
---

# Phase 8 Plan 05: Region Browser + Detail Sheet Summary

**Flat coverage-gated card list (any admin level, %-desc) with fuzzy search and a draggable Liquid Glass stats-only detail sheet + Jump-to-on-map camera animation.**

## Performance

- **Duration:** ~16 min
- **Started:** 2026-07-10T23:14:04Z
- **Completed:** 2026-07-10T23:30:25Z
- **Tasks:** 3/3 completed
- **Files modified:** 7 (5 created, 2 modified)

## Accomplishments

- Replaced the `RegionsScreen` placeholder with a searchable lazy `ListView.builder` of `RegionCard` widgets — one card per region with coverage > 0%, any admin level mixed, sorted %-descending
- Built the first `DraggableScrollableSheet` in the app; it acts as a stats-only glass detail sheet (name + level tag + % + km stats, NO breadcrumb/ways/trips), with a "Jump to map" button that uses `ref.listenManual` to await the `mapControllerProvider` after tab switch and calls `animateCamera(newLatLngBounds(...))`
- Added `regionByOsmId(int osmId)` reverse lookup to `AdminRegionLookup` (additive, no existing method changed)
- Three-provider browser stack: `regionBrowserProvider` (FutureProvider, DB join), `regionSearchQueryProvider` (NotifierProvider), `regionBrowserFilteredProvider` (derived sync Provider with ranked fuzzy search)

## Task Commits

1. **Task 1: AdminRegionLookup reverse-by-osmId + regionBrowserProvider** - `ab2b3ef` (feat)
2. **Task 2: RegionCard + RegionDetailSheet** - `cf25217` (feat)
3. **Task 3: RegionsScreen + tests** - `498a8ce` (feat)

## Files Created/Modified

- `lib/features/admin/data/admin_region_lookup.dart` — added `regionByOsmId(int)` additive reverse lookup
- `lib/features/regions/presentation/providers/region_browser_provider.dart` — three providers (browser, search query, filtered)
- `lib/features/regions/presentation/widgets/region_card.dart` — `RegionCard`, `RegionLevelBadge`, `levelLabel()`
- `lib/features/regions/presentation/widgets/region_detail_sheet.dart` — `showRegionDetailSheet()`, `_RegionDetailContent`, jump-to-map pattern
- `lib/features/regions/presentation/regions_screen.dart` — replaced placeholder; search + lazy list
- `test/features/regions/presentation/region_browser_provider_test.dart` — 2 tests (%-desc sort, level-2 exclusion, fuzzy rank)
- `test/features/regions/presentation/regions_screen_test.dart` — 4 smoke tests (render, filter, empty states)

## Decisions Made

- **NotifierProvider for search query**: `StateProvider<String>` was removed in `flutter_riverpod` 3.x. Used `NotifierProvider<SearchQueryNotifier, String>` with a getter/setter pair following the `MapControllerNotifier` pattern (STATE Plan 02-03 decision).
- **`StatefulNavigationShell.maybeOf()`**: The non-null `.of()` triggered a "null comparison always true" analyzer warning. Used `.maybeOf()` which returns nullable, matching the plan's "if not reachable, context.go('/')" fallback.
- **0-dim guard preserved**: `LayoutBuilder` that returns `SizedBox.shrink()` when `maxWidth <= 0 || maxHeight <= 0` — mirrors `glass_pill.dart:41-48` to prevent `liquid_glass_renderer` crash.
- **Level 2 excluded from browser**: Consistent with `kComputeAdminLevels = [4,6,8,9,10]` in CoverageComputeService — a whole-Germany card is not useful.
- **`levelLabel()` and `RegionLevelBadge` public**: Both widgets needed the label; public helpers eliminate duplication.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] StateProvider unavailable in flutter_riverpod 3.x**

- **Found during:** Task 1 (region_browser_provider.dart)
- **Issue:** Plan specified `StateProvider<String>` which does not exist in `flutter_riverpod ^3.3.2`
- **Fix:** Used `NotifierProvider<SearchQueryNotifier, String>` with getter/setter pair matching the existing project pattern
- **Files modified:** `lib/features/regions/presentation/providers/region_browser_provider.dart`
- **Committed in:** `ab2b3ef`

**2. [Rule 1 - Bug] StatefulNavigationShell.of() returns non-null, null-check always true**

- **Found during:** Task 2 (region_detail_sheet.dart)
- **Issue:** Plan said to use `StatefulNavigationShell.of(context)?.goBranch(0)` but `.of()` returns `StatefulNavigationShellState` (non-nullable). Analyzer flagged as "null comparison always true" + dead code for the else branch.
- **Fix:** Changed to `StatefulNavigationShell.maybeOf(context)` which returns the nullable version, matching plan intent ("If not reachable, context.go('/')")
- **Files modified:** `lib/features/regions/presentation/widgets/region_detail_sheet.dart`
- **Committed in:** `cf25217`

**3. [Rule 1 - Bug] DraggableScrollableSheet `expand: false` is the default**

- **Found during:** Task 2 analyze
- **Issue:** `expand: false` was explicitly set but it is the default value; `avoid_redundant_argument_values` lint fires
- **Fix:** Removed redundant argument
- **Committed in:** `cf25217`
