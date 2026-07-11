// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Immutable AdminRegion domain model — one instance per row of the bundled
// `assets/admin/germany_admin.geojson.gz` FeatureCollection.

import 'dart:collection';
import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A single admin region loaded from the bundled Germany polygon asset.
///
/// Geometry is a MultiPolygon-style list of rings-of-rings:
///   `polygon[polygonIndex][ringIndex] = List<[lat, lon]>` (each point is
/// `[double lat, double lon]`).
///
/// Ring 0 of each polygon is the outer ring; subsequent rings (if any) are
/// holes. Uses even-odd point-in-ring for containment.
@immutable
class AdminRegion {
  const AdminRegion({
    required this.osmId,
    required this.adminLevel,
    required this.name,
    required this.bboxMinLat,
    required this.bboxMinLon,
    required this.bboxMaxLat,
    required this.bboxMaxLon,
    required this.polygons,
    this.nameDe,
  });

  /// OSM relation id (`properties.osm_id`).
  final int osmId;

  /// OSM admin_level tag (2/4/6/8/9/10 per plan scope).
  final int adminLevel;

  /// English/default name (`properties.name`).
  final String name;

  /// Localized German name (`properties.name:de`); null when absent.
  final String? nameDe;

  final double bboxMinLat;
  final double bboxMinLon;
  final double bboxMaxLat;
  final double bboxMaxLon;

  /// MultiPolygon coordinates: outer ring at index 0, holes at index >0.
  /// Each `[lat, lon]` pair is a two-element `List<double>`.
  final List<List<List<List<double>>>> polygons;

  /// Point-in-region test. Runs bbox cull first; on hit, ray-casts against
  /// each polygon's outer ring and subtracts hits on any inner ring (holes).
  bool containsPoint(double lat, double lon) {
    if (lat < bboxMinLat || lat > bboxMaxLat) return false;
    if (lon < bboxMinLon || lon > bboxMaxLon) return false;
    for (final poly in polygons) {
      if (poly.isEmpty) continue;
      if (!_pointInRing(poly.first, lat, lon)) continue;
      // Point in outer — check that it's not inside any hole.
      var insideHole = false;
      for (var i = 1; i < poly.length; i++) {
        if (_pointInRing(poly[i], lat, lon)) {
          insideHole = true;
          break;
        }
      }
      if (!insideHole) return true;
    }
    return false;
  }

  static bool _pointInRing(List<List<double>> ring, double lat, double lon) {
    if (ring.length < 4) return false;
    var inside = false;
    var j = ring.length - 1;
    for (var i = 0; i < ring.length; i++) {
      final yi = ring[i][0];
      final xi = ring[i][1];
      final yj = ring[j][0];
      final xj = ring[j][1];
      final intersect = ((yi > lat) != (yj > lat)) &&
          (lon < (xj - xi) * (lat - yi) / ((yj - yi) + 1e-30) + xi);
      if (intersect) inside = !inside;
      j = i;
    }
    return inside;
  }

  @override
  String toString() =>
      'AdminRegion(osmId: $osmId, level: $adminLevel, name: $name)';

  /// The point where a map renderer draws this region's label — the "pole of
  /// inaccessibility" (the interior point farthest from any edge), computed on
  /// the region's LARGEST polygon. This is what "Jump to on map" should center
  /// on (user feedback 2026-07-11): the bbox center falls outside irregular /
  /// L-shaped regions and doesn't match where MapLibre draws the name.
  ///
  /// Returns `[lat, lon]`. Falls back to the bbox center for degenerate
  /// geometry. Uses the same `polylabel` algorithm MapLibre uses for symbol
  /// placement (grid + priority-queue refinement to a 0.0005° precision).
  List<double> get labelPoint {
    final ring = _largestOuterRing();
    if (ring == null || ring.length < 4) {
      return [(bboxMinLat + bboxMaxLat) / 2, (bboxMinLon + bboxMaxLon) / 2];
    }
    return _polylabel(ring);
  }

  /// The outer ring (ring 0) of the polygon with the largest bbox area — the
  /// part a renderer labels for a multipolygon (e.g. mainland over exclaves).
  List<List<double>>? _largestOuterRing() {
    List<List<double>>? best;
    var bestArea = -1.0;
    for (final poly in polygons) {
      if (poly.isEmpty) continue;
      final outer = poly.first;
      if (outer.length < 4) continue;
      var minLat = double.infinity;
      var maxLat = -double.infinity;
      var minLon = double.infinity;
      var maxLon = -double.infinity;
      for (final p in outer) {
        if (p[0] < minLat) minLat = p[0];
        if (p[0] > maxLat) maxLat = p[0];
        if (p[1] < minLon) minLon = p[1];
        if (p[1] > maxLon) maxLon = p[1];
      }
      final area = (maxLat - minLat) * (maxLon - minLon);
      if (area > bestArea) {
        bestArea = area;
        best = outer;
      }
    }
    return best;
  }

  /// Pole of inaccessibility for a single ring (`[lat, lon]` points).
  /// Port of mapbox/polylabel: quad-tree cell subdivision guided by a
  /// max-heap on each cell's potential max distance-to-polygon.
  static List<double> _polylabel(List<List<double>> ring) {
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final p in ring) {
      if (p[0] < minLat) minLat = p[0];
      if (p[0] > maxLat) maxLat = p[0];
      if (p[1] < minLon) minLon = p[1];
      if (p[1] > maxLon) maxLon = p[1];
    }
    final latSpan = maxLat - minLat;
    final lonSpan = maxLon - minLon;
    final cellSize = math.min(latSpan, lonSpan);
    if (cellSize <= 0) return [(minLat + maxLat) / 2, (minLon + maxLon) / 2];

    var h = cellSize / 2;
    // Max-heap by cell.max (potential distance). dart:collection has no heap;
    // use a splay-tree-backed queue keyed on descending max.
    final queue = SplayTreeSet<_Cell>((a, b) {
      final c = b.max.compareTo(a.max);
      return c != 0 ? c : a._id.compareTo(b._id);
    });

    for (var lat = minLat; lat < maxLat; lat += cellSize) {
      for (var lon = minLon; lon < maxLon; lon += cellSize) {
        queue.add(_Cell(lat + h, lon + h, h, ring));
      }
    }

    // Seed with the centroid cell as the initial best.
    final best = _centroidCell(ring);
    var bestCell = _Cell(best[0], best[1], 0, ring);

    // Also consider the bbox-center cell.
    final bboxCell = _Cell(minLat + latSpan / 2, minLon + lonSpan / 2, 0, ring);
    if (bboxCell.d > bestCell.d) bestCell = bboxCell;

    const precision = 0.0005; // ~50 m in lat degrees — plenty for centering
    while (queue.isNotEmpty) {
      final cell = queue.first;
      queue.remove(cell);

      if (cell.d > bestCell.d) bestCell = cell;
      // Skip cells that cannot possibly beat the current best.
      if (cell.max - bestCell.d <= precision) continue;

      h = cell.h / 2;
      queue
        ..add(_Cell(cell.lat - h, cell.lon - h, h, ring))
        ..add(_Cell(cell.lat + h, cell.lon - h, h, ring))
        ..add(_Cell(cell.lat - h, cell.lon + h, h, ring))
        ..add(_Cell(cell.lat + h, cell.lon + h, h, ring));
    }
    return [bestCell.lat, bestCell.lon];
  }

  static List<double> _centroidCell(List<List<double>> ring) {
    var area = 0.0;
    var lat = 0.0;
    var lon = 0.0;
    var j = ring.length - 1;
    for (var i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[j];
      final f = a[0] * b[1] - b[0] * a[1];
      lat += (a[0] + b[0]) * f;
      lon += (a[1] + b[1]) * f;
      area += f * 3;
      j = i;
    }
    if (area == 0) return [ring[0][0], ring[0][1]];
    return [lat / area, lon / area];
  }
}

/// A candidate cell in the polylabel search. `d` is the signed distance from
/// the cell center to the ring (positive = inside); `max` is the largest
/// distance a point in the cell could have (`d + h*√2`), used as the heap key.
class _Cell {
  _Cell(this.lat, this.lon, this.h, List<List<double>> ring)
      : d = _pointToRingDist(lat, lon, ring),
        _id = _seq++ {
    max = d + h * math.sqrt2;
  }

  static int _seq = 0;

  final double lat;
  final double lon;
  final double h; // half the cell size
  final double d;
  final int _id; // tie-breaker so equal-max cells stay distinct in the set
  late final double max;

  /// Signed distance from (lat, lon) to the polygon ring: positive inside,
  /// negative outside. Distance computed in degree-space (isotropic enough at
  /// Germany's latitudes for label centering).
  static double _pointToRingDist(
    double lat,
    double lon,
    List<List<double>> ring,
  ) {
    var inside = false;
    var minDistSq = double.infinity;
    var j = ring.length - 1;
    for (var i = 0; i < ring.length; i++) {
      final ai = ring[i];
      final aj = ring[j];
      if (((ai[0] > lat) != (aj[0] > lat)) &&
          (lon <
              (aj[1] - ai[1]) * (lat - ai[0]) / (aj[0] - ai[0] + 1e-30) +
                  ai[1])) {
        inside = !inside;
      }
      minDistSq = math.min(minDistSq, _segDistSq(lat, lon, ai, aj));
      j = i;
    }
    final dist = math.sqrt(minDistSq);
    return inside ? dist : -dist;
  }

  static double _segDistSq(
    double lat,
    double lon,
    List<double> a,
    List<double> b,
  ) {
    var x = a[0];
    var y = a[1];
    var dx = b[0] - x;
    var dy = b[1] - y;
    if (dx != 0 || dy != 0) {
      final t = ((lat - x) * dx + (lon - y) * dy) / (dx * dx + dy * dy);
      if (t > 1) {
        x = b[0];
        y = b[1];
      } else if (t > 0) {
        x += dx * t;
        y += dy * t;
      }
    }
    dx = lat - x;
    dy = lon - y;
    return dx * dx + dy * dy;
  }
}
