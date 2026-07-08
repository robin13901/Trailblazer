// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Lazy-loaded in-memory spatial index over the bundled Germany admin
// polygon asset. `regionAt(lat, lon, level)` returns the containing region
// at the requested admin_level in <5 ms after the first load.
//
// Index: hash grid at 0.01° cells (approx 1.1 km at DE latitudes).
// Bundled asset lives at `assets/admin/germany_admin.geojson.gz`. If a
// runtime-refreshed copy exists at `<AppDocsDir>/admin/germany_admin.geojson.gz`
// (dropped by [AdminBundleRefresher] in Plan 04-16 Task 3), that copy is
// preferred.

import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path_provider/path_provider.dart';

/// Path of the bundled asset in the app rootBundle.
const String kAdminBundleAssetPath = 'assets/admin/germany_admin.geojson.gz';

/// Grid cell size in degrees.
const double _gridCellDeg = 0.01;

/// Locates the containing admin region for a given `(lat, lon, adminLevel)`.
class AdminRegionLookup {
  AdminRegionLookup({
    AssetBundle? bundle,
    String assetPath = kAdminBundleAssetPath,
    Future<Directory> Function()? docsDirLoader,
  })  : _bundle = bundle ?? rootBundle,
        _assetPath = assetPath,
        _docsDirLoader = docsDirLoader ?? getApplicationDocumentsDirectory;

  final AssetBundle _bundle;
  final String _assetPath;
  final Future<Directory> Function() _docsDirLoader;

  List<AdminRegion>? _regions;
  Map<int, List<int>>? _grid;
  int _bundleLoadCount = 0;

  /// Test-visible: how many times the underlying asset bytes were parsed.
  /// Used by tests to assert `ensureLoaded` is idempotent.
  int get bundleLoadCount => _bundleLoadCount;

  /// Idempotent — loads + indexes the bundle on first call, no-op after.
  Future<void> ensureLoaded() async {
    if (_regions != null) return;
    final bytes = await _loadBundleBytes();
    final decoded = utf8.decode(gzip.decode(bytes));
    final json = jsonDecode(decoded);
    if (json is! Map<String, dynamic>) {
      _regions = const [];
      _grid = const {};
      return;
    }
    final features = json['features'];
    if (features is! List) {
      _regions = const [];
      _grid = const {};
      return;
    }

    final regions = <AdminRegion>[];
    for (final f in features) {
      final region = _regionFromFeature(f);
      if (region != null) regions.add(region);
    }

    // Build hash grid: map cell key → list of region indices whose bbox
    // overlaps that cell.
    final grid = <int, List<int>>{};
    for (var i = 0; i < regions.length; i++) {
      final r = regions[i];
      final minCellY = (r.bboxMinLat / _gridCellDeg).floor();
      final maxCellY = (r.bboxMaxLat / _gridCellDeg).floor();
      final minCellX = (r.bboxMinLon / _gridCellDeg).floor();
      final maxCellX = (r.bboxMaxLon / _gridCellDeg).floor();
      for (var y = minCellY; y <= maxCellY; y++) {
        for (var x = minCellX; x <= maxCellX; x++) {
          final key = _cellKey(y, x);
          (grid[key] ??= <int>[]).add(i);
        }
      }
    }

    _regions = regions;
    _grid = grid;
    _bundleLoadCount++;
  }

  /// Looks up the containing region at [adminLevel] for the given point.
  ///
  /// Returns `null` when no region at that level contains the point
  /// (over water, over a level not represented in the bundle, or outside
  /// Germany).
  Future<AdminRegion?> regionAt(
    double lat,
    double lon,
    int adminLevel,
  ) async {
    await ensureLoaded();
    final grid = _grid!;
    final regions = _regions!;
    final cellY = (lat / _gridCellDeg).floor();
    final cellX = (lon / _gridCellDeg).floor();
    final key = _cellKey(cellY, cellX);
    final candidates = grid[key];
    if (candidates == null) return null;
    for (final idx in candidates) {
      final region = regions[idx];
      if (region.adminLevel != adminLevel) continue;
      if (region.containsPoint(lat, lon)) return region;
    }
    return null;
  }

  /// Clears the in-memory cache; next [regionAt] reload from disk. Used by
  /// the runtime refresher after replacing the docs-dir copy.
  void invalidate() {
    _regions = null;
    _grid = null;
  }

  /// Returns the total in-memory region count (after [ensureLoaded]).
  int get regionCount => _regions?.length ?? 0;

  Future<List<int>> _loadBundleBytes() async {
    // Runtime-refreshed copy takes precedence.
    try {
      final docsDir = await _docsDirLoader();
      final override = File('${docsDir.path}/admin/germany_admin.geojson.gz');
      if (override.existsSync()) {
        return override.readAsBytesSync();
      }
    } on Object {
      // Fall through to bundled asset.
    }
    final byteData = await _bundle.load(_assetPath);
    return byteData.buffer
        .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes)
        .toList();
  }

  static int _cellKey(int cellY, int cellX) {
    // Pack signed 20-bit cell coords into one int; y in high bits.
    // Global DE bbox stays well within +/- 20-bit range at 0.01° cells.
    final ny = (cellY + (1 << 19)) & 0xFFFFF;
    final nx = (cellX + (1 << 19)) & 0xFFFFF;
    return (ny << 20) | nx;
  }

  AdminRegion? _regionFromFeature(Object? raw) {
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

    // Normalize to MultiPolygon shape (list of polygons, each a list of
    // rings, each a list of [lat, lon] pairs). GeoJSON is [lon, lat] — we
    // transpose to [lat, lon] here so runtime hot-path skips the swap.
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

    // Bbox.
    var minLat = double.infinity;
    var minLon = double.infinity;
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
    );
  }
}
