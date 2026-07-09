---
phase: 06-inbox-match-wire-up
plan: 06-02
subsystem: trips
tags: [drift, reverse-geocoding, admin-region, inbox, coverage-invalidation, riverpod]

# Dependency graph
requires:
  - phase: 06-inbox-match-wire-up
    provides: CoverageInvalidator + coverageInvalidatorProvider (Plan 06-01)
  - phase: 04-osm-pipeline
    provides: AdminRegionLookup (bundled Germany admin polygons — Plan 04-16)
  - phase: 03-tracking-mvp
    provides: TripsDao / Trips + TripPoints tables (Plan 03-01, 03-04)
  - phase: 01-scaffolding
    provides: DrivenWayIntervalsDao FK ON DELETE SET NULL (Plan 01-02)
provides:
  - TripPlaceLookup — two-endpoint reverse geocoder (level-8 preferred, level-10 fallback)
  - TripPlaces DTO + tripPlaceLookupProvider + tripPlacesProvider (FutureProvider.family)
  - TripListItem read-model DTO (16 fields incl. intervalCount + derived start/end coords)
  - TripsInboxDao — watchInboxTrips, watchHistoryTrips, watchInFlightCount, transitionToConfirmed, getTripWithIntervalCount
  - TripsInboxRepository — confirmTrip (Keep) + discardTrip (Discard) + 3 stream pass-throughs
  - tripsInboxRepositoryProvider — plain Provider<T> wiring
affects: [06-04+ inbox/history UI, 06-05 trip detail screen, 08 coverage recompute, 09 vehicle assignment]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Companion DAO/Repository classes (TripsInboxDao, TripsInboxRepository) live alongside TripsDao/TripsRepository — never modify the originals (Wave file-ownership hygiene)"
    - "customSelect(...).watch() with subqueries for derived columns (start/end coords, interval count) — cleaner than fluent-join fan-out"
    - "Recording DAO subclasses + recording fake invalidator to assert exact call ordering in delete-sequence tests"
    - "hide isNull, isNotNull on drift.dart imports in DAO tests (STATE 05-01 / 06-01 pattern)"

key-files:
  created:
    - lib/features/trips/domain/trip_place_lookup.dart
    - lib/features/trips/data/trip_place_lookup_providers.dart
    - lib/features/trips/domain/trip_list_item.dart
    - lib/features/trips/data/trips_dao_inbox_queries.dart
    - lib/features/trips/data/trips_repository_inbox_extensions.dart
    - test/features/trips/trip_place_lookup_test.dart
    - test/features/trips/trips_dao_inbox_queries_test.dart
    - test/features/trips/trips_repository_inbox_extensions_test.dart
  modified:
    - lib/core/db/converters/trip_status_converter.dart

key-decisions:
  - "TripStatusConverter lives at lib/core/db/converters/ (not features/trips/domain as the plan sketch assumed) — comment-only fix applied there for Pitfall #4"
  - "confirmTrip flips status FIRST then invalidates; invalidator Err is logged + swallowed so the user's Keep is never lost (SC3 degrade path)"
  - "discardTrip aborts BEFORE any delete when the invalidator Errs — never deletes a trip while the cache is in an unknown state"
  - "tripPlacesProvider keeps inferred type + inline ignore for specify_nonobvious_property_types — FutureProviderFamily is @publicInMisc (not cleanly exported by flutter_riverpod 3.3.2)"
  - "No drivenWayIntervalsDaoProvider exists in the codebase — DAOs constructed inline in the provider (matches matching_providers.dart pattern)"

patterns-established:
  - "Reverse-geocode granularity: level-8 (Landkreis/kreisfreie Stadt) primary, level-10 (Gemeinde/Ortsteil) fallback, null over water"
  - "TripListItem.isFailMatched = matched status + 0 intervals — the fail-matched chip signal for the UI (Q10)"
  - "TripListItem.isInFlight = pending | pendingRoadData — the in-flight/history spinner signal (Q8)"

# Metrics
duration: 20min
completed: 2026-07-09
---

# Phase 6 Plan 06-02: Reverse-Geocoding + Inbox/History DAO + Keep/Discard Repository Summary

**Data-layer inbox wiring: two-endpoint reverse geocoder over bundled admin polygons, TripsInboxDao streams (inbox / history / in-flight) with derived start-end coords + interval counts, and a TripsInboxRepository that flips-then-invalidates on Keep and invalidates-then-deletes-in-order on Discard so coverage recomputes after Keep (SC3) and no interval orphans survive Discard.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-07-09T11:38:16Z
- **Completed:** 2026-07-09T11:58:19Z
- **Tasks:** 3/3
- **Files created:** 8 (5 lib + 3 test); 1 modified (comment-only)

## Accomplishments

- `TripPlaceLookup` reverse-geocodes trip start/end coordinates to human-readable names via `AdminRegionLookup`, level-8 preferred with level-10 fallback (Q2). `TripPlaces` carries an `isLoop` convenience getter for round-trip cards.
- `TripsInboxDao` exposes the 5 methods the inbox/history UI needs, all backed by `customSelect(...).watch()` with subqueries that derive start/end lat-lon from the first/last `trip_points` row and count `driven_way_intervals` per trip without join fan-out.
- `TripListItem` DTO with the 16 verified schema-v3 fields + `isFailMatched` / `isInFlight` / `duration` getters.
- `TripsInboxRepository` wires the whole Keep/Discard flow at the `Result<T>` boundary with the two critical ordering rules enforced AND unit-tested via a recording invalidator + recording DAO subclasses.
- `trip_status_converter.dart` stale comment now lists `pendingRoadData` (Pitfall #4).

## Task Commits

Each task was committed atomically with only files_owned staged:

1. **Task 1: TripPlaceLookup reverse-geocoder (Q2)** — `dc4283f` (feat)
2. **Task 2: TripsInboxDao inbox/history queries + TripListItem DTO (Q8, Q10)** — `8675aa9` (feat)
3. **Task 3: TripsInboxRepository confirm/discard with cache invalidation** — `941b5e5` (feat)

Metadata commit follows this SUMMARY + STATE update.

## Files Created / Modified

- `lib/features/trips/domain/trip_place_lookup.dart` — `TripPlaceLookup.lookup(...)` → `TripPlaces(startName, endName)`; level-8 primary, level-10 fallback via private `_nameAt`.
- `lib/features/trips/data/trip_place_lookup_providers.dart` — `tripPlaceLookupProvider` + `tripPlacesProvider` (`FutureProvider.family` keyed by a `TripPlacesCoords` record).
- `lib/features/trips/domain/trip_list_item.dart` — 16-field immutable read-model with `isFailMatched` / `isInFlight` / `duration`.
- `lib/features/trips/data/trips_dao_inbox_queries.dart` — `TripsInboxDao` (`DatabaseAccessor<AppDatabase>`, no `@DriftAccessor`). 5 methods: `watchInboxTrips`, `watchHistoryTrips`, `watchInFlightCount`, `transitionToConfirmed`, `getTripWithIntervalCount`.
- `lib/features/trips/data/trips_repository_inbox_extensions.dart` — `TripsInboxRepository` + `tripsInboxRepositoryProvider`.
- `lib/core/db/converters/trip_status_converter.dart` — comment-only: added `pendingRoadData` to the enumerated statuses (Pitfall #4).
- 3 test files: 5 + 10 + 8 = 23 test cases.

## API Reference (for 06-04+ wiring — do not re-read source)

```dart
// trip_place_lookup.dart
class TripPlaces { final String? startName, endName; bool get isLoop; }
class TripPlaceLookup {
  Future<TripPlaces> lookup({
    required double startLat, startLon, endLat, endLon,
  });
}
// providers: tripPlaceLookupProvider (Provider), tripPlacesProvider (FutureProvider.family<TripPlaces, TripPlacesCoords>)
// TripPlacesCoords = ({double startLat, startLon, endLat, endLon});

// trip_list_item.dart — 16 fields
class TripListItem {
  final int id; final TripStatus status;
  final DateTime startedAt; final DateTime? endedAt;
  final double? distanceMeters; final int? durationSeconds;
  final double? startLat, startLon, endLat, endLon;   // derived from trip_points
  final int intervalCount;
  final int? vehicleId;                                // null in P6
  final double? bboxMinLat, bboxMinLon, bboxMaxLat, bboxMaxLon;
  bool get isFailMatched;  // matched + intervalCount == 0
  bool get isInFlight;     // pending | pendingRoadData
  Duration? get duration;
}

// trips_dao_inbox_queries.dart
class TripsInboxDao extends DatabaseAccessor<AppDatabase> {
  Stream<List<TripListItem>> watchInboxTrips();     // matched only, ended_at DESC
  Stream<List<TripListItem>> watchHistoryTrips();   // matched+confirmed+pending+pendingRoadData
  Stream<int> watchInFlightCount();                 // pending+pendingRoadData
  Future<void> transitionToConfirmed(int tripId);   // matched -> confirmed
  Future<TripListItem?> getTripWithIntervalCount(int tripId);
}

// trips_repository_inbox_extensions.dart
class TripsInboxRepository {
  Future<Result<void>> confirmTrip(int tripId);  // flip THEN invalidateForTrip (SC3)
  Future<Result<void>> discardTrip(int tripId);  // invalidate -> deleteByTrip -> deleteTrip
  Stream<List<TripListItem>> watchInboxItems();
  Stream<List<TripListItem>> watchHistoryItems();
  Stream<int> watchInFlightCount();
}
// provider: tripsInboxRepositoryProvider (Provider<TripsInboxRepository>)
```

## Decisions Made

1. **Keep = flip THEN invalidate; invalidator Err is swallowed.** The status flip is the user's intent and must survive a cache-invalidation failure (logged as a warning). A subsequent coverage read still triggers a P8 recompute. This is the SC3 fix (Issue 1).
2. **Discard = invalidate FIRST, then delete intervals, then delete trip.** Invalidator reads the trip's bbox, which must still be present. Intervals are deleted explicitly because the FK is `ON DELETE SET NULL` (not CASCADE) — otherwise they orphan forever. If the invalidator Errs, the discard aborts BEFORE any delete, so the trip is never removed while the cache state is unknown.
3. **`TripStatusConverter` actual path is `lib/core/db/converters/`.** The plan's `files_owned` listed `lib/features/trips/domain/trip_status_converter.dart`; the file does not exist there. The real converter is at `lib/core/db/converters/trip_status_converter.dart` — the comment-only Pitfall #4 fix was applied to the real file.
4. **`tripPlacesProvider` type left inferred with inline ignore.** `FutureProviderFamily` is `@publicInMisc` in flutter_riverpod 3.3.2 and not cleanly importable, so annotating the top-level field is impractical; an inline `// ignore: specify_nonobvious_property_types` documents the choice.
5. **DAOs constructed inline in providers.** No `drivenWayIntervalsDaoProvider` exists in the codebase (matching_providers.dart constructs `DrivenWayIntervalsDao(...)` inline); `tripsInboxRepositoryProvider` follows the same pattern.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `trip_status_converter.dart` real path differs from files_owned**
- **Found during:** Task 2
- **Issue:** `files_modified` listed `lib/features/trips/domain/trip_status_converter.dart` but that file does not exist; the converter lives at `lib/core/db/converters/trip_status_converter.dart`.
- **Fix:** Applied the comment-only Pitfall #4 change (add `pendingRoadData`) to the real file.
- **Files modified:** `lib/core/db/converters/trip_status_converter.dart`
- **Verification:** `flutter analyze` clean; full `flutter test test/features/trips/` (114 tests) green.
- **Committed in:** `8675aa9` (Task 2 commit)

**2. [Rule 3 - Blocking] Analyzer lint iterations (drift/matcher import collision + literal + type-annotation)**
- **Found during:** Tasks 1 & 2
- **Issue:** `isNull`/`isNotNull` ambiguous import (drift vs flutter_test), `prefer_int_literals`, `specify_nonobvious_property_types`, `avoid_redundant_argument_values`, `matching_super_parameters`.
- **Fix:** `hide isNull, isNotNull` on drift imports (STATE 06-01 pattern), literal cleanups, inline ignore for the Riverpod family type, `super.attachedDatabase` naming.
- **Verification:** `flutter analyze` clean on all owned files.
- **Committed in:** each respective task commit.

---

**Total deviations:** 2 auto-fixed (both Rule 3 - Blocking). No architectural changes, no scope creep.
**Impact on plan:** All fixes mechanical. The only substantive divergence is the converter file path (documented above).

## Issues Encountered

None beyond the mechanical Ralph-loop lint fixes above.

## Verification

- `flutter analyze` — clean on all 8 owned files + the modified converter.
- `flutter test test/features/trips/` — 114/114 green (includes the 23 new cases: 5 + 10 + 8).
- Delete ordering asserted: `['invalidateForTripDelete', 'deleteByTrip', 'deleteTrip']` via recording fakes.
- Keep flow asserted: status flips to confirmed AND `invalidateForTrip(tripId)` invoked exactly once (SC3).

## Wave Hygiene

Files staged INDIVIDUALLY per the parallel-wave rule (memory: `wave-2-parallel-metadata-hygiene`). No `git add .` / `git add -A`. 06-02 runs in Wave 2 (after 06-01 landed); no sibling agents contended for these files.

## Next Phase Readiness

- 06-04+ inbox/history UI can consume `tripsInboxRepositoryProvider` (streams + Keep/Discard) and `tripPlacesProvider` (card place names) directly.
- 06-05 trip detail screen can use `getTripWithIntervalCount` for matched-way count + `isFailMatched`.
- No blockers. `vehicleId` stays null until Phase 9; the DTO already carries the field.

---
*Phase: 06-inbox-match-wire-up*
*Completed: 2026-07-09*
