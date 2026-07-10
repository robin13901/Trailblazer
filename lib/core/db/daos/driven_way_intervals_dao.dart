import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/tables/driven_intervals_table.dart';
import 'package:drift/drift.dart';

part 'driven_way_intervals_dao.g.dart';

/// DAO for the `driven_way_intervals` table (schema v3).
///
/// Consumed by the Phase 5 matcher isolate coordinator (Plan 05-07):
/// * [insertBatch] — bulk-write the intervals produced by one HmmMatcher run.
/// * [getByTrip] — read intervals for a trip (used by the golden corpus
///   test harness + Phase 6 inbox).
/// * [deleteByTrip] — cancel path: user deletes an in-flight trip; the
///   coordinator drops any intervals already written.
///
/// FK on `trip_id` is `ON DELETE SET NULL` (Phase-1 decision), so
/// deleting a Trip row does NOT cascade to intervals; the coordinator
/// must call [deleteByTrip] explicitly when cleaning up cancelled trips.
@DriftAccessor(tables: [DrivenWayIntervals])
class DrivenWayIntervalsDao extends DatabaseAccessor<AppDatabase>
    with _$DrivenWayIntervalsDaoMixin {
  DrivenWayIntervalsDao(super.attachedDatabase);

  Future<void> insertBatch(List<DrivenWayIntervalsCompanion> rows) {
    if (rows.isEmpty) return Future.value();
    return batch((b) => b.insertAll(drivenWayIntervals, rows));
  }

  Future<List<DrivenWayInterval>> getByTrip(int tripId) {
    return (select(drivenWayIntervals)
          ..where((t) => t.tripId.equals(tripId))
          ..orderBy([(t) => OrderingTerm.asc(t.matchedAt)]))
        .get();
  }

  Future<int> deleteByTrip(int tripId) {
    return (delete(drivenWayIntervals)..where((t) => t.tripId.equals(tripId)))
        .go();
  }

  /// Returns ALL driven-way interval rows, ordered by `wayId` ascending.
  ///
  /// Used by the Phase-7 geometry resolver to compute per-way coverage
  /// across ALL driven trips (not just one trip). The resolver groups
  /// rows by `wayId` in Dart — avoids a fragile GROUP_CONCAT aggregate.
  ///
  /// No JOIN on trips.status: Phase 6 only writes intervals for trips
  /// that reached the matcher, and both `matched` and `confirmed` statuses
  /// represent "driven" for rendering purposes. Rows whose `tripId` was
  /// SET NULL (after a trip deletion) are included — the driven geometry
  /// is way-centric and survives trip lifecycle events by design
  /// (Plan 01-02 FK cascade policy: driven_intervals -> trips SET NULL).
  Future<List<DrivenWayInterval>> getAllIntervals() {
    return (select(drivenWayIntervals)
          ..orderBy([(t) => OrderingTerm.asc(t.wayId)]))
        .get();
  }

  /// Returns a deduplicated list of all driven way IDs, sorted ascending.
  ///
  /// Convenience query when only the set of wayIds is needed (e.g. to
  /// decide whether to trigger a geometry resolution pass without reading
  /// the full interval payload). The resolver can also derive distinct ids
  /// from `getAllIntervals`, but this avoids materialising row payloads.
  Future<List<int>> getDistinctWayIds() async {
    final rows = await customSelect(
      'SELECT DISTINCT way_id FROM driven_way_intervals ORDER BY way_id',
      readsFrom: {drivenWayIntervals},
    ).get();
    return rows.map((r) => r.read<int>('way_id')).toList();
  }
}
