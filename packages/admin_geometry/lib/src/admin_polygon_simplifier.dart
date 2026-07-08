// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Overpass admin-relations → simplified GeoJSON FeatureCollection.
//
// Input: raw Overpass JSON body (from `AdminPolygonDownloader`) — every
// relation carries `members[]` with inline `geometry[]` per way member
// (Overpass `out geom` mode).
//
// Output: `Map<String, dynamic>` shaped as GeoJSON FeatureCollection with
// one `MultiPolygon` feature per accepted admin relation. Property set:
// `osm_id`, `admin_level`, `name`, `name:de` (nullable).
//
// Assembly pipeline per relation:
//   1. Partition members by role (`outer` / `inner`; roles empty / other
//      dropped as outer per OSM convention).
//   2. Chain member ways head-to-tail into closed rings. Reverses ways as
//      needed. Discards fragments that don't close within tolerance.
//   3. Applies Douglas-Peucker per ring using level-dependent tolerance
//      (see `_toleranceMetersPerLevel` — 04-RESEARCH §3 targets <15 MB
//      gzipped for full Germany bundle).
//   4. Buckets simplified inner rings into their containing outer polygon
//      (point-in-ring at the inner's first vertex).
//   5. Emits `MultiPolygon` geometry with one Polygon per outer.
//
// Pure Dart — depends only on `dart:convert` (implicitly, none — the caller
// hands us a String and we return a Map).

// ignore_for_file: public_member_api_docs
// Internal implementation module. Public API is re-exported via
// `admin_geometry.dart`; docstrings live on the exported types.
// document_ignores: internal-only file, per-symbol docs not required.
// ignore_for_file: document_ignores

import 'dart:convert';
import 'dart:math' as math;

/// Douglas-Peucker tolerance in meters, keyed by OSM `admin_level`.
///
/// Values chosen per 04-RESEARCH §3 to keep the bundled asset < 15 MB
/// gzipped for full Germany at levels 2/4/6/8/9/10. Higher levels
/// (municipalities, Ortsteile) use looser tolerance because there are many
/// more of them — the byte budget lives mostly with L8+.
const _toleranceMetersPerLevel = <int, double>{
  2: 10,
  4: 30,
  6: 50,
  8: 100,
  9: 100,
  10: 100,
};

/// Endpoint-match tolerance for ring stitching, in degrees.
/// ~1e-6 deg ≈ 11 cm — Overpass member ways share exact node coordinates
/// at their endpoints, so anything looser is generous.
const _stitchEpsilonDeg = 1e-6;

class AdminPolygonSimplifier {
  const AdminPolygonSimplifier({
    Map<int, double>? tolerancesPerLevel,
  }) : _tolerances = tolerancesPerLevel ?? _toleranceMetersPerLevel;

  final Map<int, double> _tolerances;

  /// Convenience — swap in stricter tolerances if the bundled asset blows
  /// the 15 MB budget (plan §Deviations).
  AdminPolygonSimplifier withStricterL8(double meters) {
    final next = Map<int, double>.from(_tolerances);
    next[8] = meters;
    return AdminPolygonSimplifier(tolerancesPerLevel: next);
  }

  /// Assembles + simplifies every admin relation in [rawJson] and returns
  /// a GeoJSON `FeatureCollection` map (ready for `jsonEncode`).
  Map<String, dynamic> assembleAndSimplify(String rawJson) {
    final Object? decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      return {'type': 'FeatureCollection', 'features': const <dynamic>[]};
    }
    final elements = decoded['elements'];
    if (elements is! List) {
      return {'type': 'FeatureCollection', 'features': const <dynamic>[]};
    }

    final features = <Map<String, dynamic>>[];
    for (final raw in elements) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['type'] != 'relation') continue;

      final feature = _assembleRelation(raw);
      if (feature != null) features.add(feature);
    }

    return {
      'type': 'FeatureCollection',
      'features': features,
    };
  }

  Map<String, dynamic>? _assembleRelation(Map<String, dynamic> relation) {
    final id = relation['id'];
    if (id is! int) return null;
    final tags = relation['tags'];
    if (tags is! Map<String, dynamic>) return null;
    final name = tags['name'];
    if (name is! String || name.isEmpty) return null;
    final levelRaw = tags['admin_level'];
    if (levelRaw is! String) return null;
    final adminLevel = int.tryParse(levelRaw);
    if (adminLevel == null) return null;
    if (!_tolerances.containsKey(adminLevel)) return null;

    final members = relation['members'];
    if (members is! List) return null;

    // Partition member ways by role.
    final outerWays = <List<_LatLon>>[];
    final innerWays = <List<_LatLon>>[];
    for (final m in members) {
      if (m is! Map<String, dynamic>) continue;
      if (m['type'] != 'way') continue;
      final geom = m['geometry'];
      if (geom is! List) continue;
      final pts = <_LatLon>[];
      for (final pt in geom) {
        if (pt is! Map) continue;
        final lat = pt['lat'];
        final lon = pt['lon'];
        if (lat is! num || lon is! num) continue;
        pts.add(_LatLon(lat.toDouble(), lon.toDouble()));
      }
      if (pts.length < 2) continue;
      final role = m['role'];
      if (role == 'inner') {
        innerWays.add(pts);
      } else {
        // 'outer' or blank/other → treat as outer per OSM convention.
        outerWays.add(pts);
      }
    }

    if (outerWays.isEmpty) return null;

    final outerRings = _stitchRings(outerWays);
    final innerRings = _stitchRings(innerWays);
    if (outerRings.isEmpty) return null;

    // Simplify.
    final toleranceMeters = _tolerances[adminLevel]!;
    final simplifiedOuters =
        outerRings.map((r) => _simplifyRing(r, toleranceMeters)).toList();
    final simplifiedInners =
        innerRings.map((r) => _simplifyRing(r, toleranceMeters)).toList();

    // Bucket inners into their containing outer (point-in-ring test).
    final polygons = <List<List<_LatLon>>>[];
    for (final outer in simplifiedOuters) {
      polygons.add([outer]);
    }
    for (final inner in simplifiedInners) {
      if (inner.isEmpty) continue;
      final probe = inner.first;
      var placed = false;
      for (final poly in polygons) {
        if (_pointInRing(probe, poly.first)) {
          poly.add(inner);
          placed = true;
          break;
        }
      }
      // If no outer contains it (dangling inner), silently drop it.
      // Overpass admin relations occasionally carry stale members.
      if (!placed) continue;
    }

    // Build MultiPolygon coordinates: [ [ [ [lon,lat], ... ], ... ], ... ].
    final coords = <List<List<List<double>>>>[];
    for (final poly in polygons) {
      final rings = <List<List<double>>>[];
      for (final ring in poly) {
        final ringPts = <List<double>>[
          for (final p in ring) [p.lon, p.lat],
        ];
        rings.add(ringPts);
      }
      coords.add(rings);
    }

    final properties = <String, dynamic>{
      'osm_id': id,
      'admin_level': adminLevel,
      'name': name,
    };
    final nameDe = tags['name:de'];
    if (nameDe is String && nameDe.isNotEmpty) {
      properties['name:de'] = nameDe;
    }

    return {
      'type': 'Feature',
      'properties': properties,
      'geometry': {
        'type': 'MultiPolygon',
        'coordinates': coords,
      },
    };
  }

  /// Stitches an unordered collection of open way-fragments into a set of
  /// closed rings by head-to-tail chaining.
  ///
  /// Each ring is guaranteed closed (last == first). Fragments that cannot
  /// close within [_stitchEpsilonDeg] are silently dropped.
  List<List<_LatLon>> _stitchRings(List<List<_LatLon>> fragments) {
    final rings = <List<_LatLon>>[];
    final pool = fragments.map(List<_LatLon>.from).toList();

    while (pool.isNotEmpty) {
      final current = pool.removeLast();
      // Already closed?
      if (_pointsEqual(current.first, current.last) && current.length >= 4) {
        rings.add(current);
        continue;
      }

      var progress = true;
      while (progress) {
        progress = false;
        // Already closed?
        if (_pointsEqual(current.first, current.last) && current.length >= 4) {
          break;
        }
        for (var i = pool.length - 1; i >= 0; i--) {
          final candidate = pool[i];
          if (_pointsEqual(current.last, candidate.first)) {
            current.addAll(candidate.skip(1));
            pool.removeAt(i);
            progress = true;
            break;
          }
          if (_pointsEqual(current.last, candidate.last)) {
            final reversed = candidate.reversed.toList();
            current.addAll(reversed.skip(1));
            pool.removeAt(i);
            progress = true;
            break;
          }
          if (_pointsEqual(current.first, candidate.last)) {
            final prefix = List<_LatLon>.from(candidate)..removeLast();
            current.insertAll(0, prefix);
            pool.removeAt(i);
            progress = true;
            break;
          }
          if (_pointsEqual(current.first, candidate.first)) {
            final prefix = candidate.reversed.toList()..removeLast();
            current.insertAll(0, prefix);
            pool.removeAt(i);
            progress = true;
            break;
          }
        }
      }

      if (_pointsEqual(current.first, current.last) && current.length >= 4) {
        rings.add(current);
      }
      // Else: fragment couldn't close — dropped.
    }

    return rings;
  }

  static bool _pointsEqual(_LatLon a, _LatLon b) {
    return (a.lat - b.lat).abs() < _stitchEpsilonDeg &&
        (a.lon - b.lon).abs() < _stitchEpsilonDeg;
  }

  /// Douglas-Peucker on a closed ring.
  ///
  /// Tolerance in meters is converted to a degrees threshold using the
  /// approximate ratio 111 km per degree (latitude-independent for the
  /// scales we care about; error at 55°N is ~2%, negligible relative to
  /// the tolerance itself).
  List<_LatLon> _simplifyRing(List<_LatLon> ring, double toleranceMeters) {
    if (ring.length <= 4) return ring;
    final toleranceDeg = toleranceMeters / 111000.0;
    // DP expects a polyline; we treat the closed ring as such and re-close
    // afterwards.
    final open = ring.sublist(0, ring.length - 1);
    final kept = List<bool>.filled(open.length, false);
    kept[0] = true;
    kept[open.length - 1] = true;
    _dp(open, 0, open.length - 1, toleranceDeg, kept);
    final simplified = <_LatLon>[
      for (var i = 0; i < open.length; i++)
        if (kept[i]) open[i],
    ];
    // Close the ring.
    if (simplified.length < 3) return ring;
    simplified.add(simplified.first);
    return simplified;
  }

  void _dp(
    List<_LatLon> pts,
    int i0,
    int i1,
    double tolerance,
    List<bool> kept,
  ) {
    if (i1 <= i0 + 1) return;
    var maxDist = 0.0;
    var maxIdx = i0;
    for (var i = i0 + 1; i < i1; i++) {
      final d = _perpendicularDistance(pts[i], pts[i0], pts[i1]);
      if (d > maxDist) {
        maxDist = d;
        maxIdx = i;
      }
    }
    if (maxDist > tolerance) {
      kept[maxIdx] = true;
      _dp(pts, i0, maxIdx, tolerance, kept);
      _dp(pts, maxIdx, i1, tolerance, kept);
    }
  }

  static double _perpendicularDistance(_LatLon p, _LatLon a, _LatLon b) {
    final dx = b.lon - a.lon;
    final dy = b.lat - a.lat;
    if (dx == 0 && dy == 0) {
      final ex = p.lon - a.lon;
      final ey = p.lat - a.lat;
      return math.sqrt(ex * ex + ey * ey);
    }
    final t = ((p.lon - a.lon) * dx + (p.lat - a.lat) * dy) /
        (dx * dx + dy * dy);
    final projX = a.lon + t * dx;
    final projY = a.lat + t * dy;
    final ex = p.lon - projX;
    final ey = p.lat - projY;
    return math.sqrt(ex * ex + ey * ey);
  }

  /// Point-in-ring test via ray casting, even-odd rule.
  static bool _pointInRing(_LatLon p, List<_LatLon> ring) {
    if (ring.length < 4) return false;
    var inside = false;
    var j = ring.length - 1;
    for (var i = 0; i < ring.length; i++) {
      final yi = ring[i].lat;
      final xi = ring[i].lon;
      final yj = ring[j].lat;
      final xj = ring[j].lon;
      final intersect = ((yi > p.lat) != (yj > p.lat)) &&
          (p.lon < (xj - xi) * (p.lat - yi) / ((yj - yi) + 1e-30) + xi);
      if (intersect) inside = !inside;
      j = i;
    }
    return inside;
  }
}

class _LatLon {
  const _LatLon(this.lat, this.lon);
  final double lat;
  final double lon;
}
