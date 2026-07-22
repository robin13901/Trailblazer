// Trailblazer Phase 8, Plan 08-02 (Wave 1) / updated Phase 10, Plan 10-04:
// Riverpod providers for CoverageComputeService.
//
// Plain Provider<T> — no @Riverpod codegen (STATE Plan 01-01).
// Wires all collaborators from their existing singleton providers.
//
// Plan 10-04 change: RegionTotalsLookup injected; regionTotalLengthServiceProvider
// REMOVED (runtime Overpass totals path deleted — Decision 8).
//
// 2026-07-22: the heavy recompute attribution runs OFF the UI isolate via
// CoverageComputeIsolate (mirrors matcherIsolateProvider). The service is
// injected with the isolate's computeAttribution as its runner and its start()
// as the warm-up hook; all three .recompute() call sites are unchanged.

import 'dart:async';

import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_isolate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Long-lived [CoverageComputeIsolate] — mirrors `matcherIsolateProvider`.
///
/// `start()` is fired fire-and-forget at construction (the isolate spawns +
/// parses its polygon index in the background); `dispose()` is bound to the
/// container teardown. The isolate reads the admin + totals asset bytes on the
/// main isolate (rootBundle is unreachable off-isolate) via the extracted
/// `loadAdminBundleBytes` / `loadRegionTotalsBytes` helpers (docs-dir override
/// preserved), then ships them once to the worker.
final coverageComputeIsolateProvider = Provider<CoverageComputeIsolate>((ref) {
  final isolate = CoverageComputeIsolate(
    loadAdminBytes: loadAdminBundleBytes,
    loadTotalsBytes: loadRegionTotalsBytes,
  );
  // Eager warm-up, but swallow errors here: start() rethrows on failure (e.g.
  // rootBundle unavailable in a bare-container unit test) and this is
  // fire-and-forget, so an uncaught error would fail unrelated tests. The
  // first recompute() awaits start() again (single-flight retry) and surfaces
  // any real failure through its Result.
  unawaited(isolate.start().catchError((Object _) {}));
  ref.onDispose(isolate.dispose);
  return isolate;
});

/// Singleton [CoverageComputeService] — plain `Provider<T>` per STATE 01-01.
///
/// Fire-and-forget: callers do `unawaited(ref.read(coverageComputeServiceProvider).recompute())`
/// after the coverage invalidator runs (Phase 8 hook in confirmTrip).
final coverageComputeServiceProvider = Provider<CoverageComputeService>((ref) {
  final isolate = ref.watch(coverageComputeIsolateProvider);
  return CoverageComputeService(
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
    waySource: ref.watch(wayCandidateSourceProvider),
    regionLookup: ref.watch(adminRegionLookupProvider),
    cacheDao: ref.watch(coverageCacheDaoProvider),
    tripsDao: ref.watch(tripsDaoProvider),
    totalsLookup: ref.watch(regionTotalsLookupProvider),
    compute: (gzippedTiles, tileBboxes, intervalsByWayId) =>
        isolate.computeAttribution(
      gzippedTiles: gzippedTiles,
      tileBboxes: tileBboxes,
      intervalsByWayId: intervalsByWayId,
    ),
    ensureComputeReady: isolate.start,
  );
});
