/// Directionality normalization for Kfz ways (04-RESEARCH §5).
///
/// Storage convention: after normalization, `is_directional=1` ALWAYS means
/// "forward along the stored node order". `oneway=-1` ways are physically
/// reversed at parse time so downstream stages need not remember the twist
/// (04-RESEARCH §12 pitfall #7).
library;

import 'package:osm_pipeline/filter/highway_class.dart';
import 'package:osm_pipeline/pbf/entities.dart';

/// The normalized directionality of an OSM way after applying the rules in
/// 04-RESEARCH §5 (raw `oneway` tag + implicit-oneway highway classes).
class NormalizedDirection {
  /// Create a normalized direction record.
  const NormalizedDirection({
    required this.isDirectional,
    required this.nodeIds,
  });

  /// `true` when the way is one-way in the forward direction of [nodeIds].
  final bool isDirectional;

  /// Node ids in traversal order. For `oneway=-1` inputs this list is the
  /// REVERSED sequence of the raw OSM node refs.
  final List<int> nodeIds;
}

/// Applies the pipeline's directionality rules to [w].
///
/// Rules (locked here, not left to matcher):
///   * `oneway=yes`  → `isDirectional=true`, node order preserved.
///   * `oneway=-1`   → `isDirectional=true`, node order PHYSICALLY REVERSED.
///   * `oneway=no`   → `isDirectional=false`, node order preserved.
///   * missing tag   → apply implicit-oneway rule per [kImplicitOnewayKfzTags]
///                     (motorway / motorway_link / trunk_link only).
NormalizedDirection normalizeDirectionality(OsmWay w) {
  final ow = w.tags['oneway'];
  final hw = w.tags['highway'];
  switch (ow) {
    case 'yes':
      return NormalizedDirection(isDirectional: true, nodeIds: w.nodeRefs);
    case '-1':
      return NormalizedDirection(
        isDirectional: true,
        nodeIds: w.nodeRefs.reversed.toList(),
      );
    case 'no':
      return NormalizedDirection(isDirectional: false, nodeIds: w.nodeRefs);
    default:
      final implicit = kImplicitOnewayKfzTags.contains(hw);
      return NormalizedDirection(
        isDirectional: implicit,
        nodeIds: w.nodeRefs,
      );
  }
}
