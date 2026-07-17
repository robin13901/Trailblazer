// Trailblazer Phase 8, Plan 08-02 (Wave 1) / updated Phase 10, Plan 10-04:
// Riverpod providers for CoverageComputeService.
//
// Plain Provider<T> — no @Riverpod codegen (STATE Plan 01-01).
// Wires all collaborators from their existing singleton providers.
//
// Plan 10-04 change: RegionTotalsLookup injected; regionTotalLengthServiceProvider
// REMOVED (runtime Overpass totals path deleted — Decision 8).

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
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
    totalsLookup: ref.watch(regionTotalsLookupProvider),
  );
});
