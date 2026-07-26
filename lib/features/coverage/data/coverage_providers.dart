// Trailblazer Phase 6, Plan 06-01 (Wave 1 Task 3):
// Riverpod wiring for the coverage-cache DAO and invalidator.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_invalidator.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Singleton [CoverageCacheDao] — plain `Provider<T>` per STATE 01-01.
final coverageCacheDaoProvider = Provider<CoverageCacheDao>((ref) {
  return CoverageCacheDao(ref.watch(appDatabaseProvider));
});

/// Reactive stream of all `coverage_cache` rows with driven coverage. Re-emits
/// on ANY write to the table (recompute deleteAll+upsert, real-total writes).
///
/// Exposed here (2026-07-25 #8) so the live focus pill can react to coverage
/// recompute without a camera move — it `ref.listen`s this to refresh the
/// shown region's % as soon as new numbers land. The regions tab keeps its own
/// private copy of the same watch.
final coverageCacheStreamProvider =
    StreamProvider<List<CoverageCacheData>>((ref) {
  return ref.watch(coverageCacheDaoProvider).watchAllWithCoverage();
});

/// Singleton [CoverageInvalidator], composing the cache DAO, the
/// admin-region lookup, and the TripsDao (for bbox reads).
final coverageInvalidatorProvider = Provider<CoverageInvalidator>((ref) {
  return CoverageInvalidator(
    cacheDao: ref.watch(coverageCacheDaoProvider),
    regionLookup: ref.watch(adminRegionLookupProvider),
    tripsDao: ref.watch(tripsDaoProvider),
  );
});
