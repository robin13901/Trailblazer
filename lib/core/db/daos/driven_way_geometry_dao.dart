import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/tables/driven_way_geometry_table.dart';
import 'package:drift/drift.dart';

part 'driven_way_geometry_dao.g.dart';

/// DAO for the durable per-way OSM geometry cache (schema v10).
///
/// Rows are written once at match time (corridor tiles fresh) and read on
/// every coverage overlay resolve — no network, no tile cache dependency.
@DriftAccessor(tables: [DrivenWayGeometry])
class DrivenWayGeometryDao extends DatabaseAccessor<AppDatabase>
    with _$DrivenWayGeometryDaoMixin {
  DrivenWayGeometryDao(super.attachedDatabase);

  /// Set of wayIds that already have a cached geometry row.
  /// Used to skip re-caching ways that were matched in a previous trip.
  Future<Set<int>> getCachedWayIds() async {
    final rows = await customSelect(
      'SELECT way_id FROM driven_way_geometry',
      readsFrom: {drivenWayGeometry},
    ).get();
    return rows.map((r) => r.read<int>('way_id')).toSet();
  }

  /// All cached geometry rows — the resolver reads these to build the
  /// geomByWayId / nodesByWayId maps for clipDrivenWays().
  Future<List<DrivenWayGeometryData>> getAllRows() {
    return select(drivenWayGeometry).get();
  }

  /// Reactive row count — advances whenever a batch is upserted. The
  /// coverage overlay provider watches this to repaint when new ways are
  /// added (e.g. after a trip match adds new corridor geometries).
  Stream<int> watchRevision() {
    return customSelect(
      'SELECT COUNT(*) AS n FROM driven_way_geometry',
      readsFrom: {drivenWayGeometry},
    ).watchSingle().map((row) => row.read<int>('n'));
  }

  /// Bulk-upsert geometry rows. INSERT OR REPLACE so a re-fetched way
  /// (e.g. after an OSM geometry correction) updates in place.
  /// No-op on an empty list.
  Future<void> upsertBatch(List<DrivenWayGeometryCompanion> rows) {
    if (rows.isEmpty) return Future.value();
    return batch(
      (b) => b.insertAll(
        drivenWayGeometry,
        rows,
        mode: InsertMode.insertOrReplace,
      ),
    );
  }

  /// Clear all cached geometries (full reset — e.g. after a schema change
  /// or if geometry data is suspected corrupt).
  Future<int> deleteAll() => delete(drivenWayGeometry).go();
}
