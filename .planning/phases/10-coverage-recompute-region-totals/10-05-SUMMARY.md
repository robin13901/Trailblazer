---
phase: 10-coverage-recompute-region-totals
plan: 05
subsystem: regions
tags: [dart, flutter, riverpod, sqlite, regions, coverage, recompute, performance]

# Dependency graph
requires:
  - phase: 10-coverage-recompute-region-totals
    plan: 04
    provides: recompute() writes real_total_length_m from bundled table; RegionTotalsLookup

provides:
  - RecalculateCoverageAction: orchestrates rematch + recompute with progress signal
  - RecalculateButton: "Regionen neu berechnen" confirmation-gated button at Regions-tab top
  - Auto recompute-only seam: recomputeForTrip() fires after intervals land in TripMatchCoordinator
  - Incremental auto-recompute (OQ1-PERF landed): targeted upsert for trip bbox only, no deleteAll

affects:
  - future phases: regions tab now self-serviceable; button + auto-seam keep coverage_cache fresh

# Tech tracking
tech-stack:
  added: []
  patterns:
    - ValueNotifier<RecalculateProgress> sealed-class progress signal (not Riverpod state)
    - OnIntervalsLandedCallback seam: coordinator stays Riverpod-free; wired at provider construction
    - Re-entrancy guard with _recomputeInFlight bool (debounce vs queue)
    - Incremental targeted upsert via 5-point bbox probe (reuses CoverageInvalidator pattern)

key-files:
  created:
    - lib/features/regions/data/recalculate_coverage_action.dart
    - lib/features/regions/presentation/widgets/recalculate_button.dart
    - test/features/regions/presentation/recalculate_button_test.dart
  modified:
    - lib/features/regions/presentation/regions_screen.dart
    - lib/features/matching/data/trip_match_coordinator.dart
    - lib/features/matching/data/matching_providers.dart
    - lib/features/regions/data/coverage_compute_service.dart
    - test/features/matching/data/trip_match_coordinator_test.dart
    - test/features/regions/data/coverage_compute_service_test.dart

key-decisions:
  - "OnIntervalsLandedCallback seam chosen over injecting CoverageComputeService directly into TripMatchCoordinator (keeps coordinator Riverpod-free and testable)"
  - "Auto path uses recomputeForTrip() (incremental, targeted) not full recompute() (Decision 6 + OQ1-PERF win)"
  - "Button path retains full deleteAll+recompute for correctness guarantee"
  - "Re-entrancy: simple _recomputeInFlight bool (debounce, not queue) — second event skipped, not buffered"

patterns-established:
  - "Incremental region upsert: 5-point bbox probe → affected region IDs → upsert only those rows"

# Metrics
duration: ~23min
completed: 2026-07-17
---

# Phase 10 Plan 05: Recompute Button + Auto Seam + Perf Summary

**RecalculateCoverageAction + RecalculateButton at Regions-tab top; auto recompute-only seam in TripMatchCoordinator; incremental recomputeForTrip() (OQ1-PERF win) landed**

## Performance

- **Duration:** ~23 min
- **Started:** 2026-07-17T13:16:05Z
- **Completed:** 2026-07-17T13:39:11Z
- **Tasks:** 3/3 complete
- **Files created:** 3 | **Modified:** 6
- **Tests:** 891 total (was 881; +10 new)

## Accomplishments

### Task 1: Recalculate action + confirmation-gated button

- **`recalculate_coverage_action.dart`**: plain class + `Provider<RecalculateCoverageAction>`. Exposes `Future<Result<int>> run()` which: (1) `TripMatchCoordinator.rematchAllStoredTrips()` over ALL stored trips (no deletion), (2) `CoverageComputeService.recompute()` (rebuilds region rows from freshly-matched intervals), (3) bundled totals populated inside `recompute()` from `RegionTotalsLookup` (10-04) — no extra Overpass call. Progress signal via `ValueNotifier<RecalculateProgress>` sealed class (`idle → rematching(N/M) → recomputing → done/error`). Never throws.
- **`recalculate_button.dart`**: `ConsumerWidget` + `ValueListenableBuilder` (no `ConsumerStatefulWidget` needed). Confirmation `AlertDialog` (reusing `DataManagementSection` confirm-dialog pattern). Spinner + progress label while running. Snackbar on success/error. Disabled while running. `OutlinedButton.icon` with Liquid-Glass-consistent theming.
- **`regions_screen.dart`**: `RecalculateButton` inserted as first `Column` child inside `SafeArea` (above `_SearchField` + `Divider` + `Expanded(_BrowserBody)`).
- **5 widget tests**: idle label renders, dialog appears on tap, cancel no-op, confirm invokes `run()` and snackbar shows, widget present in tree.

### Task 2: Auto recompute-only hook in TripMatchCoordinator

- Added `OnIntervalsLandedCallback` typedef (plain function, no Riverpod coupling).
- `TripMatchCoordinator` constructor gets optional `onIntervalsLanded` param; `_recomputeInFlight` bool guards re-entrancy.
- `_writeIntervals` calls `_triggerAutoRecompute(tripId)` after batch insert. `_triggerAutoRecompute` uses `unawaited(Future(...))` with try/finally to clear the in-flight guard.
- `matching_providers.dart`: `tripMatchCoordinatorProvider` wires `onIntervalsLanded` to `recomputeForTrip(tripId)` fire-and-forget (see Task 3). `Logger('matching_providers')` logs ok/err.
- **3 new coordinator tests**: callback fires after intervals (test 8), not when empty intervals (test 9), re-entrancy debounces second call to exactly 1 invocation (test 10).

### Task 3: OQ1-PERF — Incremental auto-recompute landed

- **`CoverageComputeService.recomputeForTrip(int tripId)`**: incremental targeted upsert for auto path.
  - Loads trip bbox from DB.
  - 5-point probe (corners + centre) → affected `regionIds` (same algorithm as `CoverageInvalidator`).
  - Fetches ways ONLY in trip bbox (not full union bbox — key speedup for short drives).
  - Reads ALL intervals (cumulative driven totals correct across trips).
  - Upserts only affected region rows — **no `deleteAll`** (other regions untouched, preserved).
  - Returns `Ok(0)` for null-bbox trips.
- **Auto path in `matching_providers`** now uses `recomputeForTrip(tripId)` instead of full `recompute()`.
- **Button path** retains full `deleteAll + upsert-all` in `RecalculateCoverageAction.run()` — correctness guaranteed.
- **2 new service tests**: test 10 (incremental == full recompute for single trip), test 11 (null bbox → Ok(0)).

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Regionen neu berechnen button + recalculate action | `c9d1f62` | recalculate_coverage_action.dart (new), recalculate_button.dart (new), regions_screen.dart, recalculate_button_test.dart (new) |
| 2 | Auto recompute-only hook when intervals land | `129eb77` | trip_match_coordinator.dart, matching_providers.dart, trip_match_coordinator_test.dart |
| 3 | Incremental auto-recompute + OQ1-PERF findings | `68ff793` | coverage_compute_service.dart, matching_providers.dart, coverage_compute_service_test.dart |

## OQ1-PERF: Shipped vs Deferred

### Shipped

| Win | Where | Details |
|-----|-------|---------|
| Incremental recompute (auto path) | `recomputeForTrip()` | 5-point bbox probe → targeted upsert for trip-touched regions only; no deleteAll; way-fetch restricted to trip bbox |
| Re-entrancy guard | `_recomputeInFlight` bool | Debounces rapid interval writes; second auto-recompute skipped, not queued |
| Warm MatcherIsolate (confirmed, no work needed) | `MatcherIsolate._isolate.start()` is idempotent | `rematchAllStoredTrips()` calls `start()` once before the loop; isolate stays warm across N trips — no per-trip spawn cost |
| Overpass tile cache across trips in same bbox | `OverpassWayCandidateSource` | Cache-first via `OverpassWayCacheDao`; overlapping-bbox trips share the cached tiles — no re-download |

### Deferred

| Deferred Win | Why | Deferred To |
|---|---|---|
| Cross-trip warm R-Tree reuse in button path | `MatcherIsolate` spawns a fresh worker per `start()` call if already disposed; R-Tree is rebuilt per trip from the cached tile bytes. Sharing a warm R-Tree across N trips in `rematchAllStoredTrips()` would require a new isolate API (e.g. persistent-session mode). Low priority at current trip counts (< 20 trips = seconds, not minutes). | Future phase if button becomes noticeably slow |
| Progressive progress reporting for button | `rematchAllStoredTrips()` returns total matched count only after all trips complete; per-trip progress would need a callback. The current "N/M Trips: done/done" state shown after the batch completes is acceptable. | Future phase |

## Deferred On-Device Confirmation

The end-to-end device confirm — "tap Regionen neu berechnen → Bayern / Landkreis Miltenberg / Miltenberg-town / Kleinheubach appear with correct driven-km" — is deferred to the next drive per project convention (device confirmations are batched, see `defer-in-car-verification.md`).

**Expected behavior when confirmed on-device:**
- Tap button → dialog with "Neu berechnen" CTA.
- Confirm → spinner + "Fahrten werden abgeglichen …" while rematch runs.
- Spinner transitions to "Regionen werden berechnet …" during recompute.
- Snackbar "N Regionen aktualisiert" appears.
- Regions tab immediately shows Bayern (L4), Landkreis Miltenberg (L6), Miltenberg-town (L8), Kleinheubach (L8) with correct driven km.

**Deferred data dependency:** `assets/admin/region_totals.json.gz` (from 10-03 PBF checkpoint) is not yet present. Without it, `real_total_length_m` is null → region browser falls back to haversine total as denominator (correct lower bound). When the asset is present, denominator is the full bundled road-network total. Zero code change required — loader is in place (10-04).

## Test Results

- `flutter analyze`: **No issues found**
- `flutter test`: **891/891 tests passed** (881 baseline + 10 new)
  - +5: `recalculate_button_test.dart` (widget tests)
  - +3: `trip_match_coordinator_test.dart` (tests 8, 9, 10)
  - +2: `coverage_compute_service_test.dart` (tests 10, 11)

## Deviations from Plan

### None

Plan executed exactly as specified. All three tasks landed. Task 3 (OQ1-PERF) shipped both the incremental `recomputeForTrip` path AND the deferred documentation — no gold-plating.

---

*Phase: 10-coverage-recompute-region-totals*
*Completed: 2026-07-17 (code-complete; on-device confirm deferred to next drive)*
