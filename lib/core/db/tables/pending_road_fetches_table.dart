import 'package:auto_explore/core/db/tables/trips_table.dart';
import 'package:drift/drift.dart';

/// Offline-trip queue for Overpass road-fetches that could not run at
/// trip-close time (no network, throttled by remote, or bbox too large
/// on the current retry budget).
///
/// Consumed by the Wave 2 flow layer (04-15): trip-start pre-fetch
/// coordinator enqueues bboxes here when the network call fails, and a
/// retry worker drains the queue with exponential backoff.
///
/// FK on `tripId` cascades on trip delete — losing a trip discards its
/// pending fetches. Matches the CASCADE policy from `trip_points -> trips`
/// (see Plan 01-02 STATE decision).
@DataClassName('PendingRoadFetch')
class PendingRoadFetches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tripId =>
      integer().references(Trips, #id, onDelete: KeyAction.cascade)();
  RealColumn get bboxMinLat => real()();
  RealColumn get bboxMinLon => real()();
  RealColumn get bboxMaxLat => real()();
  RealColumn get bboxMaxLon => real()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}
