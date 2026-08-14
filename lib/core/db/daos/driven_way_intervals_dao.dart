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
    return (delete(
      drivenWayIntervals,
    )..where((t) => t.tripId.equals(tripId))).go();
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
    return (select(
      drivenWayIntervals,
    )..orderBy([(t) => OrderingTerm.asc(t.wayId)])).get();
  }

  /// A strictly-changing revision number that advances on ANY write to
  /// `driven_way_intervals` (insert, delete, re-match).
  ///
  /// `MAX(id)` uses the table's autoincrement PK, which is monotonic and never
  /// reuses ids — so every insert bumps it, INCLUDING a re-match's delete-then-
  /// insert (the new rows get fresh higher ids). `COUNT(*)` is added so a pure
  /// delete (e.g. a trip removed, no reinsert) also changes the value.
  ///
  /// **Why this exists (2026-07-30):** the coverage overlay's reactive trigger
  /// was keyed on `TripsDao.watchUnionBbox()`, whose emitted `LatLngBounds` has
  /// VALUE equality. A trip driven WITHIN the already-covered union bbox
  /// re-emits an EQUAL bounds; Riverpod's `ref.watch` then deduplicates it and
  /// the overlay `async*` never re-resolves — so freshly matched roads did not
  /// repaint until an app restart (coverage % still updated, because that path
  /// watches `coverage_cache` directly). Watching THIS monotonic revision
  /// alongside the bounds guarantees the observed value changes on every
  /// interval write, closing the dedup gap. Table-write invalidation via
  /// `readsFrom` is the mechanism — do NOT collapse it to a value-diff.
  Stream<int> watchRevision() {
    return customSelect(
      'SELECT COALESCE(MAX(id), 0) + COUNT(*) AS rev FROM driven_way_intervals',
      readsFrom: {drivenWayIntervals},
    ).watchSingle().map((row) => row.read<int>('rev'));
  }

  /// One-shot read of the current revision (same expression as [watchRevision]).
  /// Used by the durable coverage-line cache to decide whether the stored blob
  /// is still current without re-clipping geometry.
  Future<int> getRevision() async {
    final row = await customSelect(
      'SELECT COALESCE(MAX(id), 0) + COUNT(*) AS rev FROM driven_way_intervals',
      readsFrom: {drivenWayIntervals},
    ).getSingle();
    return row.read<int>('rev');
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

  /// Returns the distinct non-null `trip_id`s that currently have stored
  /// intervals, sorted ascending. Used by the one-shot re-match migration
  /// (`TripMatchCoordinator.rematchAllStoredTrips`) to find which already-
  /// matched trips need reprocessing after a matcher-algorithm change. Rows
  /// whose `trip_id` was SET NULL (trip deleted) are excluded — there is no
  /// trip left to re-match.
  Future<List<int>> getDistinctTripIds() async {
    final rows = await customSelect(
      'SELECT DISTINCT trip_id FROM driven_way_intervals '
      'WHERE trip_id IS NOT NULL ORDER BY trip_id',
      readsFrom: {drivenWayIntervals},
    ).get();
    return rows.map((r) => r.read<int>('trip_id')).toList();
  }
}
