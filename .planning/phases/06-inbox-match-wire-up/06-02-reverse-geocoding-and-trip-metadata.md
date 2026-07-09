---
plan: 06-02
phase: 6
wave: 1
depends_on: []
type: execute
autonomous: true
files_owned:
  - lib/features/trips/domain/trip_place_lookup.dart
  - lib/features/trips/domain/trip_list_item.dart
  - lib/features/trips/data/trips_dao_inbox_queries.dart
  - lib/features/trips/data/trips_repository_inbox_extensions.dart
  - lib/features/trips/data/trip_place_lookup_providers.dart
  - test/features/trips/trip_place_lookup_test.dart
  - test/features/trips/trips_dao_inbox_queries_test.dart
  - test/features/trips/trips_repository_inbox_extensions_test.dart
files_modified:
  - lib/features/trips/domain/trip_place_lookup.dart
  - lib/features/trips/domain/trip_list_item.dart
  - lib/features/trips/data/trips_dao_inbox_queries.dart
  - lib/features/trips/data/trips_repository_inbox_extensions.dart
  - lib/features/trips/data/trip_place_lookup_providers.dart
  - test/features/trips/trip_place_lookup_test.dart
  - test/features/trips/trips_dao_inbox_queries_test.dart
  - test/features/trips/trips_repository_inbox_extensions_test.dart
  - lib/features/trips/domain/trip_status_converter.dart
must_haves:
  truths:
    - "Inbox stream yields only trips with status == matched, newest first (INB-01, INB-06)"
    - "History stream yields matched + confirmed + pending + pendingRoadData trips (INB-06)"
    - "In-flight count stream yields count of pending + pendingRoadData trips (Q8)"
    - "TripsRepository.confirmTrip(tripId) flips matched → confirmed and returns Result<void> (INB-03)"
    - "TripsRepository.discardTrip(tripId) deletes driven_way_intervals BEFORE trip row, invalidates cache, hard-deletes trip (INB-04, INB-08, COV-06)"
    - "TripPlaceLookup returns (startName, endName) at admin level 8 with fallback to level 10 (Q2)"
    - "TripListItem exposes intervalCount so UI can chip 'No roads matched' when zero (Q10)"
  artifacts:
    - path: "lib/features/trips/domain/trip_place_lookup.dart"
      provides: "TripPlaceLookup.lookup(lat,lon,lat,lon) → (String? start, String? end)"
    - path: "lib/features/trips/data/trips_dao_inbox_queries.dart"
      provides: "watchInboxTrips, watchHistoryTrips, watchInFlightCount, transitionToConfirmed, getTripWithIntervalCount"
    - path: "lib/features/trips/data/trips_repository_inbox_extensions.dart"
      provides: "confirmTrip, discardTrip, watchInboxItems, watchHistoryItems, watchInFlightCount"
    - path: "lib/features/trips/domain/trip_list_item.dart"
      provides: "TripListItem DTO with intervalCount"
  key_links:
    - from: "TripsRepository.discardTrip"
      to: "CoverageInvalidator.invalidateForTripDelete"
      via: "call BEFORE deleting the trip so bbox is still readable"
      pattern: "invalidateForTripDelete"
    - from: "TripsRepository.discardTrip"
      to: "DrivenWayIntervalsDao.deleteByTrip"
      via: "call BEFORE deleteTrip — FK is ON DELETE SET NULL, not CASCADE"
      pattern: "deleteByTrip"
    - from: "TripPlaceLookup"
      to: "AdminRegionLookup.regionAt(lat, lon, level)"
      via: "level 8 primary, level 10 fallback"
      pattern: "AdminRegionLookup"
verification:
  analyzer: "flutter analyze passes"
  tests:
    - test/features/trips/trip_place_lookup_test.dart
    - test/features/trips/trips_dao_inbox_queries_test.dart
    - test/features/trips/trips_repository_inbox_extensions_test.dart
---

<objective>
Data-layer wiring for the inbox: reverse-geocoded place names from bundled admin polygons, new Drift queries for inbox/history/in-flight streams, TripsRepository extensions for Keep + Discard flows with correct delete ordering (intervals → invalidator → trip row).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/06-inbox-match-wire-up/06-CONTEXT.md
@.planning/phases/06-inbox-match-wire-up/06-RESEARCH.md
@CLAUDE.md

# Existing infrastructure to reuse (READ these, do not duplicate)
@lib/features/trips/data/trips_dao.dart
@lib/features/trips/data/trips_repository.dart
@lib/features/trips/data/trips_repository_providers.dart
@lib/features/trips/domain/trip_status.dart
@lib/features/trips/domain/trip_status_converter.dart
@lib/features/admin/data/admin_region_lookup.dart
@lib/features/admin/data/admin_region_providers.dart
@lib/core/db/daos/driven_way_intervals_dao.dart
@lib/core/errors/domain_error.dart
@lib/core/errors/result.dart

# Sibling plan 06-01 output (READ during Wave-1 to know the API — but 06-01 & 06-02 own DIFFERENT files)
# CoverageInvalidator API: invalidateForTripDelete(tripId) → Future<Result<int>>
</context>

<invariants>
- Riverpod codegen OFF — plain `Provider<T>` / `Notifier`.
- Package imports only (`package:auto_explore/...`).
- `DomainError` + `Result<T>` at boundaries; wrap non-DomainError throwables via `DomainError.wrap()`.
- No schema bump — `trips.vehicle_id` already at v3, `TripStatus.rejected` already in enum.
- `DrivenWayIntervals` FK is `ON DELETE SET NULL` (verified `driven_intervals_table.dart:8`) — deleteByTrip MUST run before trip delete.
- Ralph Loop tiered: `flutter analyze` per commit; behavior-sensitive changes here → run `flutter test test/features/trips/` inside the loop too.
- No drive checkpoint in this plan.
- **DO NOT touch files owned by 06-01, 06-03, 06-04** (parallel-wave metadata hygiene).
- **DO NOT modify `trips_dao.dart` or `trips_repository.dart` directly** — add new files with extension-style additions to avoid file conflicts if another wave-1 plan touches them. (See files_owned.)
</invariants>

<tasks>

<task id="1" type="auto">
  <title>Task 1: TripPlaceLookup domain service (Q2)</title>
  <files>
    lib/features/trips/domain/trip_place_lookup.dart
    lib/features/trips/data/trip_place_lookup_providers.dart
    test/features/trips/trip_place_lookup_test.dart
  </files>
  <action>
Wrap `AdminRegionLookup` for the two-endpoint (start/end) query pattern needed by trip cards.

Signature:
```dart
class TripPlaces {
  const TripPlaces({required this.startName, required this.endName});
  final String? startName; // e.g. "Miltenberg" (level 8) or "Kleinheubach" (level 10 fallback)
  final String? endName;
  bool get isLoop => startName != null && startName == endName;
}

class TripPlaceLookup {
  TripPlaceLookup(this._regionLookup);
  final AdminRegionLookup _regionLookup;

  /// Returns level-8 (Landkreis/kreisfreie Stadt) name if present,
  /// falls back to level-10 (Gemeinde) if null,
  /// finally null if both are null (over water / outside DE).
  Future<TripPlaces> lookup({
    required double startLat,
    required double startLon,
    required double endLat,
    required double endLon,
  });

  String? _nameAt(double lat, double lon);
}
```

The wrapping name resolution reads `.name` from the region record — check `AdminRegionLookup.regionAt`'s return type (likely `AdminRegion?` with a `.name` field). Use the exact accessor from the codebase.

Provider (`lib/features/trips/data/trip_place_lookup_providers.dart`):
```dart
final tripPlaceLookupProvider = Provider<TripPlaceLookup>((ref) {
  return TripPlaceLookup(ref.watch(adminRegionLookupProvider));
});

/// Memoized per-trip place lookup for card rendering.
/// Family provider keyed by tripId — UI reads coordinates from TripListItem.
final tripPlacesProvider = FutureProvider.family<TripPlaces, ({double startLat, double startLon, double endLat, double endLon})>((ref, coords) async {
  return ref.watch(tripPlaceLookupProvider).lookup(
    startLat: coords.startLat,
    startLon: coords.startLon,
    endLat: coords.endLat,
    endLon: coords.endLon,
  );
});
```

Tests (`test/features/trips/trip_place_lookup_test.dart`) with a fake `AdminRegionLookup`:
- Level-8 returns "Miltenberg" for both endpoints → TripPlaces(start: "Miltenberg", end: "Miltenberg"), isLoop == true.
- Level-8 differs → distinct start/end names.
- Level-8 returns null but level-10 returns "Kleinheubach" → fallback used.
- Both levels null (over water) → TripPlaces(start: null, end: null).
- Mixed: start has level-8, end only level-10 → returns each's best.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trip_place_lookup_test.dart` green.
  </verify>
  <done>
`TripPlaceLookup.lookup` returns level-8-preferred names with level-10 fallback; 5 test cases pass.
  </done>
</task>

<task id="2" type="auto">
  <title>Task 2: TripsDao inbox/history queries + TripListItem DTO (Q8, Q10)</title>
  <files>
    lib/features/trips/domain/trip_list_item.dart
    lib/features/trips/data/trips_dao_inbox_queries.dart
    lib/features/trips/domain/trip_status_converter.dart
    test/features/trips/trips_dao_inbox_queries_test.dart
  </files>
  <action>
Add new queries as an **extension** on `TripsDao` in a new file (`trips_dao_inbox_queries.dart`) to keep file ownership clean across the wave. Extensions can use `_db` if we expose an internal getter; if not, take `AppDatabase` explicitly in each helper. Choose whichever compiles clean under `very_good_analysis`.

Alternative if extension pattern doesn't fit: create a `TripsInboxDao` class (constructor takes `AppDatabase`) that lives alongside `TripsDao` and reuses the same tables. This is the recommended path — cleaner, no reach-into-private-state.

`TripListItem` DTO (`lib/features/trips/domain/trip_list_item.dart`):
```dart
class TripListItem {
  const TripListItem({
    required this.id,
    required this.status,
    required this.startedAt,
    required this.endedAt,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
    required this.intervalCount,
    this.vehicleId,          // stays null in P6 (P9 populates)
    this.minLat,
    this.minLon,
    this.maxLat,
    this.maxLon,
  });
  // ... fields ...
  bool get isFailMatched => status == TripStatus.matched && intervalCount == 0;
  bool get isInFlight => status == TripStatus.pending || status == TripStatus.pendingRoadData;
  Duration get duration => Duration(seconds: durationSeconds);
}
```

`TripsInboxDao` (in `trips_dao_inbox_queries.dart`):
```dart
class TripsInboxDao {
  TripsInboxDao(this._db);
  final AppDatabase _db;

  /// Inbox = trips awaiting Keep/Discard decision.
  /// status == matched, ORDER BY endedAt DESC.
  /// Includes intervalCount subquery.
  Stream<List<TripListItem>> watchInboxTrips();

  /// History = confirmed trips + in-flight matching trips (Q8).
  /// status IN (matched, confirmed, pending, pendingRoadData), ORDER BY endedAt DESC.
  Stream<List<TripListItem>> watchHistoryTrips();

  /// Global queue indicator (Q8).
  /// count of trips WHERE status IN (pending, pendingRoadData).
  Stream<int> watchInFlightCount();

  /// Keep action (INB-03) — status flip only.
  Future<void> transitionToConfirmed(int tripId);

  /// For TripDetailScreen — single-row lookup with intervalCount.
  Future<TripListItem?> getTripWithIntervalCount(int tripId);
}
```

Implementation notes:
- Use a Drift `join` or a raw custom query — whichever the existing `trips_dao.dart` uses for its more complex queries; **match the codebase style**.
- LEFT JOIN driven_way_intervals subquery: `SELECT ..., (SELECT COUNT(*) FROM driven_way_intervals WHERE trip_id = trips.id) AS interval_count FROM trips WHERE ...`.
- Map `TripStatus` values via the existing converter (`trip_status_converter.dart`).

**While editing `trip_status_converter.dart`:** update the STALE COMMENT (line ~6) to include `pendingRoadData` in the enumerated statuses list (RESEARCH.md Pitfall #4 — comment-only fix, no logic change).

Tests (`test/features/trips/trips_dao_inbox_queries_test.dart`) with in-memory Drift:
- Seed 5 trips: statuses [matched, matched, confirmed, pending, rejected]. watchInboxTrips first emit → 2 matched trips only, sorted by endedAt DESC.
- watchHistoryTrips → 4 trips (matched, matched, confirmed, pending); rejected excluded (but note P6 hard-deletes rejected — this test just confirms the SQL filter).
- watchInFlightCount → 1 (only pending). Seed one more `pendingRoadData` → count becomes 2, emitted reactively.
- transitionToConfirmed(tripId) on a matched trip → subsequent watchInboxTrips emit no longer contains it; watchHistoryTrips does.
- getTripWithIntervalCount for a trip with 3 seeded intervals → intervalCount == 3; for a fail-matched trip (0 intervals) → intervalCount == 0 and isFailMatched == true.
- Ordering test: 3 trips with distinct endedAt → returned newest-first.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trips_dao_inbox_queries_test.dart` green.
  </verify>
  <done>
`TripsInboxDao` exposes 5 methods; `TripListItem` DTO exists; ≥6 test cases pass; status converter comment fixed.
  </done>
</task>

<task id="3" type="auto">
  <title>Task 3: TripsRepository inbox extensions — confirmTrip + discardTrip with correct delete order</title>
  <files>
    lib/features/trips/data/trips_repository_inbox_extensions.dart
    test/features/trips/trips_repository_inbox_extensions_test.dart
  </files>
  <action>
Add an inbox-facing repository layer that wraps `TripsInboxDao` + `CoverageInvalidator` + `DrivenWayIntervalsDao` at the `Result<T>` boundary. Ship as a companion class (not modifying `trips_repository.dart` directly) to avoid file conflicts with any other Wave-1 plan.

```dart
class TripsInboxRepository {
  TripsInboxRepository({
    required TripsInboxDao inboxDao,
    required TripsDao tripsDao,           // reuse for deleteTrip
    required DrivenWayIntervalsDao intervalsDao,
    required CoverageInvalidator invalidator,
  });

  /// INB-03: Keep = flip matched → confirmed.
  /// NOTE: matching already ran at trip-stop time (Q8) — Keep does NOT enqueue matching.
  Future<Result<void>> confirmTrip(int tripId);

  /// INB-04 + INB-08 + COV-06 trigger 2.
  /// Hard-delete: invalidator FIRST (needs bbox), then intervalsDao.deleteByTrip
  /// (FK is SET NULL not CASCADE — RESEARCH.md Pitfall #3), then tripsDao.deleteTrip
  /// (which cascades trip_points).
  Future<Result<void>> discardTrip(int tripId);

  /// Streams pass-through, mapped to Result<T> nothing — expose raw for providers.
  Stream<List<TripListItem>> watchInboxItems() => _inboxDao.watchInboxTrips();
  Stream<List<TripListItem>> watchHistoryItems() => _inboxDao.watchHistoryTrips();
  Stream<int> watchInFlightCount() => _inboxDao.watchInFlightCount();
}
```

Delete ordering (critical — this is the whole reason this class exists):
```dart
Future<Result<void>> discardTrip(int tripId) async {
  return DomainError.wrap(() async {
    // 1. Invalidate cache FIRST — needs bbox from trip row.
    final invalidation = await _invalidator.invalidateForTripDelete(tripId);
    if (invalidation.isErr) return invalidation.map((_) {});
    // 2. Delete driven_way_intervals explicitly (FK is SET NULL, not CASCADE).
    await _intervalsDao.deleteByTrip(tripId);
    // 3. Delete trip row (cascades trip_points).
    await _tripsDao.deleteTrip(tripId);
  });
}
```

Provider (co-locate in `trips_repository_inbox_extensions.dart`):
```dart
final tripsInboxRepositoryProvider = Provider<TripsInboxRepository>((ref) {
  return TripsInboxRepository(
    inboxDao: TripsInboxDao(ref.watch(appDatabaseProvider)),
    tripsDao: ref.watch(tripsDaoProvider),
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
    invalidator: ref.watch(coverageInvalidatorProvider), // from 06-01
  );
});
```

Tests (`test/features/trips/trips_repository_inbox_extensions_test.dart`) — in-memory Drift + fake `CoverageInvalidator` capturing calls:
- confirmTrip flips status matched → confirmed, returns Result.ok(null).
- confirmTrip on a non-matched trip (e.g. rejected/pending) → either succeeds no-op or returns Result.err (pick one, document, TEST it). Recommended: succeeds no-op (status flip idempotent).
- discardTrip **call ordering** (verify with call recorder): invalidator.invalidateForTripDelete → intervalsDao.deleteByTrip → tripsDao.deleteTrip, in that order.
- discardTrip: seed a trip with 3 intervals; after discard, `SELECT COUNT(*) FROM driven_way_intervals WHERE trip_id IS NULL` == 0 (no orphans) AND `SELECT COUNT(*) FROM trips WHERE id = ?` == 0.
- discardTrip: fake invalidator returns Result.err → discard aborts, trip + intervals still present.
- discardTrip on a fail-matched trip (bbox NULL): invalidator returns Result.ok(0), delete completes cleanly.

Pitfalls to explicitly guard (from RESEARCH.md):
- `driven_way_intervals.trip_id` FK is `ON DELETE SET NULL` — orphans would linger forever. deleteByTrip BEFORE deleteTrip.
- `TripMatchCoordinator.processPending` on resume drains pending — this repo does NOT interact with the matcher; Keep is purely a status flip.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trips_repository_inbox_extensions_test.dart` green.
  </verify>
  <done>
`TripsInboxRepository` with confirmTrip + discardTrip + 3 stream pass-throughs; delete order enforced + tested; ≥5 test cases pass.
  </done>
</task>

</tasks>

<verification>
Fast-loop (per commit): `flutter analyze`.
Behavior-sensitive (run in loop): `flutter test test/features/trips/`.
Pre-push hook covers the full test suite.
</verification>

<success_criteria>
- All 3 test files pass.
- Analyzer clean.
- Delete ordering enforced: invalidator → intervals → trip row (RESEARCH Pitfall #3).
- Reverse-geocoding returns level-8 with level-10 fallback (RESEARCH Q2).
- No schema bump; no vehicle CRUD; `counts_for_coverage` untouched (CONTEXT deviations honored).
- No modification to `trips_dao.dart`/`trips_repository.dart` (file-ownership hygiene).
- Comment in `trip_status_converter.dart` includes `pendingRoadData` (Pitfall #4).
</success_criteria>

<output>
Create `.planning/phases/06-inbox-match-wire-up/06-02-SUMMARY.md`.
Capture: exact TripsInboxDao/Repository API, TripListItem field list, delete-order rule, decision that Keep is idempotent no-op on non-matched trips.
</output>
