// Trailblazer Phase 8, Plan 08-05 (Wave 2):
// Region browser Riverpod providers — coverage-gated flat list + fuzzy search.
// Plain Provider/FutureProvider/NotifierProvider — NO @Riverpod codegen.
// StateProvider was removed in flutter_riverpod 3.x; using NotifierProvider
// with a simple Notifier<String> following the MapControllerNotifier pattern
// (STATE Plan 02-03).
// Package imports only (very_good_analysis always_use_package_imports).

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
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

/// FutureProvider that loads ALL regions with coverage > 0%, sorted by
/// coverage % descending. Level 2 (Germany country) is excluded — it would
/// accumulate the entire DE road network and is never a useful card.
///
/// Join: coverage_cache row (driven_length_m > 0) → AdminRegionLookup.regionByOsmId
/// → RegionCoverage value type.
final regionBrowserProvider = FutureProvider<List<RegionCoverage>>((ref) async {
  final lookup = ref.watch(adminRegionLookupProvider);
  await lookup.ensureLoaded(); // main isolate — RESEARCH Pitfall 1
  final dao = ref.watch(coverageCacheDaoProvider);
  final rows = await dao.getAllWithCoverage();
  final out = <RegionCoverage>[];
  for (final row in rows) {
    final osmId = int.tryParse(row.regionId);
    if (osmId == null) continue;
    final region = lookup.regionByOsmId(osmId);
    if (region == null) continue; // stale row without a polygon
    if (region.adminLevel == 2) continue; // exclude Deutschland (RESEARCH 273)
    out.add(
      RegionCoverage(
        osmId: osmId,
        adminLevel: region.adminLevel,
        name: region.nameDe ?? region.name,
        drivenLengthM: row.drivenLengthM,
        totalLengthM: row.totalLengthM,
      ),
    );
  }
  // %-descending sort (CONTEXT.md line 35).
  out.sort((a, b) => b.percent.compareTo(a.percent));
  return out;
});

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
