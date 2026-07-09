---
phase: 07-coverage-rendering
plan: 03
type: execute
wave: 2
depends_on: ["07-01"]
files_modified:
  - lib/features/coverage/data/driven_way_geometry_resolver.dart
  - lib/features/coverage/data/coverage_overlay_data.dart
  - lib/features/coverage/data/coverage_overlay_providers.dart
  - lib/core/db/daos/driven_way_intervals_dao.dart
  - lib/features/trips/data/trips_dao.dart
  - test/features/coverage/data/driven_way_geometry_resolver_test.dart
autonomous: true

must_haves:
  truths:
    - "All distinct driven wayIds across confirmed/matched trips can be enumerated with their intervals"
    - "Each driven wayId resolves to a LatLng polyline via the Overpass cache, grouped by z12 tile"
    - "Ways whose tile is a cache-miss/offline are silently skipped (logged), not crash"
    - "Each resolved way yields a CoverageDatum (fraction+isFull) from union-length / Haversine way-length"
    - "The resolved coverage set is exposed via coverageOverlayDataProvider, which auto-recomputes when a trip is confirmed mid-session (reactive Drift stream)"
  artifacts:
    - path: "lib/features/coverage/data/driven_way_geometry_resolver.dart"
      provides: "DrivenWayGeometryResolver: wayIds -> geometry+coverage (RESEARCH open-Q1)"
      contains: "class DrivenWayGeometryResolver"
    - path: "lib/features/coverage/data/coverage_overlay_data.dart"
      provides: "CoverageWay immutable (wayId, geometry, datum) + CoverageOverlayData collection"
      contains: "class CoverageWay"
    - path: "lib/features/coverage/data/coverage_overlay_providers.dart"
      provides: "coverageOverlayDataProvider (StreamProvider, reactive) + resolver provider"
      contains: "coverageOverlayDataProvider"
  key_links:
    - from: "driven_way_geometry_resolver.dart"
      to: "OverpassWayCandidateSource.fetchWaysInBbox / OverpassWayCacheDao.getByTile"
      via: "cache-first geometry lookup"
      pattern: "fetchWaysInBbox|getByTile"
    - from: "driven_way_geometry_resolver.dart"
      to: "coverage_threshold.dart classifyCoverage"
      via: "per-way fraction+isFull from union length"
      pattern: "classifyCoverage"
    - from: "coverage_overlay_providers.dart"
      to: "TripsDao.watchUnionBbox (Drift watchSingle stream)"
      via: "reactive recompute on confirmed-trips change"
      pattern: "watchUnionBbox"
---

<objective>
Build the coverage data layer: resolve every driven way's geometry from the
Overpass cache and pair it with a `CoverageDatum` computed from its merged
driven intervals. This is RESEARCH open-question #1 — the `driven_intervals`
table stores no geometry and no tile mapping, so we must enumerate driven
wayIds, resolve geometry via the existing cache-first `WayCandidateSource`, and
compute per-way coverage fraction + full/partial from union-length divided by
the Haversine way length.

Purpose: Produces the `CoverageOverlayData` (list of CoverageWays) that the
render overlay (07-04) turns into a GeoJSON FeatureCollection. Isolates all
DB/cache/network concerns here so the render layer is pure MapLibre wiring. The
provider is REACTIVE — it re-runs when a trip is confirmed mid-session so the
map updates live (this is the trigger 07-06 truth #3 depends on).
Output: resolver + value types + reactive providers + a unit test with a fake source.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-RESEARCH.md

# Domain built in 07-01 (this plan consumes it)
@lib/features/coverage/domain/coverage_threshold.dart
@lib/features/coverage/domain/coverage_datum.dart
@lib/features/coverage/domain/interval_union.dart

# The exact geometry-resolution seam to reuse — TripDetailScreen already does
# fetchWaysInBbox + reconstructWaySubsegment + Haversine way length per trip.
# Generalize its pattern app-wide; DO NOT reinvent the polyline math.
@lib/features/trips/presentation/trip_detail_screen.dart
@lib/features/matching/data/overpass_way_candidate_source.dart
@lib/features/matching/data/way_candidate_source.dart
@lib/features/matching/data/matching_providers.dart
@lib/features/matching/data/tile_bbox_math.dart
@lib/features/matching/domain/way_candidate.dart
@lib/core/db/daos/driven_way_intervals_dao.dart
@lib/features/trips/data/trips_dao.dart
@lib/features/trips/domain/haversine.dart

# The reactive-stream idiom to mirror (watchInboxTrips uses customSelect().watch();
# confirmTrip flips status=confirmed which watched queries observe live).
@lib/features/trips/data/trips_dao_inbox_queries.dart
</context>

<tasks>

<task type="auto">
  <name>Task 1: Enumerate driven wayIds + intervals across confirmed trips (DAO)</name>
  <files>lib/core/db/daos/driven_way_intervals_dao.dart</files>
  <action>
Add a read method to `DrivenWayIntervalsDao` that returns ALL intervals for
ways belonging to confirmed/matched trips (the app-wide driven set, not one
trip). The table's `tripId` FK is `ON DELETE SET NULL`; include rows even where
tripId is null (already-matched historic intervals) — the driven set is
way-centric.

Add:
  Future<List<DrivenWayInterval>> getAllIntervals()  — SELECT * ordered by wayId.

Rationale: the resolver groups these by wayId in Dart (avoids a fragile
GROUP_CONCAT). Keep it a simple `select(drivenWayIntervals).get()`. Do NOT add
a JOIN on trips status — Phase 6 only writes intervals for trips that reached
the matcher, and confirmed vs matched both represent "driven" for rendering;
keeping every interval is correct and simplest. Document this choice in the
doc-comment.

If a distinct-wayId-only query is also useful, add
`Future<List<int>> getDistinctWayIds()` via customSelect
`SELECT DISTINCT way_id FROM driven_way_intervals` — optional, resolver can
derive distinct ids from getAllIntervals().

NOTE: This touches lib/core/db — run `flutter test` inline after (tiered Ralph
Loop). No schema change (no new column/table), so no drift_dev schema generate
needed; but run `dart run build_runner build` if the .g.dart mixin needs a
refresh for the new method (it should not — these are hand-written query
methods, not codegen). Verify analyze is clean.
  </action>
  <verify>flutter analyze clean; a DB test (in-memory) confirms getAllIntervals returns inserted rows across multiple wayIds.</verify>
  <done>DrivenWayIntervalsDao.getAllIntervals() returns every interval row; grouping by wayId is possible downstream.</done>
</task>

<task type="auto">
  <name>Task 2: DrivenWayGeometryResolver + CoverageWay value types</name>
  <files>lib/features/coverage/data/driven_way_geometry_resolver.dart, lib/features/coverage/data/coverage_overlay_data.dart</files>
  <action>
Create `coverage_overlay_data.dart`:
  - `@immutable class CoverageWay { const CoverageWay({required this.wayId,
    required this.geometry, required this.datum}); final int wayId;
    final List<LatLng> geometry; final CoverageDatum datum; }` (LatLng from
    maplibre_gl).
  - `@immutable class CoverageOverlayData { const CoverageOverlayData(this.ways);
    final List<CoverageWay> ways; static const empty = CoverageOverlayData(<CoverageWay>[]); }`

Create `driven_way_geometry_resolver.dart` with
`class DrivenWayGeometryResolver`:
  constructor injects `DrivenWayIntervalsDao intervalsDao` and
  `WayCandidateSource waySource` (the runtime provider is
  OverpassWayCandidateSource — cache-first).

  Future<CoverageOverlayData> resolve(LatLngBounds unionBounds) async:
    (unionBounds is passed in from the reactive provider in Task 3 — the
    resolver stays focused on geometry+coverage, not on querying trips.)
    1. final intervals = await intervalsDao.getAllIntervals();
       Group into Map<int wayId, List<Interval>> (Interval from interval_union.dart
       — startMeters/endMeters). Empty -> return CoverageOverlayData.empty.
    2. Resolve geometry for all ways in one cache-first pass over the union bbox:
         - waySource.fetchWaysInBbox(
             minLat: unionBounds.southwest.latitude,
             minLon: unionBounds.southwest.longitude,
             maxLat: unionBounds.northeast.latitude,
             maxLon: unionBounds.northeast.longitude,
             throwOnError: false)  -> List<WayCandidate>.
           throwOnError:false so an offline gap yields whatever tiles are cached
           (graceful skip, not crash — mirrors TripDetailScreen's offline path).
         - Build Map<int, WayCandidate> byId.
    3. For each driven wayId:
         - way = byId[wayId]; if null -> skip + log.fine('geometry miss $wayId').
         - unionLen = drivenLengthMeters(intervalsForWay) (interval_union.dart).
         - wayLen = Haversine sum over way.geometry (reuse the polyline-length
           helper pattern from trip_detail_screen — extract a small private
           `_polylineLengthMeters` here using haversineMeters; do NOT import the
           private one).
         - datum = classifyCoverage(unionLen, wayLen).
         - if datum.fraction <= 0 && !datum.isFull -> skip (below floor / undriven).
         - add CoverageWay(wayId, way.geometry, datum).
    4. Return CoverageOverlayData(list). Log a summary count + skipped count.

Wrap any non-DomainError throwable at the boundary via DomainError.wrap()
(project rule) — but since fetchWaysInBbox with throwOnError:false already
swallows network errors, the resolver should not normally throw. Guard the DB
read + geometry loop; on unexpected error return CoverageOverlayData.empty and
log.warning (rendering must degrade gracefully, never crash the map — memory:
06-05 on-device crash).

Package imports only; no relative imports. Use `logging` Logger like
OverpassWayCandidateSource does.
  </action>
  <verify>flutter analyze clean.</verify>
  <done>DrivenWayGeometryResolver.resolve(unionBounds) returns CoverageOverlayData; missing-geometry ways skipped+logged; each CoverageWay carries geometry + fraction + isFull.</done>
</task>

<task type="auto">
  <name>Task 3: Reactive providers + watchUnionBbox stream + resolver unit test</name>
  <files>lib/features/trips/data/trips_dao.dart, lib/features/coverage/data/coverage_overlay_providers.dart, test/features/coverage/data/driven_way_geometry_resolver_test.dart</files>
  <action>
LIVE-REFRESH IS MANDATORY (07-06 truth #3 depends on it). Use Drift's reactive
`watch` stream so a trip confirmation (status flip to `confirmed`, done by
`TripsInboxDao.transitionToConfirmed`) automatically recomputes the overlay
data. A one-shot FutureProvider would cache and NOT re-run mid-session — do NOT
use FutureProvider for the trigger.

1. TripsDao (`lib/features/trips/data/trips_dao.dart`) — add a WATCHED
   union-bbox query (this method is unconditionally needed; not optional):
     Stream<LatLngBounds?> watchUnionBbox()
   Implement via customSelect(...).watchSingle() (mirror the reactive-stream
   idiom in trips_dao_inbox_queries.dart `_watchByStatuses`):
     SELECT MIN(bbox_min_lat) AS min_lat, MIN(bbox_min_lon) AS min_lon,
            MAX(bbox_max_lat) AS max_lat, MAX(bbox_max_lon) AS max_lon
     FROM trips
     WHERE status IN ('matched','confirmed')
   readsFrom: {trips, drivenWayIntervals}. Map the row -> LatLngBounds (null when
   all aggregates are null, i.e. no trips or no bbox columns populated). Because
   the query `readsFrom` BOTH tables, Drift re-emits whenever a trip's
   status/bbox changes (incl. confirmTrip) OR whenever driven intervals are
   written/deleted. The explicit `readsFrom` set is independent of the SELECT'd
   tables — we aggregate only `trips`, but subscribe to interval writes too so
   the overlay stays live even for a future intervals-only mutation path
   (e.g. a Phase-8 background backfill or a re-match on an already-matched trip).
   Document that this reactivity is what drives the live map update.

2. `coverage_overlay_providers.dart` (plain Provider / StreamProvider — NO @Riverpod):
   - `drivenWayGeometryResolverProvider = Provider<DrivenWayGeometryResolver>((ref)
      => DrivenWayGeometryResolver(intervalsDao: ref.watch(<intervals dao provider>),
         waySource: ref.watch(wayCandidateSourceProvider)));`
     Find/create the intervals DAO provider (check app_database_providers.dart for
     an existing one; if none, add `drivenWayIntervalsDaoProvider` following the
     coverageCacheDaoProvider pattern). Reuse the existing TripsDao provider
     (`tripsDaoProvider`).
   - `tripsUnionBoundsProvider = StreamProvider<LatLngBounds?>((ref) =>
        ref.watch(tripsDaoProvider).watchUnionBbox());`
     StreamProvider (NOT FutureProvider) — this is the reactive trigger.
   - `coverageOverlayDataProvider = StreamProvider<CoverageOverlayData>((ref) async* {
        final boundsAsync = ref.watch(tripsUnionBoundsProvider);
        final bounds = boundsAsync.valueOrNull;
        if (bounds == null) { yield CoverageOverlayData.empty; return; }
        yield await ref.watch(drivenWayGeometryResolverProvider).resolve(bounds);
      });`
     Modeling note: use `ref.watch(tripsUnionBoundsProvider)` inside so the
     StreamProvider re-runs each time the union-bbox stream emits (trip confirmed).
     Alternatively implement as a StreamProvider that awaits
     `ref.watch(tripsUnionBoundsProvider.future)` then resolves — either is fine
     as long as a confirmed-trip emission causes a fresh resolve(). Confirm the
     end-to-end chain: confirmTrip -> trips.status change -> watchUnionBbox emits
     -> tripsUnionBoundsProvider emits -> coverageOverlayDataProvider re-resolves
     -> 07-06 bridge re-applies. State this chain in a doc-comment so 07-06's
     truth #3 is provably satisfied.

   Note on the driven-intervals side: the union-bbox recompute is a SUFFICIENT
   trigger because Drift invalidates the watched stream on ANY write to the
   `trips` or `drivenWayIntervals` tables (the `readsFrom` set above) — it does
   NOT diff the aggregated MIN/MAX result value. So a `matched->confirmed` status
   flip (which does not change the `status IN ('matched','confirmed')` membership)
   still re-emits, purely on the table write. The resolver re-reads
   getAllIntervals() on every recompute, so freshly-written intervals are picked
   up. IMPORTANT for the executor: do NOT "optimize" the trigger to fire only on
   membership/value changes — the table-write invalidation is the mechanism.
   Document this rationale (no separate intervals watch needed — it is folded
   into the `readsFrom` set).

3. `driven_way_geometry_resolver_test.dart`:
   - In-memory AppDatabase (NativeDatabase.memory()) — follow existing DAO test
     setup patterns (grep test/ for NativeDatabase.memory usage).
   - Insert intervals for wayIds: one fully covered, one partial-above-floor,
     one below-floor that must be skipped.
   - Fake WayCandidateSource returning WayCandidate geometry for those wayIds
     (a simple straight polyline of known Haversine length; make one wayId absent
     to assert the skip-on-missing-geometry path).
   - Assert resolve(bounds): returns CoverageWay for the covered + partial ways
     with correct isFull flags; the below-floor way and the geometry-missing way
     are skipped.
   - Reactivity assertion: insert a trip (status matched), listen to
     `watchUnionBbox()` (or drive coverageOverlayDataProvider via a
     ProviderContainer), confirm the stream emits; then transition the trip to
     confirmed / insert another matched trip and assert the stream emits AGAIN
     (proves the live-refresh trigger works — the crux of the BLOCKER fix).

Run `flutter test test/features/coverage/data/` inline (touches lib/core/db +
trips DAO — behavior-sensitive).
  </action>
  <verify>flutter test test/features/coverage/data/ green (incl. the re-emit reactivity test); flutter analyze clean.</verify>
  <done>coverageOverlayDataProvider is a StreamProvider that re-resolves when confirmed-trips change; watchUnionBbox re-emits on trip status change; resolver test proves classification + skip paths AND the re-emit trigger.</done>
</task>

</tasks>

<verification>
- `flutter analyze` clean.
- `flutter test test/features/coverage/` green.
- Resolver never throws on cache-miss/offline — returns partial or empty data.
- The reactive chain (confirmTrip -> watchUnionBbox emit -> overlay re-resolve)
  is proven by a re-emit test.
</verification>

<success_criteria>
Given driven intervals + a cached Overpass geometry set, the coverage data layer
produces a list of CoverageWays (geometry + fraction + isFull), skipping ways
with missing geometry or below the partial floor, exposed via a REACTIVE
coverageOverlayDataProvider that auto-recomputes on trip confirmation. RESEARCH
open-question #1 (geometry resolver) is owned and closed here, and the
live-refresh trigger 07-06 needs is in place.
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-03-SUMMARY.md`
</output>
