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
import 'dart:typed_data';

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path_provider/path_provider.dart';

/// Path of the bundled asset in the app rootBundle.
const String kAdminBundleAssetPath = 'assets/admin/germany_admin.geojson.gz';

/// Grid cell size in degrees.
const double _gridCellDeg = 0.01;

/// Parsed output of the admin bundle: the region list plus the hash grid.
///
/// Returned from the [compute] isolate as a plain Dart object; both fields
/// are Lists/Maps of primitives (and [AdminRegion], which is itself built
/// from primitive Lists), so they copy cleanly across the SendPort boundary.
class _ParsedAdminBundle {
  const _ParsedAdminBundle(this.regions, this.grid);

  final List<AdminRegion> regions;
  final Map<int, List<int>> grid;
}

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

  /// In-flight load future — single-flight guard. Without this, concurrent
  /// `regionAt` callers (e.g. multiple inbox cards each reverse-geocoding
  /// start+end) would each pass the `_regions == null` check during the
  /// `compute()` async gap and spawn their OWN isolate parsing the ~12 MB
  /// bundle in parallel — a memory spike that OOM-kills the app (Plan 06-07
  /// re-drive crash). Sharing one future collapses N parses into 1.
  Future<void>? _loading;

  /// Test-visible: how many times the underlying asset bytes were parsed.
  /// Used by tests to assert `ensureLoaded` is idempotent.
  int get bundleLoadCount => _bundleLoadCount;

  /// Idempotent — loads + indexes the bundle on first call, no-op after.
  ///
  /// The cheap asset read (`_loadBundleBytes`) stays on the UI isolate because
  /// the asset bundle is not reachable from a spawned isolate. The heavy work
  /// (gzip inflate + UTF-8 decode + JSON parse + polygon/bbox/grid build over
  /// the ~12 MB bundle) is offloaded to a background isolate via [compute] so
  /// it never blocks the UI thread. (Plan 06-07: this was an ANR/crash cause
  /// on the Trips tab, where every card triggered reverse-geocoding.)
  ///
  /// Concurrent callers share a single in-flight load ([_loading]) so the
  /// 12 MB parse happens exactly once even under a burst of `regionAt` calls.
  Future<void> ensureLoaded() {
    if (_regions != null) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await _loadBundleBytes();
      final parsed = await compute(_parseAdminBundle, bytes);
      _regions = parsed.regions;
      _grid = parsed.grid;
      _bundleLoadCount++;
    } finally {
      // Clear the guard so a post-[invalidate] reload can run again. On
      // success `_regions != null` short-circuits future calls anyway.
      _loading = null;
    }
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
    _loading = null;
  }

  /// Returns the total in-memory region count (after [ensureLoaded]).
  int get regionCount => _regions?.length ?? 0;

  Future<Uint8List> _loadBundleBytes() async {
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
        .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
  }

  static int _cellKey(int cellY, int cellX) {
    // Pack signed 20-bit cell coords into one int; y in high bits.
    // Global DE bbox stays well within +/- 20-bit range at 0.01° cells.
    final ny = (cellY + (1 << 19)) & 0xFFFFF;
    final nx = (cellX + (1 << 19)) & 0xFFFFF;
    return (ny << 20) | nx;
  }
}

/// Isolate entry point: inflate + parse the bundle bytes into regions + grid.
///
/// Runs via [compute] on a background isolate. Takes the raw (still gzipped)
/// asset bytes — the asset bundle itself is not reachable off the UI isolate,
/// so the caller reads the bytes first and hands them over here. The returned
/// [_ParsedAdminBundle] is plain Lists/Maps of primitives (+[AdminRegion]),
/// which copy cleanly back across the SendPort boundary.
_ParsedAdminBundle _parseAdminBundle(Uint8List bytes) {
  final decoded = utf8.decode(gzip.decode(bytes));
  final json = jsonDecode(decoded);
  if (json is! Map<String, dynamic>) {
    return const _ParsedAdminBundle([], {});
  }
  final features = json['features'];
  if (features is! List) {
    return const _ParsedAdminBundle([], {});
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
        final key = AdminRegionLookup._cellKey(y, x);
        (grid[key] ??= <int>[]).add(i);
      }
    }
  }

  return _ParsedAdminBundle(regions, grid);
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
