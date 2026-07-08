import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/tables/pending_road_fetches_table.dart';
import 'package:drift/drift.dart';

part 'pending_road_fetches_dao.g.dart';

/// DAO for the offline-trip road-fetch queue.
///
/// Consumed by the Wave 2 flow layer (04-15): trip-close bbox pre-fetch
/// enqueues here on network failure; a retry worker drains the queue with
/// exponential backoff, calling [incrementAttempts] on each retry.
///
/// FK cascade on `tripId` (see [PendingRoadFetches] docstring) removes
/// rows automatically when the parent trip is deleted — no manual cleanup
/// required in that path. [removeByTrip] is provided for successful drains.
@DriftAccessor(tables: [PendingRoadFetches])
class PendingRoadFetchesDao extends DatabaseAccessor<AppDatabase>
    with _$PendingRoadFetchesDaoMixin {
  PendingRoadFetchesDao(super.attachedDatabase);

  /// Enqueue a bbox to be re-fetched for [tripId]. Returns the new row id.
  Future<int> enqueue({
    required int tripId,
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
  }) {
    return into(pendingRoadFetches).insert(
      PendingRoadFetchesCompanion.insert(
        tripId: tripId,
        bboxMinLat: minLat,
        bboxMinLon: minLon,
        bboxMaxLat: maxLat,
        bboxMaxLon: maxLon,
      ),
    );
  }

  /// All pending fetches, oldest-first. Empty if none.
  Future<List<PendingRoadFetch>> listPending() {
    return (select(pendingRoadFetches)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  /// Look up the single pending fetch for [tripId], or null.
  Future<PendingRoadFetch?> getByTrip(int tripId) {
    return (select(pendingRoadFetches)
          ..where((t) => t.tripId.equals(tripId)))
        .getSingleOrNull();
  }

  /// Bump `attempts` by 1 and stamp `lastAttemptAt`. Returns rows updated.
  ///
  /// Plan §Deviations authorised falling back to select-then-update if the
  /// `CustomExpression('attempts + 1')` idiom did not compile against
  /// drift ^2.34.0. It does not: `PendingRoadFetchesCompanion.attempts`
  /// takes a `Value<int>`, not an `Expression<int>`. This implementation
  /// runs a small select + write under an implicit transaction (single
  /// DAO call) — one extra read per attempt-bump is acceptable per plan.
  Future<int> incrementAttempts(int id, {DateTime? now}) async {
    final row = await (select(pendingRoadFetches)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return 0;
    return (update(pendingRoadFetches)..where((t) => t.id.equals(id))).write(
      PendingRoadFetchesCompanion(
        attempts: Value(row.attempts + 1),
        lastAttemptAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Remove all pending fetches for [tripId]. Returns rows deleted.
  Future<int> removeByTrip(int tripId) {
    return (delete(pendingRoadFetches)
          ..where((t) => t.tripId.equals(tripId)))
        .go();
  }
}
