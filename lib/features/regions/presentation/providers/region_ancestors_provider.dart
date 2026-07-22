// Trailblazer — upward admin-hierarchy breadcrumb for the region detail sheet
// (on-device feedback 2026-07-22).
//
// The bundled admin data carries NO parent/child linkage — each region is an
// isolated polygon tagged only with its own admin_level. So we resolve the
// ancestor chain by CONTAINMENT: take an interior point of the tapped region
// (its label point, guaranteed inside the region and therefore inside every
// region that contains it) and ask AdminRegionLookup.regionAt() which region
// at each coarser level contains that point.
//
// Bundled levels are {4,6,8,9,10}; there is NO L5 (Regierungsbezirk) and NO L2
// (country) polygon. So the chain covers Bundesland (4) / Landkreis (6) /
// Gemeinde (8) / Ortsteil (9), and "Deutschland" is prepended as a fixed top
// (exactly as the focus pill special-cases the missing country polygon).

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

/// One entry in the upward hierarchy breadcrumb.
@immutable
class RegionCrumb {
  const RegionCrumb({required this.name, required this.level});

  /// Display name (German-preferred). "Deutschland" for the synthetic top.
  final String name;

  /// OSM admin_level, or 2 for the synthetic "Deutschland" top.
  final int level;

  @override
  bool operator ==(Object other) =>
      other is RegionCrumb && other.name == name && other.level == level;

  @override
  int get hashCode => Object.hash(name, level);
}

/// Candidate ancestor levels, coarsest → finest. Filtered per region to those
/// strictly coarser than the region's own level. L5/L2 are absent from the
/// bundle (see file header), so they never appear here.
const List<int> _ancestorLevels = [4, 6, 8, 9];

/// Resolves the upward admin hierarchy for a tapped region, keyed by its OSM
/// relation id. Returns crumbs ordered top-down (Deutschland → … → nearest
/// parent), EXCLUDING the region itself (the sheet header already shows it).
///
/// Returns an empty list when the region can't be resolved (e.g. bundle not
/// loaded / id not found) — the sheet then simply omits the breadcrumb.
///
/// The provider's concrete type (`FutureProviderFamily`) is internal to
/// Riverpod, so the type is left inferred here.
// ignore: specify_nonobvious_property_types
final regionAncestorsProvider =
    FutureProvider.family<List<RegionCrumb>, int>((ref, osmId) async {
  final lookup = ref.watch(adminRegionLookupProvider);
  await lookup.ensureLoaded();

  final self = lookup.regionByOsmId(osmId);
  if (self == null) return const [];

  // An interior point of the region — guaranteed inside every containing
  // (coarser) region, so containment tests upward always resolve.
  final seed = self.labelPoint; // [lat, lon]
  final seedLat = seed[0];
  final seedLon = seed[1];

  final crumbs = <RegionCrumb>[];
  final seenOsmIds = <int>{self.osmId};

  for (final level in _ancestorLevels) {
    if (level >= self.adminLevel) continue; // only strictly-coarser ancestors
    final parent = await lookup.regionAt(seedLat, seedLon, level);
    if (parent == null) continue;
    if (!seenOsmIds.add(parent.osmId)) continue; // dedupe
    crumbs.add(
      RegionCrumb(name: parent.nameDe ?? parent.name, level: parent.adminLevel),
    );
  }

  // Fixed country top — no L2 polygon exists in the bundle, and every bundled
  // region lies within Germany (matches focus_pill_provider's Deutschland
  // fallback). Always prepended: even a lone Bundesland (no coarser ancestor
  // in the bundle) then correctly reads "Deutschland" above it.
  crumbs.insert(0, const RegionCrumb(name: 'Deutschland', level: 2));

  return crumbs;
});
