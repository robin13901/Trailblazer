// Phase 4 rescope Wave 2 (Plan 04-15):
// Abstract source of OSM way candidates for the map-matcher.
//
// Two implementations exist:
//   * `OverpassWayCandidateSource` — runtime, cache-first, network-backed.
//   * `FixtureWayCandidateSource` (test/helpers/) — deterministic, offline.
//
// The interface is what Phase 5's HMM matcher consumes. Both implementations
// must apply the Kfz allowlist (`kfzHighwayClasses` in
// `lib/features/matching/domain/way_candidate.dart`) and deduplicate by
// `wayId` across tile boundaries.

import 'dart:typed_data';

import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:meta/meta.dart';

/// One cached/fetched tile's raw gzipped Overpass JSON plus its tile bbox.
///
/// Returned by [WayCandidateSource.fetchRawTilesInBbox] so the matcher isolate
/// can decode + parse + filter the payload itself — keeping that CPU work OFF
/// the main isolate (Plan 06-07 re-drive #3). [payloadGzip] is a [Uint8List]
/// so it crosses the isolate SendPort untouched.
@immutable
class RawTilePayload {
  const RawTilePayload({required this.payloadGzip, required this.bbox});

  /// `gzip(utf8(overpassJson))` straight from the cache row.
  final Uint8List payloadGzip;

  /// The tile's geographic bounds — used for the post-parse bbox-clip.
  final LatLonBbox bbox;
}

/// Abstract seam consumed by the map-matcher (Phase 5).
///
/// `fetchWaysInBbox` returns every Kfz-allowlisted [WayCandidate] whose
/// geometry intersects the requested bbox. Coordinate order is
/// `(minLat, minLon, maxLat, maxLon)` — matches Overpass's
/// `(south, west, north, east)` convention.
///
/// `throwOnError` controls network-failure behavior:
///   * `true` (default) — rethrow as a `DomainError` (`NetworkError` for
///     HTTP failures, wrapped `UnknownError` otherwise).
///   * `false` — return whatever cached candidates are available and swallow
///     the network error. Used by the offline-drain path (04-15 coordinator).
///
/// `restrictTiles` (added 2026-07-21 for the corridor-fetch fix) narrows the
/// work set to the intersection of the bbox tiles and the given tile set —
/// pass the tiles the trip *path* touches (see `TileBboxMath.tilesForPath`) so
/// a long point-to-point trip fetches only its ~corridor tiles instead of the
/// whole (mostly-empty) bounding rectangle. `null` (default) = no restriction,
/// i.e. the pre-existing full-bbox behaviour (detail-overlay + golden callers).
///
/// `onTileProgress`, when non-null, is invoked with `(done, total)` as tiles
/// are resolved (`total` = the count of tiles in scope, cache hits included).
/// Lets the road-fetch coordinator surface N/M tile progress to the UI pill.
abstract class WayCandidateSource {
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    void Function(int done, int total)? onTileProgress,
  });

  /// Like [fetchWaysInBbox] but returns the RAW gzipped tile payloads without
  /// decoding/parsing them — the decode + parse + dedupe + clip + corridor
  /// filter happens later, inside the matcher isolate (Plan 06-07). This keeps
  /// the CPU-heavy stage off the main isolate; only cache reads + network
  /// fetches (async I/O) run here.
  ///
  /// `throwOnError`, `restrictTiles`, and `onTileProgress` have the same
  /// semantics as [fetchWaysInBbox].
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    void Function(int done, int total)? onTileProgress,
  });
}
