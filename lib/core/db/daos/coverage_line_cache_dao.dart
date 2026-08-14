import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/tables/coverage_line_cache_table.dart';
import 'package:drift/drift.dart';

part 'coverage_line_cache_dao.g.dart';

/// DAO for the durable coverage-LINE geometry blob (schema v9).
///
/// Single-row table (`id = 1`) — see [CoverageLineCache]. The blob is the
/// complete clipped coverage line for all trips; the resolver reads it on app
/// launch (instant, no tile access) and overwrites it after a new drive.
@DriftAccessor(tables: [CoverageLineCache])
class CoverageLineCacheDao extends DatabaseAccessor<AppDatabase>
    with _$CoverageLineCacheDaoMixin {
  CoverageLineCacheDao(super.attachedDatabase);

  /// Read the single cache row, or null when the line has never been computed.
  Future<CoverageLineCacheData?> getRow() {
    return (select(
      coverageLineCache,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
  }

  /// Reactive single-row read — re-emits whenever the blob is (re)written, so
  /// the overlay repaints live after a match without a tab-switch or restart.
  Stream<CoverageLineCacheData?> watchRow() {
    return (select(
      coverageLineCache,
    )..where((t) => t.id.equals(1))).watchSingleOrNull();
  }

  /// Insert-or-replace the single row (id = 1) with a fresh blob + the
  /// `driven_way_intervals` revision it was computed against.
  Future<void> put({
    required String linesJson,
    required int intervalsRevision,
    DateTime? now,
  }) {
    return into(coverageLineCache).insertOnConflictUpdate(
      CoverageLineCacheCompanion.insert(
        id: const Value(1),
        linesJson: linesJson,
        intervalsRevision: intervalsRevision,
        computedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Clear the cached line (used when trips are deleted / full reset).
  Future<int> deleteAll() => delete(coverageLineCache).go();
}
