// Trailblazer Phase 6, Plan 06-01 (Wave 1 Task 2):
// CoverageCacheDao — the sole write/read path for the `coverage_cache`
// table (physical name; REQUIREMENTS.md refers to this table as
// `coverage_by_region` — logical alias). Schema stays at v3; no table
// definition changes here.
//
// Follows the plain `DatabaseAccessor<AppDatabase>` pattern used by
// `TripsDao` (see STATE Plan 03-01) instead of `@DriftAccessor(tables:)`
// — no codegen, no `part` file, drops in without touching
// `app_database.dart`'s `daos:` list.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:drift/drift.dart';

/// CRUD over `coverage_cache`.
///
/// Row class is Drift-generated [CoverageCacheData] (Drift's default row
/// type; `CoverageCache` is the *table* class). Callers wire this DAO in
/// via `coverageCacheDaoProvider` (see `coverage_providers.dart`); direct
/// construction is reserved for tests that inject a
/// `NativeDatabase.memory()`-backed [AppDatabase].
class CoverageCacheDao extends DatabaseAccessor<AppDatabase> {
  CoverageCacheDao(super.attachedDatabase);

  $CoverageCacheTable get _table => attachedDatabase.coverageCache;

  /// Insert or replace the row for [regionId]. Used by the Phase-8
  /// recompute pass — ships now for symmetry so Phase 8 does not need to
  /// reopen this DAO.
  Future<void> upsert({
    required String regionId,
    required double drivenLengthM,
    required double totalLengthM,
    required DateTime updatedAt,
    String? extractVersion,
  }) {
    return into(_table).insertOnConflictUpdate(
      CoverageCacheCompanion.insert(
        regionId: regionId,
        drivenLengthM: Value(drivenLengthM),
        totalLengthM: Value(totalLengthM),
        updatedAt: Value(updatedAt),
        extractVersion: Value(extractVersion),
      ),
    );
  }

  /// Point-read; null when the row does not exist.
  Future<CoverageCacheData?> getByRegionId(String regionId) {
    return (select(_table)..where((r) => r.regionId.equals(regionId)))
        .getSingleOrNull();
  }

  /// Write the REAL total road length (meters) computed by
  /// `RegionTotalLengthService` for [regionId], stamping the compute time.
  /// Upserts so a region row is created if the recompute pass hasn't run yet.
  /// Also clears `realTotalProgressJson` — the region is fully computed, so the
  /// resumable-compute accumulator is no longer needed.
  Future<void> writeRealTotalLength({
    required String regionId,
    required double realTotalLengthM,
    required DateTime computedAt,
  }) {
    return into(_table).insertOnConflictUpdate(
      CoverageCacheCompanion.insert(
        regionId: regionId,
        realTotalLengthM: Value(realTotalLengthM),
        realTotalUpdatedAt: Value(computedAt),
        realTotalProgressJson: const Value(null),
      ),
    );
  }

  /// Reads the resumable-compute progress blob for [regionId] (null when no
  /// pass is in flight). See `RegionTotalLengthService` for the JSON shape.
  Future<String?> readRealTotalProgress(String regionId) async {
    final row = await getByRegionId(regionId);
    return row?.realTotalProgressJson;
  }

  /// Persists the resumable-compute progress blob for [regionId]. Upserts so a
  /// region row is created if the recompute pass hasn't run yet.
  Future<void> writeRealTotalProgress({
    required String regionId,
    required String progressJson,
  }) {
    return into(_table).insertOnConflictUpdate(
      CoverageCacheCompanion.insert(
        regionId: regionId,
        realTotalProgressJson: Value(progressJson),
      ),
    );
  }

  /// All rows that have driven coverage but no real total computed yet
  /// (`real_total_length_m IS NULL`). These are the regions the background
  /// `RegionTotalLengthService` still needs to process — each drives a
  /// per-region spinner in the browser until its real total lands.
  Future<List<CoverageCacheData>> getRegionsNeedingRealTotal() {
    return (select(_table)
          ..where(
            (r) =>
                r.drivenLengthM.isBiggerThanValue(0) &
                r.realTotalLengthM.isNull(),
          ))
        .get();
  }

  /// Batch-delete rows whose `region_id` is in [regionIds]. Returns the
  /// number of rows removed. Empty-input fast-path returns 0 without
  /// issuing SQL — guards SQLite's "empty IN list" error.
  Future<int> deleteByRegionIds(Iterable<String> regionIds) async {
    final ids = regionIds.toList(growable: false);
    if (ids.isEmpty) return 0;
    return (delete(_table)..where((r) => r.regionId.isIn(ids))).go();
  }

  /// Truncate the cache. OSM-extract-updated stub trigger 3 in P6; the
  /// P10 admin-swap flow will call this. Returns rows removed.
  Future<int> deleteAll() => delete(_table).go();

  /// All cached rows with any driven coverage (driven_length_m > 0), for the
  /// Phase-8 region browser. Names/levels are resolved from AdminRegionLookup
  /// by the caller (no region_name column — RESEARCH.md line 227).
  Future<List<CoverageCacheData>> getAllWithCoverage() {
    return (select(_table)
          ..where((r) => r.drivenLengthM.isBiggerThanValue(0)))
        .get();
  }

  /// Bump `invalidation_gen` by 1 without touching lengths — Phase-8
  /// path where the cache is marked stale but the row survives until
  /// recompute overwrites it. P6 does not use this method itself.
  Future<void> bumpInvalidationGen(String regionId) async {
    await customUpdate(
      'UPDATE coverage_cache '
      'SET invalidation_gen = invalidation_gen + 1 '
      'WHERE region_id = ?',
      variables: [Variable<String>(regionId)],
      updates: {_table},
      updateKind: UpdateKind.update,
    );
  }
}
