import 'package:drift/drift.dart';

/// Compressed Overpass response cache, keyed by slippy z12 tile ID.
///
/// Populated by the Wave 2 way-candidate source (04-15) so re-driving the same
/// road doesn't re-hit the shared Overpass server. TTL is enforced by
/// `sweepTtl` (30 days) and total on-disk size by `_enforceLruBudget`
/// (50 MB high water → 40 MB low water).
///
/// Payload column stores the raw gzipped Overpass JSON blob — parsing back
/// into `WayCandidate` domain objects is the reader's responsibility. This
/// keeps the cache format stable across parser changes and cheap to write.
class OverpassWayCache extends Table {
  IntColumn get tileZ => integer()();
  IntColumn get tileX => integer()();
  IntColumn get tileY => integer()();
  DateTimeColumn get fetchedAt =>
      dateTime().withDefault(currentDateAndTime)();
  IntColumn get wayCount => integer()();
  BlobColumn get payloadGzip => blob()();
  IntColumn get payloadBytes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {tileZ, tileX, tileY};
}
