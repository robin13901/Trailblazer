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
  - test/features/coverage/data/driven_way_geometry_resolver_test.dart
autonomous: true

must_haves:
  truths:
    - "All distinct driven wayIds across confirmed/matched trips can be enumerated with their intervals"
    - "Each driven wayId resolves to a LatLng polyline via the Overpass cache, grouped by z12 tile"
    - "Ways whose tile is a cache-miss/offline are silently skipped (logged), not crash"
    - "Each resolved way yields a CoverageDatum (fraction+isFull) from union-length / Haversine way-length"
    - "The result is a Map<int wayId, (geometry, CoverageDatum)> exposed via a FutureProvider"
  artifacts:
    - path: "lib/features/coverage/data/driven_way_geometry_resolver.dart"
      provides: "DrivenWayGeometryResolver: wayIds -> geometry+coverage (RESEARCH open-Q1)"
      contains: "class DrivenWayGeometryResolver"
    - path: "lib/features/coverage/data/coverage_overlay_data.dart"
      provides: "CoverageWay immutable (wayId, geometry, datum) + CoverageOverlayData collection"
      contains: "class CoverageWay"
    - path: "lib/features/coverage/data/coverage_overlay_providers.dart"
      provides: "coverageOverlayDataProvider (FutureProvider) + resolver provider"
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
    - from: "driven_way_intervals_dao.dart"
      to: "driven_way_intervals table"
      via: "new getAllIntervalsForConfirmedTrips / distinct wayIds query"
      pattern: "wayId"
---

<objective>
Build the coverage data layer: resolve every driven way's geometry from the
Overpass cache and pair it with a `CoverageDatum` computed from its merged
driven intervals. This is RESEARCH open-question #1 — the `driven_intervals`
table stores no geometry and no tile mapping, so we must enumerate driven
wayIds, resolve geometry via the existing cache-first `WayCandidateSource`, and
compute per-way coverage fraction + full/partial from union-length divided by
the Haversine way length.

Purpose: Produces the `Map<wayId, CoverageWay>` that the render overlay (07-04)
turns into a GeoJSON FeatureCollection. Isolates all DB/cache/network concerns
here so the render layer is pure MapLibre wiring.
Output: resolver + value types + providers + a unit test with a fake source.
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
@lib/features/trips/domain/haversine.dart
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

  Future<CoverageOverlayData> resolve() async:
    1. final intervals = await intervalsDao.getAllIntervals();
       Group into Map<int wayId, List<Interval>> (Interval from interval_union.dart
       — startMeters/endMeters). Empty -> return CoverageOverlayData.empty.
    2. Compute the union bbox over ALL intervals' ways? We have no geometry yet.
       Instead resolve geometry per wayId via the Overpass cache. The cheapest
       correct approach reusing existing seams:
         - We cannot bbox without geometry. So drive geometry lookup off the
           cache TILES that already exist. Read distinct wayIds; for the bbox
           we need a hint. Use the trips' stored bbox columns (bboxMinLat..)
           to build a coarse union bbox of all confirmed/matched trips, then a
           single waySource.fetchWaysInBbox over that union (cache-first — no
           network if tiles are cached). Inject a `TripsDao`-backed bbox source:
           add `List<LatLngBounds> Function()`-style dependency, OR accept a
           precomputed `LatLngBounds unionBounds` argument to resolve(). Prefer
           passing the union bounds in from the provider (Task 3 computes it via
           a small TripsDao query) to keep the resolver focused.
         - Given `unionBounds`, call
           waySource.fetchWaysInBbox(minLat,minLon,maxLat,maxLon,
           throwOnError:false) -> List<WayCandidate>. throwOnError:false so an
           offline gap yields whatever tiles are cached (graceful skip, not crash).
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
  <name>Task 3: Providers + union-bounds query + resolver unit test</name>
  <files>lib/features/coverage/data/coverage_overlay_providers.dart, test/features/coverage/data/driven_way_geometry_resolver_test.dart</files>
  <action>
`coverage_overlay_providers.dart` (plain Provider / FutureProvider — NO @Riverpod):
  - `drivenWayGeometryResolverProvider = Provider<DrivenWayGeometryResolver>((ref)
     => DrivenWayGeometryResolver(intervalsDao: ref.watch(<intervals dao provider>),
        waySource: ref.watch(wayCandidateSourceProvider)));`
    Find/create the intervals DAO provider (check app_database_providers.dart for
    an existing one; if none, add `drivenWayIntervalsDaoProvider` there or in a
    coverage provider file following the coverageCacheDaoProvider pattern).
  - Compute the union bounds of all confirmed/matched trips: add a tiny
    `tripsUnionBoundsProvider` (FutureProvider<LatLngBounds?>) that reads the
    trips' bbox columns. Reuse TripsDao — add a `Future<LatLngBounds?> unionBbox()`
    method there if needed (SELECT MIN(bbox_min_lat), MIN(bbox_min_lon),
    MAX(bbox_max_lat), MAX(bbox_max_lon) FROM trips WHERE status IN
    ('matched','confirmed')). Null when no trips.
  - `coverageOverlayDataProvider = FutureProvider<CoverageOverlayData>((ref) async {
       final bounds = await ref.watch(tripsUnionBoundsProvider.future);
       if (bounds == null) return CoverageOverlayData.empty;
       return ref.watch(drivenWayGeometryResolverProvider).resolve(bounds); });`
    This is the app-start + post-trip-confirmation load (RESEARCH §"Coverage
    fraction computation placement"). Riverpod runs it off the UI build path.

`driven_way_geometry_resolver_test.dart`:
  - In-memory AppDatabase (NativeDatabase.memory()) — follow existing DAO test
    setup patterns (grep test/ for NativeDatabase.memory usage).
  - Insert intervals for 2 wayIds (one fully covered, one partial-above-floor,
    one below-floor that must be skipped).
  - Fake WayCandidateSource returning WayCandidate geometry for those wayIds
    (a simple straight polyline of known Haversine length; make one wayId absent
    to assert the skip-on-missing-geometry path).
  - Assert: resolve(bounds) returns CoverageWay for the covered + partial ways
    with correct isFull flags; the below-floor way and the geometry-missing way
    are skipped.

Run `flutter test test/features/coverage/data/` inline (touches lib/core/db +
data layer — behavior-sensitive).
  </action>
  <verify>flutter test test/features/coverage/data/ green; flutter analyze clean.</verify>
  <done>coverageOverlayDataProvider yields resolved CoverageWays; resolver test proves full/partial classification + skip paths with a fake source.</done>
</task>

</tasks>

<verification>
- `flutter analyze` clean.
- `flutter test test/features/coverage/` green.
- Resolver never throws on cache-miss/offline — returns partial or empty data.
</verification>

<success_criteria>
Given driven intervals + a cached Overpass geometry set, the coverage data layer
produces a Map/list of CoverageWays (geometry + fraction + isFull), skipping
ways with missing geometry or below the partial floor, exposed via
coverageOverlayDataProvider. RESEARCH open-question #1 (geometry resolver) is
owned and closed here.
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-03-SUMMARY.md`
</output>
