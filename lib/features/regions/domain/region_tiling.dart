// Trailblazer 2026-07-14 (region-spinner visibility + smallest-first ordering):
// region_tiling — pure tiling math shared by RegionTotalLengthService (which
// fetches cell lengths) and the region browser provider (which shows compute
// progress). No Drift, no Riverpod, no Flutter, no http — safe to import from
// the presentation layer without dragging in the network service.

import 'dart:convert';

/// Target cell size (degrees) for tiling a region's bbox. ~0.1° ≈ 11 km N–S;
/// small enough that a single cell's `sum(length())` stays well under the
/// Overpass per-query memory ceiling for typical road densities. This is the
/// canonical definition — RegionTotalLengthService imports it from here.
const double kRegionTileDegrees = 0.1;

/// Schema version of the persisted progress accumulator blob (stored in
/// `coverage_cache.real_total_progress_json`). Bumped if the cell-key scheme or
/// tiling constant changes so stale blobs are discarded. Canonical definition —
/// RegionTotalLengthService imports it from here.
const int kRegionProgressBlobVersion = 1;

/// Number of cells the tiled real-total pass will produce for a region whose
/// bbox is `(minLat, minLon, maxLat, maxLon)`. Mirrors the `_tileBbox`
/// while-loop in RegionTotalLengthService exactly, so the count shown to the
/// user matches the work the service actually does. Used both to sort regions
/// smallest-first and to render "done / planned" progress.
///
/// Returns 0 for a degenerate (zero-area) bbox.
int plannedCellCount(
  double minLat,
  double minLon,
  double maxLat,
  double maxLon,
) {
  if (maxLat <= minLat || maxLon <= minLon) return 0;
  var count = 0;
  var lat = minLat;
  while (lat < maxLat) {
    final nextLat = (lat + kRegionTileDegrees).clamp(minLat, maxLat);
    var lon = minLon;
    while (lon < maxLon) {
      final nextLon = (lon + kRegionTileDegrees).clamp(minLon, maxLon);
      count++;
      if (nextLon >= maxLon) break;
      lon = nextLon;
    }
    if (nextLat >= maxLat) break;
    lat = nextLat;
  }
  return count;
}

/// Count of completed cells recorded in a `real_total_progress_json` blob, or
/// `null` when the blob is absent, empty, malformed, or from a different
/// version / tiling constant (a stale blob is not trustworthy progress). Uses
/// the same version/tiles guard as RegionTotalLengthService._loadProgress.
int? completedCellCount(String? progressJson) {
  if (progressJson == null || progressJson.isEmpty) return null;
  try {
    final decoded = jsonDecode(progressJson);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['v'] != kRegionProgressBlobVersion) return null;
    if ((decoded['tiles'] as num?)?.toDouble() != kRegionTileDegrees) {
      return null;
    }
    final cells = decoded['cells'];
    if (cells is! Map<String, dynamic>) return null;
    return cells.length;
    // Corrupt blob: report "no progress" rather than throw into the UI.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return null;
  }
}
