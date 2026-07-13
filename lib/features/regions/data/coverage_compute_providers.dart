// Trailblazer Phase 8, Plan 08-02 (Wave 1):
// Riverpod provider for CoverageComputeService.
//
// Plain Provider<T> — no @Riverpod codegen (STATE Plan 01-01).
// Wires all five collaborators from their existing singleton providers.

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/region_total_length_service.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Singleton [CoverageComputeService] — plain `Provider<T>` per STATE 01-01.
///
/// Fire-and-forget: callers do `unawaited(ref.read(coverageComputeServiceProvider).recompute())`
/// after the coverage invalidator runs (Phase 8 hook in confirmTrip).
final coverageComputeServiceProvider = Provider<CoverageComputeService>((ref) {
  return CoverageComputeService(
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
    waySource: ref.watch(wayCandidateSourceProvider),
    regionLookup: ref.watch(adminRegionLookupProvider),
    cacheDao: ref.watch(coverageCacheDaoProvider),
    tripsDao: ref.watch(tripsDaoProvider),
  );
});

/// Singleton [RegionTotalLengthService] — computes the REAL per-region total
/// road length (tiled area-clipped Overpass sums), cached once per region.
final regionTotalLengthServiceProvider =
    Provider<RegionTotalLengthService>((ref) {
  return RegionTotalLengthService(
    regionLookup: ref.watch(adminRegionLookupProvider),
    overpassClient: ref.watch(overpassClientProvider),
    cacheDao: ref.watch(coverageCacheDaoProvider),
  );
});
