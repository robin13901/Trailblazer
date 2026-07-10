// Trailblazer Phase 7, Plan 07-04:
// Pure top-level GeoJSON FeatureCollection builder for coverage ways.
//
// Converts a list of [CoverageWay]s into a GeoJSON FeatureCollection Map
// suitable for passing directly to MapLibre's `addGeoJsonSource` /
// `setGeoJsonSource`. Each feature carries three GeoJSON properties:
//   - way_id   : the OSM way ID (int)
//   - fraction : coverage fraction in [0, 1] (double)
//   - is_full  : 1 if fully explored, 0 if partial (int — used in the
//                MapLibre `case` paint expression; booleans are fragile in
//                JSON expressions on the native side, ints are safe)
//
// Design notes:
//   - Pure function — no Flutter/Riverpod/IO deps; runs safely on a
//     compute() isolate for large corpora (Phase 7 stress harness, plan
//     07-06). The only external dep is maplibre_gl's LatLng, kept minimal.
//   - Ways with < 2 geometry points are degenerate LineStrings and are
//     silently dropped (RESEARCH Pitfall 7 — always add the GeoJSON source
//     even when all ways are dropped; let it render an empty feature list).
//   - Empty input → FeatureCollection with an empty features array (not an
//     error — source is always added so the layer can be layered below labels
//     unconditionally, avoids special-casing in the applier).

import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';

/// Converts [ways] to a GeoJSON FeatureCollection ready for MapLibre.
///
/// Each [CoverageWay] becomes a `LineString` Feature with properties:
/// `way_id` (int), `fraction` (double), `is_full` (int 1 or 0).
///
/// Ways with fewer than 2 geometry points are silently skipped (degenerate
/// LineStrings are invalid GeoJSON and would cause a native parse error).
/// An empty [ways] list produces a valid FeatureCollection with an empty
/// `features` array — the source is still registered in MapLibre so the
/// layer is unconditionally present and renders nothing until data arrives.
///
/// Coordinate order follows GeoJSON RFC 7946 §3.1.1 — [longitude, latitude].
Map<String, dynamic> buildCoverageFeatureCollection(
  List<CoverageWay> ways,
) {
  final features = <Map<String, dynamic>>[];

  for (final way in ways) {
    // Skip degenerate ways — a LineString requires at least 2 points.
    if (way.geometry.length < 2) continue;

    features.add({
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        // GeoJSON RFC 7946 §3.1.1: coordinates are [longitude, latitude].
        'coordinates': [
          for (final p in way.geometry) [p.longitude, p.latitude],
        ],
      },
      'properties': {
        'way_id': way.wayId,
        'fraction': way.datum.fraction,
        // int 1/0 instead of bool — MapLibre case expressions on mobile
        // handle ints more reliably than JSON booleans in the method-channel
        // round-trip (verified against plan 04-08 expression patterns).
        'is_full': way.datum.isFull ? 1 : 0,
      },
    });
  }

  return {
    'type': 'FeatureCollection',
    'features': features,
  };
}
