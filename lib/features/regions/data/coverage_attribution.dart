// Pure STAGE-1 coverage attribution (2026-07-25) — the geometric polyline-vs-
// polygon clip extracted from CoverageComputeService so it runs inside the
// coverage-compute worker isolate (and is unit-testable WITHOUT spawning one).
//
// Given the parsed admin polygon index and the raw gzipped Overpass tiles +
// their bboxes, this walks each NEW driven way's polyline and, for each admin
// level, emits the contiguous meter-RANGES along the way that lie inside each
// containing region's polygon. These rows are DURABLE: a way's region
// membership + meter-ranges are static (geometry never moves), so they are
// computed ONCE per new wayId and cached forever in `way_region_attribution`.
// The driven-vs-total aggregation (STAGE 2) is then a pure DB read/sum on the
// main isolate — eviction-proof + monotonic.
//
// Sampling granularity: SEGMENT-level. The way's polyline is already densified
// upstream (Overpass `out geom`), so each segment [mStart, mEnd] is attributed
// to the region containing its MIDPOINT, then consecutive same-region segments
// at the same level are MERGED into one range row. This is the acceptable
// approximation called out in the schema docstring — a boundary crossing lands
// on a segment boundary (± half a densified segment), which is negligible
// against per-region km totals.
//
// STRICTLY PURE + isolate-safe: dart:convert, dart:io(gzip), dart:typed_data,
// and pure domain/value types only. NO Flutter, NO Drift, NO Riverpod. Mirror
// of tile_way_pipeline.dart's posture — decode tiles ONE AT A TIME so each
// tile's JSON + parsed ways are GC-eligible before the next (bounded peak
// memory), and the polygon index is passed in (never re-parsed per way).

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_job.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';

/// Admin levels attributed during the clip pass.
///
/// Level 2 (country) is intentionally excluded: the DE country row would
/// accumulate every driven meter and its total would be the entire German road
/// network — not a meaningful display (RESEARCH.md Pitfall 2). Level 9 is
/// INCLUDED (Ortsteil granularity). Mirrors the value that previously lived in
/// coverage_compute_service.dart (kept identical so behaviour is unchanged).
const List<int> kComputeAdminLevels = [4, 6, 8, 9, 10];

/// STAGE 1: clip each NEW driven way's polyline against the admin polygons and
/// return the durable per-(way, region, meter-range) attribution rows.
///
/// - [regionsByLevel]: admin polygon index bucketed by adminLevel (built once
///   inside the worker from the shipped bundle bytes — NOT copied per call).
/// - [gzippedTiles] / [tileBboxes]: parallel raw cached Overpass tiles; decoded
///   tile-by-tile here (bounded memory), deduped by wayId, bbox-clipped.
/// - [alreadyAttributedWayIds]: wayIds that already have rows in
///   `way_region_attribution` — SKIPPED (attribution is static per wayId).
///
/// Returns one [WayRegionAttributionRow] per (way, level, contiguous in-region
/// run). A way that stays inside one region at a level produces one row spanning
/// its whole length; a boundary-crossing way produces one row per region run.
/// Pure + synchronous — no yields needed (it runs off the UI isolate).
List<WayRegionAttributionRow> computeCoverageAttribution({
  required Map<int, List<AdminRegion>> regionsByLevel,
  required List<List<int>> gzippedTiles,
  required List<LatLonBbox> tileBboxes,
  Set<int> alreadyAttributedWayIds = const {},
  List<int> levels = kComputeAdminLevels,
  OverpassResponseParser parser = const OverpassResponseParser(),
}) {
  final out = <WayRegionAttributionRow>[];
  final seenIds = <int>{};

  for (var t = 0; t < gzippedTiles.length; t++) {
    final bbox = t < tileBboxes.length ? tileBboxes[t] : null;
    // Decode + parse ONE tile; locals GC before the next iteration.
    final rawJson = utf8.decode(gzip.decode(gzippedTiles[t]));
    final ways = parser.parseWays(rawJson);

    for (final way in ways) {
      if (!seenIds.add(way.wayId)) continue; // dedupe across tile boundaries
      if (alreadyAttributedWayIds.contains(way.wayId)) continue; // cached
      if (bbox != null && !_geometryTouchesBbox(way, bbox)) continue; // clip
      if (way.geometry.length < 2) continue; // degenerate — no segments

      for (final level in levels) {
        _clipWayAtLevel(
          way: way,
          regions: regionsByLevel[level],
          level: level,
          out: out,
        );
      }
    }
  }

  return out;
}

/// Walk [way]'s segments, attributing each segment to the region (at [level])
/// containing its midpoint, and merge consecutive same-region segments into one
/// contiguous meter-range row appended to [out]. Segments whose midpoint is in
/// no region flush the current run (a gap outside every polygon at this level).
void _clipWayAtLevel({
  required WayCandidate way,
  required List<AdminRegion>? regions,
  required int level,
  required List<WayRegionAttributionRow> out,
}) {
  if (regions == null || regions.isEmpty) return;
  final geom = way.geometry;

  // Current in-region run: the region id it belongs to and its meter-range.
  String? runRegionId;
  var runStart = 0.0;
  var runEnd = 0.0;

  var cursorM = 0.0;
  for (var i = 0; i < geom.length - 1; i++) {
    final a = geom[i];
    final b = geom[i + 1];
    final segLen = haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude);
    final segStart = cursorM;
    final segEnd = cursorM + segLen;
    cursorM = segEnd;
    if (segLen <= 0) continue; // zero-length segment contributes nothing

    // Region containing this segment's midpoint (finest match at this level).
    final midLat = (a.latitude + b.latitude) / 2;
    final midLon = (a.longitude + b.longitude) / 2;
    final region = _regionAt(regions, midLat, midLon);
    final id = region?.osmId.toString();

    if (id == runRegionId) {
      // Same region (including "both null" = still outside) → extend the run.
      if (id != null) runEnd = segEnd;
      continue;
    }

    // Region changed — flush the prior run (if it was inside a region).
    if (runRegionId != null && runEnd > runStart) {
      out.add(
        WayRegionAttributionRow(
          wayId: way.wayId,
          regionId: runRegionId,
          adminLevel: level,
          rangeStartM: runStart,
          rangeEndM: runEnd,
        ),
      );
    }
    // Start a new run at this segment.
    runRegionId = id;
    runStart = segStart;
    runEnd = segEnd;
  }

  // Flush the trailing run.
  if (runRegionId != null && runEnd > runStart) {
    out.add(
      WayRegionAttributionRow(
        wayId: way.wayId,
        regionId: runRegionId,
        adminLevel: level,
        rangeStartM: runStart,
        rangeEndM: runEnd,
      ),
    );
  }
}

/// Sync point-in-polygon lookup over one level's bucket — the isolate-local
/// replacement for the async `AdminRegionLookup.regionAt`. Returns the first
/// region whose polygon contains the point; bbox cull is inside `containsPoint`.
AdminRegion? _regionAt(List<AdminRegion> regions, double lat, double lon) {
  for (final region in regions) {
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
