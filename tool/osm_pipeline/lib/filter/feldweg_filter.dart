/// Feldweg / Fußweg carve-out per 04-RESEARCH §4.
///
/// The set is intentionally small — a "nice-to-see" dashed line on the map,
/// NOT a coverage metric. Feldweg rows are tagged `is_counting=0` in
/// `osm.sqlite` so they do not inflate Phase 8 coverage %.
library;

import 'package:osm_pipeline/pbf/entities.dart';

/// Returns the retained-tag subset for [w] if it qualifies as a Feldweg,
/// or `null` if [w] should be rejected.
///
/// Accepts:
///   * `highway=track` — Wirtschaftsweg, drivable by DE convention.
///   * `highway=path`  AND `motor_vehicle IN (yes, permissive)`.
///   * `highway=service` AND `service IN (driveway, alley)`.
///
/// Rejects everything else (in particular `footway`, `cycleway`,
/// `pedestrian`, `bridleway` — non-drivable by definition in DE).
Map<String, String>? feldwegTagsOrNull(OsmWay w) {
  final hw = w.tags['highway'];
  switch (hw) {
    case 'track':
      return _pick(w, const {'highway', 'name', 'surface'});
    case 'path':
      final mv = w.tags['motor_vehicle'];
      if (mv == 'yes' || mv == 'permissive') {
        return _pick(w, const {'highway', 'name', 'surface', 'motor_vehicle'});
      }
      return null;
    case 'service':
      final svc = w.tags['service'];
      if (svc == 'driveway' || svc == 'alley') {
        return _pick(w, const {'highway', 'name', 'surface', 'service'});
      }
      return null;
    default:
      return null;
  }
}

Map<String, String> _pick(OsmWay w, Set<String> keep) {
  final out = <String, String>{};
  for (final k in keep) {
    final v = w.tags[k];
    if (v != null) out[k] = v;
  }
  return out;
}
