// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Immutable AdminRegion domain model — one instance per row of the bundled
// `assets/admin/germany_admin.geojson.gz` FeatureCollection.

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
}
