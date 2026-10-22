// Pure admin-bundle parsing (2026-07-22) — extracted from admin_region_lookup.dart
// so BOTH the main-isolate lookup AND the coverage-compute worker isolate can
// parse the bundled Germany polygon asset without importing Flutter.
//
// STRICTLY PURE + isolate-safe: imports only dart:convert, dart:typed_data, and
// the pure AdminRegion value type. NO Flutter, NO Drift, NO rootBundle. The raw
// gzipped bytes are read by the CALLER on the main isolate (rootBundle is
// unreachable from a spawned isolate) and handed to [parseAdminBundle].

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:auto_explore/features/admin/data/admin_region.dart';

/// Inflate + parse the gzipped GeoJSON bundle bytes into a region list.
///
/// Top-level so it can run via `compute()` (main isolate) OR directly inside a
/// long-lived worker isolate. The returned `List<AdminRegion>` is built from
/// primitive Lists, so it copies cleanly across a SendPort when needed.
List<AdminRegion> parseAdminBundle(Uint8List bytes) {
  final decoded = utf8.decode(gzip.decode(bytes));
  final json = jsonDecode(decoded);
  if (json is! Map<String, dynamic>) {
    return const [];
  }
  final features = json['features'];
  if (features is! List) {
    return const [];
  }

  final regions = <AdminRegion>[];
  for (final f in features) {
    final region = regionFromFeature(f);
    if (region != null) regions.add(region);
  }
  return regions;
}

/// Buckets regions by `adminLevel` so a lookup scans only the relevant level.
Map<int, List<AdminRegion>> bucketRegionsByLevel(List<AdminRegion> regions) {
  final byLevel = <int, List<AdminRegion>>{};
  for (final r in regions) {
    (byLevel[r.adminLevel] ??= <AdminRegion>[]).add(r);
  }
  return byLevel;
}

/// Parse one GeoJSON feature into an [AdminRegion], or null when malformed.
///
/// GeoJSON coordinates are `[lon, lat]`; transposed to `[lat, lon]` here so the
/// runtime hot path (containsPoint) skips the swap.
AdminRegion? regionFromFeature(Object? raw) {
  if (raw is! Map<String, dynamic>) return null;
  final props = raw['properties'];
  if (props is! Map<String, dynamic>) return null;
  final osmId = props['osm_id'];
  if (osmId is! int) return null;
  final adminLevel = props['admin_level'];
  if (adminLevel is! int) return null;
  final name = props['name'];
  if (name is! String || name.isEmpty) return null;
  final nameDe = props['name:de'];
  final geom = raw['geometry'];
  if (geom is! Map<String, dynamic>) return null;
  final geomType = geom['type'];
  final coords = geom['coordinates'];
  if (coords is! List) return null;

  final polygons = <List<List<List<double>>>>[];
  if (geomType == 'MultiPolygon') {
    for (final poly in coords) {
      if (poly is! List) continue;
      final rings = <List<List<double>>>[];
      for (final ring in poly) {
        if (ring is! List) continue;
        final r = <List<double>>[];
        for (final p in ring) {
          if (p is! List || p.length < 2) continue;
          final lon = p[0];
          final lat = p[1];
          if (lat is! num || lon is! num) continue;
          r.add([lat.toDouble(), lon.toDouble()]);
        }
        if (r.length >= 4) rings.add(r);
      }
      if (rings.isNotEmpty) polygons.add(rings);
    }
  } else if (geomType == 'Polygon') {
    final rings = <List<List<double>>>[];
    for (final ring in coords) {
      if (ring is! List) continue;
      final r = <List<double>>[];
      for (final p in ring) {
        if (p is! List || p.length < 2) continue;
        final lon = p[0];
        final lat = p[1];
        if (lat is! num || lon is! num) continue;
        r.add([lat.toDouble(), lon.toDouble()]);
      }
      if (r.length >= 4) rings.add(r);
    }
    if (rings.isNotEmpty) polygons.add(rings);
  } else {
    return null;
  }
  if (polygons.isEmpty) return null;

  var minLat = double.infinity;  var minLon = double.infinity;
  var maxLat = -double.infinity;
  var maxLon = -double.infinity;
  for (final poly in polygons) {
    for (final ring in poly) {
      for (final p in ring) {
        if (p[0] < minLat) minLat = p[0];
        if (p[0] > maxLat) maxLat = p[0];
        if (p[1] < minLon) minLon = p[1];
        if (p[1] > maxLon) maxLon = p[1];
      }
    }
  }

  // Prefer the bundled geodesic area (available after Python tool rebuild);
  // fall back to the spherical-shoelace approximation (~0.3% error, sufficient
  // for display). areaKm2 is never negative; 0.0 means degenerate geometry.
  final bundledArea = props['area_km2'];
  final areaKm2 =
      bundledArea is num && bundledArea > 0
          ? bundledArea.toDouble()
          : _computeAreaKm2(polygons);

  return AdminRegion(
    osmId: osmId,
    adminLevel: adminLevel,
    name: name,
    nameDe: nameDe is String && nameDe.isNotEmpty ? nameDe : null,
    bboxMinLat: minLat,
    bboxMinLon: minLon,
    bboxMaxLat: maxLat,
    bboxMaxLon: maxLon,
    polygons: polygons,
    areaKm2: areaKm2,
  );
}

/// Geodesic area in km² for a MultiPolygon. Outer rings add, holes subtract.
/// Uses the spherical-shoelace (Chamberlain-Duquette) formula — ~0.3% error for
/// Germany's polygon sizes, which is indistinguishable in the display.
double _computeAreaKm2(List<List<List<List<double>>>> polygons) {
  var totalM2 = 0.0;
  for (final poly in polygons) {
    if (poly.isEmpty) continue;
    totalM2 += _ringAreaM2(poly.first);
    for (var hole = 1; hole < poly.length; hole++) {
      totalM2 -= _ringAreaM2(poly[hole]);
    }
  }
  return (totalM2 / 1e6).abs();
}

/// Signed spherical-shoelace area in m² for one ring of `[lat, lon]` points.
double _ringAreaM2(List<List<double>> ring) {
  if (ring.length < 4) return 0;
  const earthRadiusM = 6378137.0;
  var sum = 0.0;
  for (var i = 0; i < ring.length - 1; i++) {
    final lat1 = ring[i][0] * math.pi / 180.0;
    final lat2 = ring[i + 1][0] * math.pi / 180.0;
    final dLon = (ring[i + 1][1] - ring[i][1]) * math.pi / 180.0;
    sum += dLon * (2 + math.sin(lat1) + math.sin(lat2));
  }
  return sum * earthRadiusM * earthRadiusM / 4;
}
