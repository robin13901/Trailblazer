// Trailblazer Phase 8, Plan 08-05 (Wave 2):
// Region browser Riverpod providers — coverage-gated flat list + fuzzy search.
// Plain Provider/FutureProvider/NotifierProvider — NO @Riverpod codegen.
// StateProvider was removed in flutter_riverpod 3.x; using NotifierProvider
// with a simple Notifier<String> following the MapControllerNotifier pattern
// (STATE Plan 02-03).
// Package imports only (very_good_analysis always_use_package_imports).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/domain/region_tiling.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// Search query state
// ---------------------------------------------------------------------------

/// Holds the current search text for the region browser.
///
/// Getter/setter pair satisfies `use_setters_to_change_properties` lint —
/// matches the `MapControllerNotifier` pattern (STATE Plan 02-03).
class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  /// Current search query.
  String get query => state;

  /// Update the search query. Callers: `ref.read(regionSearchQueryProvider.notifier).query = value`.
  set query(String value) => state = value;
}

/// Provider for the current search text. Empty string = no filter.
final regionSearchQueryProvider =
    NotifierProvider<SearchQueryNotifier, String>(SearchQueryNotifier.new);

// ---------------------------------------------------------------------------
// Browser list providers
// ---------------------------------------------------------------------------

/// Raw reactive stream of `coverage_cache` rows with driven coverage. Wrapping
/// the Drift `.watch()` in its own StreamProvider (rather than `yield*`-ing it
/// from an `async*` body) mirrors the proven `coveragePathsProvider` pattern
/// and keeps the join provider below simple + synchronous per emit.
final _coverageRowsProvider =
    StreamProvider<List<CoverageCacheData>>((ref) {
  return ref.watch(coverageCacheDaoProvider).watchAllWithCoverage();
});

/// StreamProvider that loads ALL regions with coverage > 0%, sorted by
/// coverage % descending, and RE-EMITS whenever `coverage_cache` is written —
/// so a region's spinner clears on its own the moment its real total lands and
/// its progress count climbs live, with no tab-switch. Level 2 (Germany
/// country) is excluded — it would accumulate the entire DE road network and is
/// never a useful card.
///
/// The one-time `ensureLoaded()` is awaited before the first emit;
/// `regionByOsmId` is synchronous, so each emit maps synchronously.
final regionBrowserProvider =
    StreamProvider<List<RegionCoverage>>((ref) async* {
  final lookup = ref.watch(adminRegionLookupProvider);
  await lookup.ensureLoaded(); // main isolate — RESEARCH Pitfall 1
  final rows = ref.watch(_coverageRowsProvider).value;
  yield rows == null ? const <RegionCoverage>[] : _buildRegionList(rows, lookup);
});

/// Joins raw `coverage_cache` rows with admin geometry into the sorted
/// browser list. Pure + synchronous (regionByOsmId is sync) so it can run on
/// every stream emit. Pending regions carry live compute progress.
List<RegionCoverage> _buildRegionList(
  List<CoverageCacheData> rows,
  AdminRegionLookup lookup,
) {
  final out = <RegionCoverage>[];
  for (final row in rows) {
    final osmId = int.tryParse(row.regionId);
    if (osmId == null) continue;
    final region = lookup.regionByOsmId(osmId);
    if (region == null) continue; // stale row without a polygon
    if (region.adminLevel == 2) continue; // exclude Deutschland (RESEARCH 273)
    final realTotal = row.realTotalLengthM;
    final pending = realTotal == null;
    out.add(
      RegionCoverage(
        osmId: osmId,
        adminLevel: region.adminLevel,
        name: region.nameDe ?? region.name,
        drivenLengthM: row.drivenLengthM,
        // Prefer the real region-wide total; fall back to the legacy bbox
        // total until it lands.
        totalLengthM: realTotal ?? row.totalLengthM,
        totalPending: pending,
        // Live compute progress (only meaningful while pending): cells summed
        // so far (from the accumulator blob) and cells planned (from the bbox).
        progressCellsDone:
            pending ? completedCellCount(row.realTotalProgressJson) : null,
        progressCellsPlanned: pending
            ? plannedCellCount(
                region.bboxMinLat,
                region.bboxMinLon,
                region.bboxMaxLat,
                region.bboxMaxLon,
              )
            : null,
      ),
    );
  }
  // %-descending sort (CONTEXT.md line 35). Pending rows sort by their
  // fallback %, which is fine — they reorder once the real total lands.
  out.sort((a, b) => b.percent.compareTo(a.percent));
  return out;
}

/// Derived provider that applies the fuzzy search on top of the loaded list.
/// Pure-Dart ranking (RESEARCH lines 89-92):
///   starts-with match ranks above contains-anywhere; empty query = full list.
/// Each sub-list is already %-descending from [regionBrowserProvider].
final regionBrowserFilteredProvider = Provider<List<RegionCoverage>>((ref) {
  final all = ref.watch(regionBrowserProvider).value ?? const <RegionCoverage>[];
  final q = ref.watch(regionSearchQueryProvider).trim().toLowerCase();
  if (q.isEmpty) return all;
  final starts = <RegionCoverage>[];
  final contains = <RegionCoverage>[];
  for (final r in all) {
    final n = r.name.toLowerCase();
    if (n.startsWith(q)) {
      starts.add(r);
    } else if (n.contains(q)) {
      contains.add(r);
    }
  }
  return [...starts, ...contains]; // ranked; each sub-list already %-desc
});
