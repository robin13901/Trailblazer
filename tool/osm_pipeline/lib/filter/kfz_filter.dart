/// Kfz way predicate + tag retention for the pipeline's Stage B filter.
library;

import 'package:osm_pipeline/filter/highway_class.dart';
import 'package:osm_pipeline/pbf/entities.dart';

/// Returns true if [w] is a Kfz way per OSM-02 (14-tag allowlist).
bool isKfzWay(OsmWay w) {
  final hw = w.tags['highway'];
  return hw != null && kKfzHighwayTags.contains(hw);
}

/// Returns the tag subset retained for Kfz ways in `ways_raw`.
///
/// Kept per 04-CONTEXT "Highway filter & tag retention":
/// `highway`, `name`, `ref`, `oneway`, `maxspeed`. `surface` is deliberately
/// NOT retained for Kfz — Feldweg-only per 04-RESEARCH §4.
Map<String, String> retainKfzTags(OsmWay w) {
  const kept = {'highway', 'name', 'ref', 'oneway', 'maxspeed'};
  final out = <String, String>{};
  for (final k in kept) {
    final v = w.tags[k];
    if (v != null) out[k] = v;
  }
  return out;
}
