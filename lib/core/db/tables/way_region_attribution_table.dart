import 'package:drift/drift.dart';

/// Durable per-way → region attribution cache (schema v8).
///
/// One row per `(wayId, regionId)`: the length of OSM way [wayId] that lies
/// geometrically INSIDE the admin region [regionId] (at [adminLevel]), computed
/// once by clipping the way's polyline to the region polygon. A way that
/// crosses a region boundary produces one row per region it passes through, so
/// its length is split across regions (not assigned wholly to its centroid's
/// region as the old centroid attribution did).
///
/// Why this table exists (coverage reliability, 2026-07-25):
///   * The old `recompute()` re-attributed EVERY driven way on every trip by
///     re-parsing cached Overpass tiles + point-in-polygon — growing with
///     all-trips-ever and depending on the volatile 50 MB Overpass tile cache
///     (LRU eviction silently dropped ways → coverage regressed).
///   * A way's region membership + clipped length are STATIC (geometry never
///     moves), so they are computed ONCE per new wayId (off the UI thread in
///     `CoverageComputeIsolate`) and cached here forever.
///   * Recompute then becomes a pure DB aggregation: driven length per
///     `(way, region)` = the way's driven union interval clipped to this
///     region's share; region total = SUM(clippedLengthM). Eviction-proof
///     (driven intervals live in `driven_way_intervals`, never evicted) and
///     monotonic (always sums all driven ways).
///
/// Growth is bounded by (distinct driven ways × regions they touch). Most ways
/// fall inside one region at each of the 5 attributed admin levels → ~5 rows
/// per distinct way. Driving the same road N times is still one set of rows.
class WayRegionAttribution extends Table {
  /// OSM way id.
  IntColumn get wayId => integer()();

  /// OSM relation id of the containing admin region, as a string (matches
  /// `CoverageCache.regionId` and `AdminRegion.osmId.toString()`).
  TextColumn get regionId => text()();

  /// OSM admin_level of [regionId] (one of the attributed levels 4/6/8/9/10).
  IntColumn get adminLevel => integer()();

  /// Length in meters of way [wayId]'s geometry that lies inside region
  /// [regionId]'s polygon (the clipped share, not the way's full length).
  RealColumn get clippedLengthM => real()();

  /// When this attribution row was computed (for observability / future TTL).
  DateTimeColumn get computedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {wayId, regionId};
}
