import 'package:drift/drift.dart';

/// Durable per-way OSM geometry cache (schema v10).
///
/// One row per gefahrenem OSM way: raw geometry + parallel OSM node IDs,
/// stored once at match time when the Overpass tile is freshly cached.
///
/// Why this table exists (2026-08-15):
///   Coverage line rendering needs the OSM polyline + node topology for
///   every driven way to run clipDrivenWays(). Previously the resolver
///   re-fetched these from the volatile 50 MB LRU Overpass tile cache on
///   every render — but the union bbox of all trips (~144 tiles, ~47 MB)
///   never fit entirely, so LRU kept evicting tiles and the line was always
///   gappy or required a network re-fetch.
///
///   OSM geometry is STATIC (a way's shape does not change), so it is
///   computed ONCE at match time (corridor tiles are fresh in cache) and
///   stored here forever — exactly like way_region_attribution for the
///   coverage percentages. The resolver then reads geometry directly from
///   this table: no tiles, no network, no LRU interaction, instant.
///
/// Inkrementell: a new trip adds only the new wayIds; existing rows are
/// never updated (geometry is static). A re-match does not touch this
/// table either — only intervals change.
class DrivenWayGeometry extends Table {
  /// OSM way id (primary key — one row per way, ever).
  IntColumn get wayId => integer()();

  /// Way geometry as a compact JSON array: `[[lat,lon],…]`.
  /// Minimum 2 points (enforced by WayCandidate invariant).
  TextColumn get geometryJson => text()();

  /// Parallel OSM node IDs as a JSON array: `[nodeId,…]`.
  /// Same length as geometry when available; `"[]"` when the source did
  /// not supply node IDs (fallback — stitching is then coordinate-based).
  TextColumn get nodeIdsJson => text().withDefault(const Constant('[]'))();

  /// When this row was first written (observability).
  DateTimeColumn get cachedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {wayId};
}
