import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/tables/way_region_attribution_table.dart';
import 'package:drift/drift.dart';

part 'way_region_attribution_dao.g.dart';

/// DAO for the `way_region_attribution` table (schema v8).
///
/// Backs the durable clip-per-region coverage recompute (2026-07-25):
/// * [getAttributedWayIds] — the set of wayIds already clipped+cached, so the
///   compute isolate only attributes NEW ways.
/// * [upsertBatch] — write the clipped-length rows produced for new ways.
/// * [getAllRows] — read every attribution row (recompute joins these against
///   the driven union intervals to produce per-region driven + total length).
/// * [deleteByWayIds] / [deleteAll] — maintenance (a full rebuild clears then
///   re-attributes; way-level delete supports future cache invalidation).
///
/// No FK to `driven_way_intervals`: attribution is way-centric and static, so
/// a row survives trip lifecycle events by design (same policy as the driven
/// intervals table).
@DriftAccessor(tables: [WayRegionAttribution])
class WayRegionAttributionDao extends DatabaseAccessor<AppDatabase>
    with _$WayRegionAttributionDaoMixin {
  WayRegionAttributionDao(super.attachedDatabase);

  /// All attribution rows (`wayId, regionId, adminLevel, rangeStartM,
  /// rangeEndM`). Recompute reads these once and, per region, intersects each
  /// row's `[rangeStartM, rangeEndM]` with the way's driven union intervals in
  /// Dart to produce per-region driven + total length.
  Future<List<WayRegionAttributionData>> getAllRows() {
    return select(wayRegionAttribution).get();
  }

  /// Deduplicated set of wayIds that already have attribution rows, so the
  /// compute isolate can skip re-clipping geometry it has already processed.
  Future<Set<int>> getAttributedWayIds() async {
    final rows = await customSelect(
      'SELECT DISTINCT way_id FROM way_region_attribution',
      readsFrom: {wayRegionAttribution},
    ).get();
    return rows.map((r) => r.read<int>('way_id')).toSet();
  }

  /// Bulk-upsert attribution rows: insert-or-replace on the `(wayId, regionId)`
  /// primary key, so re-attributing a way overwrites its prior clipped length.
  /// No-op on an empty list.
  Future<void> upsertBatch(List<WayRegionAttributionCompanion> rows) {
    if (rows.isEmpty) return Future.value();
    return batch(
      (b) => b.insertAll(
        wayRegionAttribution,
        rows,
        mode: InsertMode.insertOrReplace,
      ),
    );
  }

  /// Delete attribution rows for the given wayIds (cache invalidation).
  Future<int> deleteByWayIds(List<int> wayIds) {
    if (wayIds.isEmpty) return Future.value(0);
    return (delete(wayRegionAttribution)..where((t) => t.wayId.isIn(wayIds)))
        .go();
  }

  /// Clear the whole attribution cache (used by the full rebuild path).
  Future<int> deleteAll() => delete(wayRegionAttribution).go();
}
