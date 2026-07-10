---
phase: 08-regions-focus-area
plan: 04
subsystem: ui
tags: [flutter, riverpod, dart-async, focus-pill, live-camera, admin-region, coverage-cache, glass-pill, debounce]

# Dependency graph
requires:
  - phase: 08-01
    provides: ZoomLevelMapper (zoomToAdminLevel, fallbackLevelsFrom), RegionCoverage value type (coveragePercent, formatPercent)
  - phase: 08-02
    provides: CoverageComputeService + coverage_cache populated; CoverageCacheDao.getByRegionId
  - phase: 08-03
    provides: liveCameraProvider (NotifierProvider<LiveCamera?>), LiveCamera value class
  - phase: 04-16
    provides: AdminRegionLookup (regionAt, ensureLoaded), adminRegionLookupProvider
  - phase: 06-01
    provides: CoverageCacheDao, coverageCacheDaoProvider
provides:
  - focusPillProvider (NotifierProvider<FocusPillNotifier, FocusPillState>) — debounced live camera -> region + coverage %
  - FocusPillState immutable value type (name, percentLabel, hasValue)
  - FocusAreaPill ConsumerWidget — live two-line pill: name over %, GlassPill preserved, hold-last-value
  - Provider unit tests (5) — resolve, fallback, hold-last-value, no-cache-row, initial-blank
  - Widget tests (4) — seeded/empty/fallback/null-percent renders correctly
affects: [08-05, 09-vehicles, future-per-vehicle-coverage]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - ref.listen pattern for hold-last-value (state never reset on camera change)
    - Monotonically increasing _requestId to guard out-of-order async resolves
    - 150ms trailing debounce via dart:async Timer stored in Notifier field
    - FocusPillNotifier subclassing in tests (extends FocusPillNotifier, not Notifier<FocusPillState>)
    - Read provider before camera push in unit tests to ensure lazy Notifier.build() runs

key-files:
  created:
    - lib/features/regions/presentation/providers/focus_pill_provider.dart
    - test/features/regions/presentation/focus_pill_provider_test.dart
    - test/features/map/focus_area_pill_test.dart
  modified:
    - lib/features/map/presentation/widgets/focus_area_pill.dart
    - test/features/map/router_shell_test.dart
    - test/features/coverage/coverage_invalidator_test.dart
    - test/features/regions/data/coverage_compute_service_test.dart
    - test/features/trips/trip_place_lookup_test.dart
    - test/features/trips/trips_repository_inbox_extensions_test.dart

key-decisions:
  - "150ms trailing debounce chosen: fast enough for live feel on smooth pan, long enough to coalesce rapid touch-move events"
  - "ref.listen (not ref.watch) in Notifier.build() preserves hold-last-value — state is never reset on camera change"
  - "Monotonically increasing _requestId guards out-of-order resolves on rapid pans"
  - "FocusAreaPill shows Standort/—% placeholder until first resolve (never blank, never hits GlassPill 0-dim guard)"
  - "No tap handler in FocusAreaPill — 08-05 wires it without file collision"

patterns-established:
  - "Lazy Notifier init in unit tests: c.read(provider) before camera push to register ref.listen"
  - "FocusPillNotifier subclassing for fixed-state test doubles"

# Metrics
duration: 21min
completed: 2026-07-11
---

# Phase 8 Plan 04: Focus Pill Provider + Widget Summary

**Live two-line FocusAreaPill (name over %) watching liveCameraProvider via 150ms trailing debounce, fallback chain across admin levels, hold-last-value anti-flicker, proven by 9 tests**

## Performance

- **Duration:** 21 min
- **Started:** 2026-07-10T23:10:14Z
- **Completed:** 2026-07-11T00:31:00Z
- **Tasks:** 3
- **Files modified:** 9

## Accomplishments

- `FocusPillState` immutable value type with `name`, `percentLabel`, `hasValue`
- `FocusPillNotifier` with 150ms trailing debounce via `dart:async Timer`, `ref.listen` (hold-last-value), fallback chain via `fallbackLevelsFrom(zoom)`, coverage cache PK point-read, monotonic `_requestId` out-of-order guard
- `FocusAreaPill` replaced from StatelessWidget stub to live `ConsumerWidget` — two centered lines (name w600 + % onSurface 80% alpha) inside `GlassPill`, `withValues(alpha:)`, `Standort`/`—%` placeholder, no tap handler
- 5 provider unit tests (in-memory Drift DB + fake lookup): initial blank, resolve+percent, fallback chain, hold-last-value, no-cache-row
- 4 widget tests: seeded state, empty state placeholder, GlassPillFallback path, null percentLabel

## Task Commits

Each task was committed atomically:

1. **Task 1: focusPillProvider** - `6b07185` (feat)
2. **Task 2: FocusAreaPill ConsumerWidget** - `457f4d1` (feat)
3. **Task 3: tests + Rule-3 fakes fix** - `f68e714` (test)

**Rule 3 fixes (committed with Task 3):**
- `393c8d9` — router_shell_test updated for 08-05's live RegionsScreen (fix)

## Files Created/Modified

- `lib/features/regions/presentation/providers/focus_pill_provider.dart` — FocusPillState + FocusPillNotifier + focusPillProvider
- `lib/features/map/presentation/widgets/focus_area_pill.dart` — replaced stub with live ConsumerWidget
- `test/features/regions/presentation/focus_pill_provider_test.dart` — 5 provider unit tests
- `test/features/map/focus_area_pill_test.dart` — 4 widget tests
- `test/features/map/router_shell_test.dart` — updated for live RegionsScreen (08-05 compatibility)
- `test/features/coverage/coverage_invalidator_test.dart` — added regionByOsmId to fake
- `test/features/regions/data/coverage_compute_service_test.dart` — added regionByOsmId to fake
- `test/features/trips/trip_place_lookup_test.dart` — added regionByOsmId to fake
- `test/features/trips/trips_repository_inbox_extensions_test.dart` — added regionByOsmId to fake

## Decisions Made

- **150ms debounce:** Open per CONTEXT.md; 150ms chosen as the sweet spot — fast enough for live feel on smooth pan, long enough to coalesce rapid touch-move events without excessive region lookups.
- **`ref.listen` not `ref.watch`:** Using `ref.watch(liveCameraProvider)` would return the current value but NOT set up a listener that fires between builds. `ref.listen` fires on every change and is the correct pattern for side-effects (starting a timer) in `Notifier.build()`.
- **No tap handler in FocusAreaPill:** Plan explicitly defers tap-to-sheet to 08-05 to avoid file collision in the parallel wave. GestureDetector not added.
- **`_requestId` guard:** Simple monotonic int avoids needing a Completer/CancelToken. A slow 08-02 re-compute + fast pan sequence cannot cause the pill to flash an old region name.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added `regionByOsmId` to 4 pre-existing test fakes**

- **Found during:** Task 3 analysis (full `flutter analyze`)
- **Issue:** Wave-1 (08-05) added `regionByOsmId()` to `AdminRegionLookup` but 4 older test fakes implementing the interface were not updated. Full analyze reported 4 errors (`non_abstract_class_inherits_abstract_member`).
- **Fix:** Added `@override AdminRegion? regionByOsmId(int osmId)` returning null (or searching `byLevel` map for the invalidator test's lookup).
- **Files modified:** `test/features/coverage/coverage_invalidator_test.dart`, `test/features/regions/data/coverage_compute_service_test.dart`, `test/features/trips/trip_place_lookup_test.dart`, `test/features/trips/trips_repository_inbox_extensions_test.dart`
- **Verification:** `flutter analyze` clean; affected test files re-analyzed individually before commit.
- **Committed in:** `f68e714` (Task 3 commit)

**2. [Rule 3 - Blocking] Fixed `router_shell_test.dart` for 08-05's live RegionsScreen**

- **Found during:** Task 3 test run (`test/features/map` suite)
- **Issue:** `router_shell_test.dart` asserted old placeholder text `'Regions browser comes in Phase 8.'` which 08-05's commit had replaced with a live `ConsumerWidget`. The `pumpAndSettle` timed out because `regionBrowserProvider` loads the 12 MB admin asset bundle in headless test.
- **Fix:** Added `regionBrowserProvider.overrideWith((_) async => const [])` to `pumpAppAtMapShell`, updated assertion to the live empty-state message.
- **Files modified:** `test/features/map/router_shell_test.dart`
- **Verification:** `router_shell_test.dart` all 5 tests pass.
- **Committed in:** `393c8d9` (separate fix commit)

---

**Total deviations:** 2 auto-fixed (both Rule 3 - blocking)
**Impact on plan:** Both fixes essential for clean analyze + passing test suite. No scope creep. Both caused by parallel-wave 08-05 activity (regionByOsmId addition + RegionsScreen replacement) rather than 08-04 code issues.

## Issues Encountered

- `_FixedFocusPillNotifier extends Notifier<FocusPillState>` type error in widget test — fix: extend `FocusPillNotifier` so the closure matches the provider's type constraint.
- Lazy Notifier init: `ref.listen` only registers after `Notifier.build()` runs; test must call `c.read(focusPillProvider)` before pushing camera updates. Documented in helper function.

## Next Phase Readiness

- `focusPillProvider` is live and watched by `FocusAreaPill` — the map now shows a live two-line pill during movement.
- 08-05 can wire the pill tap to the detail sheet directly (no changes to `focus_area_pill.dart` needed — pill has no tap handler, clean extension point).
- Phase 9 (per-vehicle coverage) can add a `vehicleId` parameter to `_resolve()` without touching the public API.

---
*Phase: 08-regions-focus-area*
*Completed: 2026-07-11*
