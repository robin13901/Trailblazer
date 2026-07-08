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
}
