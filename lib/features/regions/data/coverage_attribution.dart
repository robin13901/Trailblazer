// Pure coverage attribution (2026-07-22) — the heavy compute extracted from
// CoverageComputeService.recompute() so it runs inside the coverage-compute
// worker isolate (and is unit-testable WITHOUT spawning one).
//
// Given the parsed admin polygon index, the bundled per-region totals, the raw
// gzipped Overpass tiles + their bboxes, and the driven union intervals per
// wayId, this attributes every driven way to its containing admin region(s) at
// levels 4/6/8/9/10 and accumulates driven + total road length per region.
//
// STRICTLY PURE + isolate-safe: dart:convert, dart:io(gzip), dart:typed_data,
// and pure domain/value types only. NO Flutter, NO Drift, NO Riverpod. Mirror
// of tile_way_pipeline.dart's posture — decode tiles ONE AT A TIME so each
// tile's JSON + parsed ways are GC-eligible before the next (bounded peak
// memory), and the polygon index is passed in (never re-parsed per way).

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_job.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Admin levels attributed during the recompute pass.
///
/// Level 2 (country) is intentionally excluded: the DE country row would
/// accumulate every driven meter and its total would be the entire German road
/// network — not a meaningful display (RESEARCH.md Pitfall 2). Level 9 is
/// INCLUDED (Ortsteil granularity). Mirrors the value that previously lived in
/// coverage_compute_service.dart (kept identical so behaviour is unchanged).
const List<int> kComputeAdminLevels = [4, 6, 8, 9, 10];

/// Attribute driven ways to admin regions and accumulate coverage per region.
///
/// - [regionsByLevel]: admin polygon index bucketed by adminLevel (built once
///   inside the worker from the shipped bundle bytes — NOT copied per call).
/// - [totals]: bundled per-region real total lengths (osm_id string → meters);
///   null when the deferred asset is absent → every `realTotal` is null.
/// - [gzippedTiles] / [tileBboxes]: parallel raw cached Overpass tiles; decoded
///   tile-by-tile here (bounded memory), deduped by wayId, bbox-clipped.
/// - [intervalsByWayId]: wayId → flattened driven union intervals
///   `[start0,end0,start1,end1,…]`; rebuilt into [Interval]s locally.
///
/// Returns `regionId (osm_id string) → RegionAccum(driven, total, realTotal)`.
/// Only regions with at least some attributed total length appear. Pure +
/// synchronous — no yields needed (it runs off the UI isolate).
Map<String, RegionAccum> computeCoverageAttribution({
  required Map<int, List<AdminRegion>> regionsByLevel,
  required Map<String, double>? totals,
  required List<List<int>> gzippedTiles,
  required List<LatLonBbox> tileBboxes,
  required Map<int, List<double>> intervalsByWayId,
  List<int> levels = kComputeAdminLevels,
  OverpassResponseParser parser = const OverpassResponseParser(),
}) {
  // Rebuild the driven union intervals per wayId (flattened doubles → Interval).
  final unionByWayId = <int, List<Interval>>{};
  for (final entry in intervalsByWayId.entries) {
    final flat = entry.value;
    final ivs = <Interval>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      ivs.add(Interval(flat[i], flat[i + 1]));
    }
    if (ivs.isNotEmpty) unionByWayId[entry.key] = ivs;
  }

  final total = <String, double>{};
  final driven = <String, double>{};
  final seenIds = <int>{};

  for (var t = 0; t < gzippedTiles.length; t++) {
    final bbox = t < tileBboxes.length ? tileBboxes[t] : null;
    // Decode + parse ONE tile; locals GC before the next iteration.
    final rawJson = utf8.decode(gzip.decode(gzippedTiles[t]));
    final ways = parser.parseWays(rawJson);

    for (final way in ways) {
      if (!seenIds.add(way.wayId)) continue; // dedupe across tile boundaries
      if (bbox != null && !_geometryTouchesBbox(way, bbox)) continue; // clip

      final c = _centroid(way.geometry);
      if (c == null) continue; // degenerate geometry
      final wayLen = _polylineLengthMeters(way.geometry);
      final ivs = unionByWayId[way.wayId];
      final unionLen = ivs != null ? drivenLengthMeters(ivs) : 0.0;

      for (final level in levels) {
        final region = _regionAt(regionsByLevel, c.latitude, c.longitude, level);
        if (region == null) continue;
        // OSM relation ids are globally unique across levels — do NOT prefix.
        final id = region.osmId.toString();
        total[id] = (total[id] ?? 0) + wayLen;
        if (unionLen > 0) driven[id] = (driven[id] ?? 0) + unionLen;
      }
    }
  }

  final out = <String, RegionAccum>{};
  for (final id in total.keys) {
    out[id] = RegionAccum(
      driven: driven[id] ?? 0,
      total: total[id]!,
      realTotal: totals?[id],
    );
  }
  return out;
}

/// Sync point-in-polygon lookup over the pre-bucketed index — the isolate-local
/// replacement for the async `AdminRegionLookup.regionAt`. Scans only the
/// requested level's bucket; bbox cull is inside `containsPoint`.
AdminRegion? _regionAt(
  Map<int, List<AdminRegion>> regionsByLevel,
  double lat,
  double lon,
  int level,
) {
  final candidates = regionsByLevel[level];
  if (candidates == null) return null;
  for (final region in candidates) {
    if (region.containsPoint(lat, lon)) return region;
  }
  return null;
}

/// True if any point of [c]'s geometry lies inside [bbox]. Ported from
/// tile_way_pipeline.dart so the clip runs in the worker.
bool _geometryTouchesBbox(WayCandidate c, LatLonBbox bbox) {
  for (final p in c.geometry) {
    if (p.latitude >= bbox.minLat &&
        p.latitude <= bbox.maxLat &&
        p.longitude >= bbox.minLon &&
        p.longitude <= bbox.maxLon) {
      return true;
    }
  }
  return false;
}

/// Mean lat/lon of [geometry]. Returns null for empty geometry.
LatLng? _centroid(List<LatLng> geometry) {
  if (geometry.isEmpty) return null;
  var sumLat = 0.0;
  var sumLon = 0.0;
  for (final p in geometry) {
    sumLat += p.latitude;
    sumLon += p.longitude;
  }
  return LatLng(sumLat / geometry.length, sumLon / geometry.length);
}

/// Haversine sum of consecutive point distances along [geometry].
double _polylineLengthMeters(List<LatLng> geometry) {
  var total = 0.0;
  for (var i = 0; i < geometry.length - 1; i++) {
    total += haversineMeters(
      geometry[i].latitude,
      geometry[i].longitude,
      geometry[i + 1].latitude,
      geometry[i + 1].longitude,
    );
  }
  return total;
}
