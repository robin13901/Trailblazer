// Phase 4 rescope Wave 2 (Plan 04-15):
// Pure slippy-tile bbox math — no I/O, no dependencies beyond `dart:math`.
//
// Used by [OverpassWayCandidateSource] to partition a bbox request into z12
// tiles for cache lookup + Overpass fetch. z12 was chosen per RESEARCH §2:
// tiles are ~10 km × 10 km at Germany's latitude, small enough that a typical
// urban trip touches 1–4 tiles and large enough that the cache hit-rate is
// meaningful.

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Immutable slippy tile identifier (z/x/y).
@immutable
class TileId {
  const TileId(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is TileId && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => 'TileId(z: $z, x: $x, y: $y)';
}

/// Immutable geographic bbox (all four corners in EPSG:4326).
@immutable
class LatLonBbox {
  const LatLonBbox({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });

  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  @override
  bool operator ==(Object other) =>
      other is LatLonBbox &&
      other.minLat == minLat &&
      other.minLon == minLon &&
      other.maxLat == maxLat &&
      other.maxLon == maxLon;

  @override
  int get hashCode => Object.hash(minLat, minLon, maxLat, maxLon);

  @override
  String toString() =>
      'LatLonBbox(minLat: $minLat, minLon: $minLon, '
      'maxLat: $maxLat, maxLon: $maxLon)';
}

/// Pure functions for slippy-tile math.
///
/// Stateless — held as `const TileBboxMath()` at call sites.
class TileBboxMath {
  const TileBboxMath();

  /// Slippy tile x for (lon, zoom). Standard OSM math.
  ///
  /// Longitudes outside `[-180, 180]` produce out-of-range tile x — callers
  /// should clamp beforehand if that matters. Trailblazer's bboxes are
  /// derived from GPS fixes so this is a defensive edge case (memory:
  /// `phase-4-rescope-decisions-2026-07-08` — no meridian crossings in the
  /// v1 corpus).
  int lonToTileX(double lon, int z) =>
      ((lon + 180.0) / 360.0 * (1 << z)).floor();

  /// Slippy tile y for (lat, zoom). Standard OSM math.
  int latToTileY(double lat, int z) {
    final rad = lat * math.pi / 180.0;
    return ((1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) /
            2.0 *
            (1 << z))
        .floor();
  }

  /// All z-tiles that overlap the bbox (inclusive on all edges).
  ///
  /// `z` defaults to 12 — the plan-locked working zoom for the road-fetch
  /// cache.
  Set<TileId> bboxToZ12Tiles(
    double minLat,
    double minLon,
    double maxLat,
    double maxLon, {
    int z = 12,
  }) {
    final xMin = lonToTileX(minLon, z);
    final xMax = lonToTileX(maxLon, z);
    // Slippy y increases southward — swap min/max relative to lat.
    final yMin = latToTileY(maxLat, z);
    final yMax = latToTileY(minLat, z);
    final out = <TileId>{};
    for (var x = xMin; x <= xMax; x++) {
      for (var y = yMin; y <= yMax; y++) {
        out.add(TileId(z, x, y));
      }
    }
    return out;
  }

  /// All z-tiles a GPS *path* passes through — the subset of
  /// [bboxToZ12Tiles] the trip actually touches, not the full bounding
  /// rectangle. This is the corridor-fetch win: a long point-to-point drive's
  /// bbox spans dozens of tiles but the driven path threads through only a
  /// fraction of them (measured: a 97 km trip touches 16 of 63 bbox tiles).
  ///
  /// [path] is the ordered trip points as `(lat, lon)` records — kept as a
  /// plain record list so this file stays dependency-light (no LatLng import);
  /// callers map their `GpsFix`/`TripPoint` rows to records.
  ///
  /// Each point marks its own tile. Consecutive points are additionally
  /// sampled ALONG the connecting segment at [_pathSampleMeters] spacing so a
  /// sparse-fix stretch (e.g. an autobahn run with fixes seconds — hundreds of
  /// meters — apart, or a GPS gap) never skips an intermediate tile. Mirrors
  /// the along-segment sampling in `TripCorridor.fromFixes`
  /// (`way_corridor_filter.dart`), applied to tiles instead of corridor cells.
  ///
  /// Returns an empty set for an empty [path] (callers treat that as "no
  /// restriction" and fall back to the bbox behaviour).
  Set<TileId> tilesForPath(
    List<({double lat, double lon})> path, {
    int z = 12,
  }) {
    final out = <TileId>{};
    if (path.isEmpty) return out;

    void mark(double lat, double lon) =>
        out.add(TileId(z, lonToTileX(lon, z), latToTileY(lat, z)));

    for (var i = 0; i < path.length; i++) {
      final p = path[i];
      mark(p.lat, p.lon);
      if (i + 1 < path.length) {
        final q = path[i + 1];
        final segMeters = _approxMeters(p.lat, p.lon, q.lat, q.lon);
        if (segMeters > _pathSampleMeters) {
          final steps = (segMeters / _pathSampleMeters).ceil();
          for (var s = 1; s < steps; s++) {
            final t = s / steps;
            mark(
              p.lat + (q.lat - p.lat) * t,
              p.lon + (q.lon - p.lon) * t,
            );
          }
        }
      }
    }
    return out;
  }

  /// Bbox of a single tile in EPSG:4326.
  LatLonBbox tileToBbox(TileId t) {
    final n = 1 << t.z;
    final minLon = t.x / n * 360.0 - 180.0;
    final maxLon = (t.x + 1) / n * 360.0 - 180.0;
    final maxLatRad = math.atan(_sinh(math.pi * (1 - 2 * t.y / n)));
    final minLatRad = math.atan(_sinh(math.pi * (1 - 2 * (t.y + 1) / n)));
    return LatLonBbox(
      minLat: minLatRad * 180.0 / math.pi,
      minLon: minLon,
      maxLat: maxLatRad * 180.0 / math.pi,
      maxLon: maxLon,
    );
  }

  /// Smallest bbox containing all tiles.
  ///
  /// Returns a degenerate bbox (all zeros) when [tiles] is empty — callers
  /// should filter empty inputs upstream.
  LatLonBbox unionBbox(Iterable<TileId> tiles) {
    if (tiles.isEmpty) {
      return const LatLonBbox(
        minLat: 0,
        minLon: 0,
        maxLat: 0,
        maxLon: 0,
      );
    }
    var minLat = 90.0;
    var minLon = 180.0;
    var maxLat = -90.0;
    var maxLon = -180.0;
    for (final t in tiles) {
      final b = tileToBbox(t);
      if (b.minLat < minLat) minLat = b.minLat;
      if (b.minLon < minLon) minLon = b.minLon;
      if (b.maxLat > maxLat) maxLat = b.maxLat;
      if (b.maxLon > maxLon) maxLon = b.maxLon;
    }
    return LatLonBbox(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
    );
  }

  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2.0;

  /// Along-segment sample spacing (meters) for [tilesForPath]. At z12 a tile is
  /// ~6–10 km wide at DE latitudes, so 2 km sampling cannot skip a tile between
  /// two consecutive samples while staying cheap on a 5000-point trace. Well
  /// below one tile width, comfortably above the ~1 s fix cadence.
  static const double _pathSampleMeters = 2000;

  /// Approximate meters per degree of latitude (WGS84 mean). Matches
  /// `way_corridor_filter.dart`.
  static const double _metersPerDegLat = 111320;

  /// Cheap planar distance for the coarse along-segment sampling in
  /// [tilesForPath] — full haversine is unnecessary at tile granularity.
  static double _approxMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final midLatRad = ((lat1 + lat2) / 2) * (math.pi / 180.0);
    final dLatM = (lat2 - lat1) * _metersPerDegLat;
    final dLonM = (lon2 - lon1) * _metersPerDegLat * math.cos(midLatRad);
    return math.sqrt(dLatM * dLatM + dLonM * dLonM);
  }
}
