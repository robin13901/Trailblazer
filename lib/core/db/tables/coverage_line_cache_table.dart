import 'package:drift/drift.dart';

/// Durable cache of the rendered coverage LINE geometry (schema v9).
///
/// A single row (always `id = 1`) holding the complete clipped coverage line —
/// every driven OSM way clipped to its driven union interval(s), deduped +
/// topology-stitched across all trips — serialized as one JSON blob (see
/// `coverage_line_codec.dart`).
///
/// Why this table exists (2026-08-13):
///   The coverage line was rendered by re-parsing + re-clipping the raw
///   Overpass tiles on EVERY resolve (`DrivenWayGeometryResolver`). Those tiles
///   live in the volatile 50 MB LRU `overpass_way_cache`; the union bbox of all
///   trips spans ~144 z12 tiles (~47 MB) which never all fit at once. LRU kept
///   evicting driven-way tiles, so the line was permanently gappy and every app
///   launch re-fetched tiles from throttled Overpass (1 tile/min) — the tiles
///   "breathed" in and out and the line never stabilised.
///
///   The clipped line is instead computed ONCE (at match/re-match, when the
///   corridor tiles are freshly cached) and stored here forever, exactly like
///   `way_region_attribution` does for the coverage PERCENTAGES. Reading it is a
///   single DB read — instant, no network, no parsing, immune to LRU eviction.
///
/// [intervalsRevision] records the `driven_way_intervals` revision (MAX(id) +
/// COUNT — see `DrivenWayIntervalsDao.watchRevision`) the blob was computed
/// against, so the resolver can tell whether the cached line is still current
/// without re-clipping. When a new drive advances the revision, the resolver
/// recomputes + overwrites this row.
class CoverageLineCache extends Table {
  /// Single-row key — always 1 (this is a key-value slot, not a per-way table).
  IntColumn get id => integer().withDefault(const Constant(1))();

  /// The full clipped coverage line as a JSON blob (see coverage_line_codec).
  TextColumn get linesJson => text()();

  /// The `driven_way_intervals` revision this blob was computed against.
  IntColumn get intervalsRevision => integer()();

  /// When this blob was computed (observability).
  DateTimeColumn get computedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
