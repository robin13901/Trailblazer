// Trailblazer Phase 6, Plan 06-07 (re-drive #3 OOM/jank fix):
// Tile-by-tile decode + parse + dedupe + bbox-clip + corridor-filter.
//
// PROBLEM (measured on-device 2026-07-09): the previous flow decoded ALL
// cached Overpass tiles (27 tiles / 13.7 MB / ~29,497 ways for a 96 km trip)
// on the MAIN isolate inside `OverpassWayCandidateSource.fetchWaysInBbox`
// BEFORE the matcher isolate started — blocking the UI thread (jank, "Skipped
// N frames", no progress %) and spiking the main heap on top of the ~529 MB
// MapLibre GL surface → OOM kill.
//
// FIX: this function runs INSIDE the matcher isolate. It processes one tile at
// a time — gunzip → parse → dedupe → bbox-clip → corridor-filter — keeping
// only the small corridor survivors and letting each tile's raw bytes + parsed
// objects go out of scope before the next tile. Peak retained memory is one
// tile's ways + the survivor subset, never all 29k at once, and never on the
// main heap (the main isolate only ships the gzipped bytes across).
//
// PURE + isolate-safe: imports only dart:io (gzip), dart:convert, the pure
// OverpassResponseParser, the pure corridor filter, and value types. No Drift,
// no Flutter, no platform channels.

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_corridor_filter.dart';

/// Decode + parse + dedupe + bbox-clip + corridor-filter a set of gzipped
/// Overpass tile payloads, tile-by-tile, returning only the ways within the
/// trip corridor described by [fixes].
///
/// [gzippedTiles] and [tileBboxes] are parallel lists (index i's payload was
/// fetched for index i's tile bbox). Each payload is `gzip(utf8(rawJson))` as
/// stored by `OverpassWayCacheDao`.
///
/// Memory is bounded: at most one tile's decoded JSON + parsed ways are live at
/// once; only the deduped corridor survivors accumulate across tiles.
///
/// When [fixes] is empty there is no corridor to test against — every deduped,
/// bbox-clipped way is kept (mirrors [filterWaysToTripCorridor]'s degenerate
/// passthrough), so the matcher's own guards still see the candidates.
List<WayCandidate> parseAndFilterTiles({
  required List<List<int>> gzippedTiles,
  required List<LatLonBbox> tileBboxes,
  required List<GpsFix> fixes,
  OverpassResponseParser parser = const OverpassResponseParser(),
}) {
  final corridor = TripCorridor.fromFixes(fixes);
  final keepAll = fixes.isEmpty;

  final seenIds = <int>{};
  final survivors = <WayCandidate>[];

  for (var i = 0; i < gzippedTiles.length; i++) {
    final bbox = i < tileBboxes.length ? tileBboxes[i] : null;
    // Decode + parse ONE tile. These locals go out of scope at the end of the
    // iteration, so the tile's raw JSON + parsed list are GC-eligible before
    // the next tile is touched.
    final rawJson = utf8.decode(gzip.decode(gzippedTiles[i]));
    final parsed = parser.parseWays(rawJson);

    for (final c in parsed) {
      if (!seenIds.add(c.wayId)) continue; // dedupe across tile boundaries
      if (bbox != null && !_geometryTouchesBbox(c, bbox)) continue; // clip
      if (!keepAll && !corridor.touchedBy(c)) continue; // corridor
      survivors.add(c);
    }
  }
  return survivors;
}

/// True if any point of [c]'s geometry lies inside [bbox]. Ported from
/// `OverpassWayCandidateSource._geometryTouchesBbox` so the clip runs in the
/// isolate rather than on the main thread.
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
