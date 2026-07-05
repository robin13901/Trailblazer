/// Predicate + constants for the admin-boundary relation filter.
///
/// The pipeline extracts OSM `relation`s that represent Germany's
/// administrative boundaries at target `admin_level` values 2/4/6/8/9/10
/// (country / state / district / municipality / borough / suburb).
///
/// See 04-CONTEXT.md > Highway filter, 04-RESEARCH.md §6 admin geometry,
/// and 04-RESEARCH.md §12 pitfall #10 (Berlin/Hamburg/Bremen city-states).
library;

import 'package:osm_pipeline/pbf/entities.dart';

/// Target OSM admin levels the pipeline extracts.
///
/// Chosen per 04-CONTEXT.md and the Roadmap decision: v1 renders regions
/// down to `Ortsteil` (10). Levels 3/5/7 (`Regierungsbezirk` and friends)
/// are intentionally excluded — they are not surfaced in the app.
const Set<int> kTargetAdminLevels = {2, 4, 6, 8, 9, 10};

/// German city-states that appear as both a Bundesland (`admin_level=4`)
/// AND a Gemeinde (`admin_level=6`) in a single OSM relation.
///
/// Matched by `name` (stable across OSM revisions) — the assembler writes
/// them TWICE to `admin_regions_raw`, once at each level. See
/// 04-RESEARCH.md §12 pitfall #10.
const Set<String> kCityStateNames = {'Berlin', 'Hamburg', 'Bremen'};

/// True iff [r] is an administrative-boundary relation the pipeline should
/// extract.
///
/// Accepts either `type=boundary` OR `type=multipolygon` with
/// `boundary=administrative`. Two `type` values are honored because OSM
/// tagging is empirically inconsistent in Germany — many Landkreise carry
/// `type=multipolygon` even though the OSM wiki recommends `type=boundary`.
/// Rejecting `multipolygon` would drop real admin boundaries; downstream
/// pitfalls (self-intersection, missing member ways) are still caught by
/// the assembler.
bool isAdminRelation(OsmRelation r) {
  final t = r.tags['type'];
  if (t != 'boundary' && t != 'multipolygon') return false;
  if (r.tags['boundary'] != 'administrative') return false;
  final lvl = int.tryParse(r.tags['admin_level'] ?? '');
  if (lvl == null) return false;
  return kTargetAdminLevels.contains(lvl);
}
