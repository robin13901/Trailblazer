---
plan: 06-02
phase: 6
wave: 2
depends_on: [06-01]
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
    - "TripsRepository.confirmTrip(tripId) flips matched → confirmed AND invokes CoverageInvalidator.invalidateForTrip(tripId) so coverage_cache re-computes on next read (INB-03, COV-06 trigger 1, SC3)"
    - "TripsRepository.discardTrip(tripId) deletes driven_way_intervals BEFORE trip row, invalidates cache, hard-deletes trip (INB-04, INB-08, COV-06 trigger 2)"
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
    - from: "TripsRepository.confirmTrip"
      to: "CoverageInvalidator.invalidateForTrip"
      via: "call AFTER status flip — Keep is the observable moment coverage may change; matcher-time invalidation is not sufficient because SC3 measures post-Keep behavior"
      pattern: "invalidateForTrip"
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
Data-layer wiring for the inbox: reverse-geocoded place names from bundled admin polygons, new Drift queries for inbox/history/in-flight streams, TripsRepository extensions for Keep + Discard flows with correct delete ordering (intervals → invalidator → trip row), and — critically — cache invalidation on both Keep (post-flip) and Discard (pre-delete) so SC3 (coverage re-computes after Keep) holds.
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
@drift_schemas/drift_schema_v3.json

# Upstream plan 06-01 output (READ before starting — 06-01 completes in Wave 1, this plan runs in Wave 2)
# CoverageInvalidator API (from 06-01):
#   Future<Result<int>> invalidateForTrip(int tripId)         — Keep path (idempotent)
#   Future<Result<int>> invalidateForTripDelete(int tripId)   — Discard path
#   Future<Result<int>> invalidateAll()                       — P10 stub
# Provider: coverageInvalidatorProvider — Provider<CoverageInvalidator>
</context>

<invariants>
- Riverpod codegen OFF — plain `Provider<T>` / `Notifier`.
- Package imports only (`package:auto_explore/...`).
- `DomainError` + `Result<T>` at boundaries; wrap non-DomainError throwables via `DomainError.wrap()`.
- No schema bump — `trips.vehicle_id` already at v3, `TripStatus.rejected` already in enum.
- `DrivenWayIntervals` FK is `ON DELETE SET NULL` (verified `driven_intervals_table.dart:8`) — deleteByTrip MUST run before trip delete.
- Ralph Loop tiered: `flutter analyze` per commit; behavior-sensitive changes here → run `flutter test test/features/trips/` inside the loop too.
- No drive checkpoint in this plan.
- **DO NOT touch files owned by 06-01, 06-03** (Wave-1 parallel-metadata hygiene — 06-01 & 06-03 both run alongside `null` here since 06-02 is Wave 2; but 06-01 landed in Wave 1 and its files must not be modified retroactively).
- **DO NOT modify `trips_dao.dart` or `trips_repository.dart` directly** — add new files with extension-style additions to avoid file conflicts if any other plan touches them. (See files_owned.)
- Sibling-API pattern: 06-01 owns CoverageInvalidator; 06-02 imports its provider. The API contract is fixed by 06-01's must_haves.artifacts before either plan writes code.
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
**Pre-flight (already done — verified against `drift_schemas/drift_schema_v3.json`):**

The `trips` table columns (schema v3) — Dart field names derived by Drift from these snake_case columns:

| Column (SQL)      | Dart field (Drift-generated) | Type      |
|-------------------|-------------------------------|-----------|
| `id`              | `id`                          | int (PK)  |
| `started_at`      | `startedAt`                   | DateTime  |
| `ended_at`        | `endedAt`                     | DateTime? |
| `duration_seconds`| `durationSeconds`             | int?      |
| `distance_meters` | `distanceMeters`              | double?   |
| `avg_speed_kmh`   | `avgSpeedKmh`                 | double?   |
| `max_speed_kmh`   | `maxSpeedKmh`                 | double?   |
| `status`          | `status`                      | String / enum via converter |
| `vehicle_id`      | `vehicleId`                   | int? (P9 populates) |
| `manually_started`| `manuallyStarted`             | bool      |
| `auto_stopped`    | `autoStopped`                 | bool      |
| `bluetooth_hint`  | `bluetoothHint`               | String?   |
| `created_at`      | `createdAt`                   | DateTime  |
| `bbox_min_lat`    | `bboxMinLat`                  | double?   |
| `bbox_min_lon`    | `bboxMinLon`                  | double?   |
| `bbox_max_lat`    | `bboxMaxLat`                  | double?   |
| `bbox_max_lon`    | `bboxMaxLon`                  | double?   |
| `point_count`     | `pointCount`                  | int       |

The `driven_way_intervals` table (schema v3): `id`, `way_id` (`wayId`), `trip_id` (`tripId`), `start_meters` (`startMeters`), `end_meters` (`endMeters`), `direction`, `matched_at` (`matchedAt`).

**Note:** the `trips` table does **not** carry start/end lat-lon columns directly — those must be derived from `trip_points` (first row by `seq` for start, last for end) OR from the bbox corners as a coarse proxy. Recommended: compute start/end coords by joining/subquery-ing `trip_points` (columns: `id`, `trip_id`, `seq`, `ts`, `lat`, `lon`, `speed_kmh`, `accuracy_meters`, `altitude_meters`, `motion_type`) — `MIN(seq)` for start, `MAX(seq)` for end. Pattern (Drift custom query):
```sql
SELECT t.*,
  (SELECT lat FROM trip_points WHERE trip_id = t.id ORDER BY seq ASC  LIMIT 1) AS start_lat,
  (SELECT lon FROM trip_points WHERE trip_id = t.id ORDER BY seq ASC  LIMIT 1) AS start_lon,
  (SELECT lat FROM trip_points WHERE trip_id = t.id ORDER BY seq DESC LIMIT 1) AS end_lat,
  (SELECT lon FROM trip_points WHERE trip_id = t.id ORDER BY seq DESC LIMIT 1) AS end_lon,
  (SELECT COUNT(*) FROM driven_way_intervals WHERE trip_id = t.id) AS interval_count
FROM trips t
WHERE t.status IN (?)
ORDER BY t.ended_at DESC;
```
Use Drift's `customSelect(...).watch()` (or `.map(...)` returning `TripListItem`) — do NOT try to compose this with the fluent Drift API, joins-with-subselects are cleaner as custom SQL. Follow whatever pattern already exists in `trips_dao.dart` if it has similar joins.

Add new queries as a **`TripsInboxDao` class** (constructor takes `AppDatabase`) that lives alongside `TripsDao` and reuses the same tables. Keeps file ownership clean across the wave and avoids reaching into `TripsDao`'s private state.

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
    this.bboxMinLat,
    this.bboxMinLon,
    this.bboxMaxLat,
    this.bboxMaxLon,
  });
  final int id;
  final TripStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double? distanceMeters;
  final int? durationSeconds;
  final double? startLat;
  final double? startLon;
  final double? endLat;
  final double? endLon;
  final int intervalCount;
  final int? vehicleId;
  final double? bboxMinLat;
  final double? bboxMinLon;
  final double? bboxMaxLat;
  final double? bboxMaxLon;

  bool get isFailMatched => status == TripStatus.matched && intervalCount == 0;
  bool get isInFlight    => status == TripStatus.pending || status == TripStatus.pendingRoadData;
  Duration? get duration => durationSeconds == null ? null : Duration(seconds: durationSeconds!);
}
```

**Note on nullability:** `endedAt`, `distanceMeters`, `durationSeconds`, and the four bbox fields are nullable per the schema. `startLat/startLon/endLat/endLon` will be null for zero-point trips (guard the derived-column mapping accordingly). UI must render "—" for null values (handled in 06-05).

`TripsInboxDao` (in `trips_dao_inbox_queries.dart`):
```dart
class TripsInboxDao {
  TripsInboxDao(this._db);
  final AppDatabase _db;

  /// Inbox = trips awaiting Keep/Discard decision.
  /// status == matched, ORDER BY ended_at DESC.
  /// Includes intervalCount subquery.
  Stream<List<TripListItem>> watchInboxTrips();

  /// History = confirmed trips + in-flight matching trips (Q8).
  /// status IN (matched, confirmed, pending, pendingRoadData), ORDER BY ended_at DESC.
  Stream<List<TripListItem>> watchHistoryTrips();

  /// Global queue indicator (Q8).
  /// count of trips WHERE status IN (pending, pendingRoadData).
  Stream<int> watchInFlightCount();

  /// Keep action (INB-03) — status flip only.
  /// (Cache invalidation is orchestrated by TripsInboxRepository — Task 3 — not here.)
  Future<void> transitionToConfirmed(int tripId);

  /// For TripDetailScreen — single-row lookup with intervalCount.
  Future<TripListItem?> getTripWithIntervalCount(int tripId);
}
```

Implementation notes:
- Map `TripStatus` values via the existing converter (`trip_status_converter.dart`).
- The subquery approach above avoids join fan-out from `driven_way_intervals`.

**While editing `trip_status_converter.dart`:** update the STALE COMMENT (line ~6) to include `pendingRoadData` in the enumerated statuses list (RESEARCH.md Pitfall #4 — comment-only fix, no logic change).

Tests (`test/features/trips/trips_dao_inbox_queries_test.dart`) with in-memory Drift:
- Seed 5 trips: statuses [matched, matched, confirmed, pending, rejected]. watchInboxTrips first emit → 2 matched trips only, sorted by ended_at DESC.
- watchHistoryTrips → 4 trips (matched, matched, confirmed, pending); rejected excluded (but note P6 hard-deletes rejected — this test just confirms the SQL filter).
- watchInFlightCount → 1 (only pending). Seed one more `pendingRoadData` → count becomes 2, emitted reactively.
- transitionToConfirmed(tripId) on a matched trip → subsequent watchInboxTrips emit no longer contains it; watchHistoryTrips does.
- getTripWithIntervalCount for a trip with 3 seeded intervals → intervalCount == 3; for a fail-matched trip (0 intervals) → intervalCount == 0 and isFailMatched == true.
- startLat/startLon/endLat/endLon populate from first/last `trip_points` row (seed 3 points, verify values).
- Ordering test: 3 trips with distinct ended_at → returned newest-first.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trips_dao_inbox_queries_test.dart` green.
  </verify>
  <done>
`TripsInboxDao` exposes 5 methods; `TripListItem` DTO exists with the 16 fields above; ≥7 test cases pass; status converter comment fixed.
  </done>
</task>

<task id="3" type="auto">
  <title>Task 3: TripsRepository inbox extensions — confirmTrip (with cache invalidation) + discardTrip with correct delete order</title>
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

  /// INB-03 + COV-06 trigger 1 (SC3):
  /// 1. Flip status matched → confirmed via inboxDao.transitionToConfirmed.
  /// 2. Call invalidator.invalidateForTrip(tripId) so the coverage cache
  ///    drops rows for regions touched by this trip. The next coverage-read
  ///    will recompute. Idempotent — safe if invoked twice.
  /// NOTE: matching already ran at trip-stop time (Q8) — Keep does NOT enqueue
  /// matching. But the observable "trip counts for coverage" moment is Keep,
  /// so cache invalidation MUST happen here (not at matcher-write time) for
  /// SC3 to hold.
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

Keep body (critical — this is Issue 1's fix):
```dart
Future<Result<void>> confirmTrip(int tripId) async {
  return DomainError.wrap(() async {
    // 1. Flip status — matched → confirmed.
    await _inboxDao.transitionToConfirmed(tripId);
    // 2. Invalidate coverage cache — COV-06 trigger 1 / SC3.
    //    Idempotent: invalidator returns Result.ok(0) if already invalidated.
    //    We ignore the returned count; treat an invalidator Err as a
    //    non-fatal warning (log and swallow) so the user's Keep isn't lost.
    final invalidation = await _invalidator.invalidateForTrip(tripId);
    if (invalidation.isErr) {
      // Log but don't surface — status flip already succeeded.
      // A subsequent coverage read will still see stale cache; P8 will fix on
      // next recompute. Acceptable degrade path.
    }
  });
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
- confirmTrip on a matched trip: status flips to confirmed AND `invalidator.invalidateForTrip(tripId)` is invoked exactly once with the correct tripId. Assert both via a call recorder. (This is the SC3 fix — Issue 1.)
- confirmTrip when invalidator returns Result.err → status flip STILL succeeds (returns Result.ok), invalidator error is swallowed (documented degrade path).
- confirmTrip on a non-matched trip (e.g. rejected/pending): status flip is idempotent no-op, invalidator STILL called (also idempotent). Both no-ops → Result.ok.
- discardTrip **call ordering** (verify with call recorder): invalidator.invalidateForTripDelete → intervalsDao.deleteByTrip → tripsDao.deleteTrip, in that order.
- discardTrip: seed a trip with 3 intervals; after discard, `SELECT COUNT(*) FROM driven_way_intervals WHERE trip_id IS NULL` == 0 (no orphans) AND `SELECT COUNT(*) FROM trips WHERE id = ?` == 0.
- discardTrip: fake invalidator returns Result.err → discard aborts, trip + intervals still present.
- discardTrip on a fail-matched trip (bbox NULL): invalidator returns Result.ok(0), delete completes cleanly.

Pitfalls to explicitly guard (from RESEARCH.md):
- `driven_way_intervals.trip_id` FK is `ON DELETE SET NULL` — orphans would linger forever. deleteByTrip BEFORE deleteTrip.
- `TripMatchCoordinator.processPending` on resume drains pending — this repo does NOT interact with the matcher; Keep is purely a status flip + cache invalidation.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trips_repository_inbox_extensions_test.dart` green.
  </verify>
  <done>
`TripsInboxRepository` with confirmTrip (with invalidator call) + discardTrip + 3 stream pass-throughs; delete order enforced + tested; invalidateForTrip call from confirmTrip enforced + tested (Issue 1 / SC3 gate); ≥7 test cases pass.
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
- **Keep flow invokes CoverageInvalidator.invalidateForTrip — SC3 satisfied** (Issue 1 fix).
- Reverse-geocoding returns level-8 with level-10 fallback (RESEARCH Q2).
- No schema bump; no vehicle CRUD; `counts_for_coverage` untouched (CONTEXT deviations honored).
- No modification to `trips_dao.dart`/`trips_repository.dart` (file-ownership hygiene).
- Comment in `trip_status_converter.dart` includes `pendingRoadData` (Pitfall #4).
- TripListItem DTO field list matches verified schema-v3 columns (start/end lat-lon derived from `trip_points`, bbox from `bbox_min_lat` / `bbox_min_lon` / `bbox_max_lat` / `bbox_max_lon`).
</success_criteria>

<output>
Create `.planning/phases/06-inbox-match-wire-up/06-02-SUMMARY.md`.
Capture: exact TripsInboxDao/Repository API, TripListItem field list (with verified schema-v3 column mapping), delete-order rule, Keep-invokes-invalidateForTrip rule (SC3), decision that Keep is idempotent no-op on non-matched trips + invalidator error is swallowed to preserve user's Keep intent.
</output>
