---
phase: 07-coverage-rendering
plan: 03
subsystem: coverage
tags: [dart, flutter, drift, riverpod, maplibre, overpass, coverage, reactive]

requires:
  - phase: 07-01
    provides: classifyCoverage, CoverageDatum, drivenLengthMeters, interval_union
  - phase: 06-01
    provides: DrivenWayIntervalsDao, interval schema, CoverageCacheDao
  - phase: 04-15
    provides: WayCandidateSource, OverpassWayCandidateSource, WayCandidate
  - phase: 03-01
    provides: TripsDao, AppDatabase, trip status lifecycle

provides:
  - DrivenWayIntervalsDao.getAllIntervals() + getDistinctWayIds() (way-centric read)
  - CoverageWay immutable (wayId + geometry + datum)
  - CoverageOverlayData collection with .empty sentinel
  - DrivenWayGeometryResolver.resolve(LatLngBounds) — RESEARCH open-Q1 closed
  - TripsDao.watchUnionBbox() — reactive Drift stream, readsFrom trips+drivenWayIntervals
  - coverageOverlayDataProvider (StreamProvider, live-refresh trigger for 07-06 truth #3)

affects:
  - 07-04: GeoJSON render bridge consumes CoverageOverlayData
  - 07-06: live-refresh truth #3 depends on coverageOverlayDataProvider StreamProvider chain
  - future Phase-8 backfill: drivenWayIntervals write triggers recompute via readsFrom

tech-stack:
  added: []
  patterns:
    - "Drift customSelect(...).watchSingle() with explicit readsFrom for reactive cross-table watch"
    - "StreamProvider (not FutureProvider) for mandatory live-refresh in Riverpod"
    - "Table-write invalidation (not value-diff) as the reactive trigger mechanism"
    - "DomainError.wrap() + .empty fallback for crash-safe rendering (06-05 lesson)"

key-files:
  created:
    - lib/features/coverage/data/coverage_overlay_data.dart
    - lib/features/coverage/data/driven_way_geometry_resolver.dart
    - lib/features/coverage/data/coverage_overlay_providers.dart
    - test/features/coverage/data/driven_way_geometry_resolver_test.dart
  modified:
    - lib/core/db/daos/driven_way_intervals_dao.dart
    - lib/features/trips/data/trips_dao.dart
    - test/core/db/daos/driven_way_intervals_dao_test.dart

key-decisions:
  - "getAllIntervals() includes SET-NULL rows (trip deleted) — coverage is way-centric, survives trip loss"
  - "No JOIN on trips.status in getAllIntervals: Phase 6 only writes intervals for trips that reached the matcher; matched+confirmed both mean driven"
  - "watchUnionBbox readsFrom {trips, drivenWayIntervals}: Drift invalidates on ANY table write (not value-diff); matched→confirmed flip re-emits even though aggregate bbox unchanged"
  - "coverageOverlayDataProvider is StreamProvider not FutureProvider: FutureProvider caches and won't re-run on upstream emission, breaking live-refresh"
  - "DrivenWayGeometryResolver is stateless: resolve() reads fresh on every call; no caching in the resolver itself"
  - "_polylineLengthMeters duplicated from TripDetailScreen (private) rather than importing presentation layer from data layer"

patterns-established:
  - "Drift reactive stream: customSelect(...).watchSingle() + readsFrom for multi-table subscriptions"
  - "Table-write invalidation pattern: readsFrom drives reactivity regardless of SQL aggregate value change"

duration: 16min
completed: 2026-07-10
---

# Phase 7 Plan 03: Geometry Resolver Summary

**Cache-first geometry resolution + per-way coverage classification via union-length/Haversine; reactive StreamProvider chain proved by 5 Drift table-write re-emit tests.**

## Performance

- **Duration:** 16 min
- **Started:** 2026-07-10T05:17:28Z
- **Completed:** 2026-07-10T05:33:46Z
- **Tasks:** 3/3
- **Files modified:** 7

## Accomplishments

- Closed RESEARCH open-question #1: `DrivenWayGeometryResolver.resolve(LatLngBounds)` bridges the gap between the `driven_way_intervals` table (no geometry, no tile info) and rendered coverage by fetching way geometry via the existing `WayCandidateSource` cache-first path.
- Live-refresh chain for 07-06 truth #3 is provably in place: `confirmTrip` → `trips` write → `watchUnionBbox` re-emits → `coverageOverlayDataProvider` re-resolves. Proven by a Drift in-memory test that observes the stream re-emit on a `matched→confirmed` status flip.
- Added `getAllIntervals()` + `getDistinctWayIds()` to `DrivenWayIntervalsDao` with full tests (8 total, incl. SET-NULL survival and distinct-id deduplication).

## Task Commits

1. **Task 1: DrivenWayIntervalsDao.getAllIntervals + getDistinctWayIds** - `2faabe0` (feat)
2. **Task 2: CoverageWay/CoverageOverlayData + DrivenWayGeometryResolver** - `ba77b69` (feat)
3. **Task 3: watchUnionBbox + coverage_overlay_providers + resolver test** - `3c19afe` (feat)

## Files Created/Modified

- `lib/core/db/daos/driven_way_intervals_dao.dart` — added `getAllIntervals()` + `getDistinctWayIds()`
- `lib/features/coverage/data/coverage_overlay_data.dart` — `CoverageWay` (wayId+geometry+datum) + `CoverageOverlayData` (.empty sentinel)
- `lib/features/coverage/data/driven_way_geometry_resolver.dart` — resolver: fetchWaysInBbox(throwOnError:false), classifyCoverage per way, skip missing geo + below-floor, degrade to .empty on error
- `lib/features/trips/data/trips_dao.dart` — `watchUnionBbox()`: customSelect MIN/MAX bbox of matched+confirmed trips, `readsFrom: {trips, drivenWayIntervals}`
- `lib/features/coverage/data/coverage_overlay_providers.dart` — `drivenWayIntervalsDaoProvider`, `drivenWayGeometryResolverProvider`, `tripsUnionBoundsProvider` (StreamProvider), `coverageOverlayDataProvider` (StreamProvider)
- `test/core/db/daos/driven_way_intervals_dao_test.dart` — 3 new tests for getAllIntervals + getDistinctWayIds
- `test/features/coverage/data/driven_way_geometry_resolver_test.dart` — 11 new tests (6 resolve paths + 5 reactivity)

## Decisions Made

1. **No JOIN on trips.status in getAllIntervals** — Phase 6 only writes intervals for trips that reached the matcher; both `matched` and `confirmed` represent "driven" for rendering; simplest and correct.
2. **watchUnionBbox readsFrom {trips, drivenWayIntervals}** — Drift invalidates the watched query on ANY write to either table, not on value change. A `matched→confirmed` flip does not change `status IN ('matched','confirmed')` membership but still re-emits. This is the mandatory trigger mechanism for 07-06.
3. **coverageOverlayDataProvider is StreamProvider** — FutureProvider caches and does not re-run on upstream emission. The StreamProvider rebuilds on each `tripsUnionBoundsProvider` emission (i.e., on every Drift table write).
4. **_polylineLengthMeters duplicated** — The version in `TripDetailScreen` is private. Duplicating the trivial Haversine sum avoids importing a presentation-layer private from the data layer.

## Deviations from Plan

None — plan executed exactly as written.
