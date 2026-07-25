import 'package:drift/drift.dart';

/// Durable per-way → region attribution cache (schema v8).
///
/// One row per contiguous stretch of an OSM way that lies inside one admin
/// region: `(wayId, regionId, adminLevel)` plus the meter-range
/// `[rangeStartM, rangeEndM]` — offsets measured ALONG the way from its first
/// node — over which the way is inside that region's polygon. A way that
/// crosses a region boundary produces one row per region it passes through
/// (and, in the rare case it weaves back into the same region, multiple rows
/// for that region — hence `rangeStartM` is part of the primary key).
///
/// Why meter-RANGES and not just a clipped length (correctness, 2026-07-25):
///   * The region TOTAL (denominator) only needs the summed clipped length:
///     `SUM(rangeEndM - rangeStartM)` over a region's rows.
///   * The DRIVEN length (numerator) must intersect each trip's driven union
///     interval `[startMeters, endMeters]` (also measured along the way) with
///     this region's meter-range. A drive covering only the first half of a
///     boundary-crossing way must credit ONLY the region that half falls in.
///     A scalar clipped length cannot express that; the range can.
///
/// Why this table exists:
///   * The old `recompute()` re-attributed EVERY driven way on every trip by
///     re-parsing cached Overpass tiles + point-in-polygon on the way centroid
///     — growing with all-trips-ever, assigning each whole way to ONE region,
///     and depending on the volatile 50 MB Overpass tile cache (LRU eviction
///     silently dropped ways → coverage regressed).
///   * A way's region membership + meter-ranges are STATIC (geometry never
///     moves), so they are computed ONCE per new wayId (off the UI thread in
///     `CoverageComputeIsolate`, which already holds the admin polygon index)
///     and cached here forever.
///   * Recompute then becomes a pure DB aggregation: per region, driven =
///     Σ overlap(driven-union, [rangeStartM, rangeEndM]); total =
///     Σ (rangeEndM - rangeStartM). Eviction-proof (driven intervals live in
///     `driven_way_intervals`, never evicted) and monotonic (always sums all
///     driven ways).
///
/// Growth is bounded by (distinct driven ways × regions they touch × levels).
/// Most ways fall inside one region at each of the 5 attributed admin levels →
/// ~5 rows per distinct way. Driving the same road N times is still one set of
/// rows.
class WayRegionAttribution extends Table {
  /// OSM way id.
  IntColumn get wayId => integer()();

  /// OSM relation id of the containing admin region, as a string (matches
  /// `CoverageCache.regionId` and `AdminRegion.osmId.toString()`).
  TextColumn get regionId => text()();

  /// OSM admin_level of [regionId] (one of the attributed levels 4/6/8/9/10).
  IntColumn get adminLevel => integer()();

  /// Start offset in meters along the way (from its first node) where this
  /// in-region stretch begins.
  RealColumn get rangeStartM => real()();

  /// End offset in meters along the way where this in-region stretch ends
  /// (`rangeEndM >= rangeStartM`; the stretch length is their difference).
  RealColumn get rangeEndM => real()();

  /// When this attribution row was computed (observability / future TTL).
  DateTimeColumn get computedAt => dateTime().withDefault(currentDateAndTime)();

  /// A way can (rarely) weave out of and back into the same region, producing
  /// multiple disjoint stretches — so the stretch start is part of the key.
  @override
  Set<Column> get primaryKey => {wayId, regionId, rangeStartM};
}
