/// Stage H — emit the admin-polygon GeoJSON bundle + per-region totals table.
///
/// Queries the FINAL `osm.sqlite` produced by Stage E (which has
/// `ways.length_m` already computed and `admin_regions.osm_relation_id`
/// keyed identically). Both output files therefore carry the same
/// `osm_relation_id` key-space by construction, satisfying invariant 5.
///
/// ## Data-path choice (recorded in 10-03-SUMMARY.md)
///
/// The plan offered two options for the totals query:
///   (a) `osm.sqlite` post-Stage-E — needs UNION of `way_admin` (cross-border
///       rows, all L9/L10) + denorm columns `admin_region_id_l{4,6,8}` for
///       wholly-contained ways (since those rows are stripped from `way_admin`
///       during Stage E denormalization).
///   (b) Scratch DB pre-Stage-E — `way_admin_raw` has ALL rows, but `ways_raw`
///       does NOT store `length_m` (pitfall 1 from 10-RESEARCH).
///
/// **Choice: (a) `osm.sqlite` with UNION.** The scratch DB is deleted after
/// Stage E, so querying it would require keeping it alive. The `osm.sqlite`
/// path is simpler operationally (one self-contained file) and the UNION
/// is straightforward SQL.
///
/// ## Kfz parity guarantee
///
/// Ways in `osm.sqlite` are already filtered to `source='kfz'` (written by
/// Stage B via `isKfzWay()` / `kKfzHighwayTags`) — no additional highway
/// filtering is needed here. The totals are therefore bit-identical to the
/// lengths the runtime matcher sees. See `kKfzHighwayTags` in
/// `tool/osm_pipeline/lib/filter/highway_class.dart` and `kfzHighwayClasses`
/// in `lib/features/matching/domain/way_candidate.dart` for the 14-tag set.
///
/// ## Admin bundle emission
///
/// The `admin_regions` table stores assembled + WKB-encoded multipolygon
/// geometry (one row per region). Stage H decodes each row's WKB back into
/// a coordinate list and applies the same Douglas-Peucker simplification
/// that `fetch_admin_polygons.dart` applies to Overpass output.
///
/// NOTE: `admin_regions` does not store the `name:de` tag — the pipeline
/// scratch schema only persists `name` (see `admin_scratch_schema.dart`).
/// The GeoJSON properties therefore omit `name:de`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/logger.dart';
import 'package:sqlite3/sqlite3.dart';

/// Warn threshold for the gzipped totals file (300 KB).
const int _kTotalsWarnBytes = 300 * 1024;

/// Hard limit for the gzipped admin bundle (15 MB) — matches
/// `fetch_admin_polygons.dart`.
const int _kAdminBudgetBytes = 15 * 1024 * 1024;

/// Runs Stage H: reads [osmSqlitePath] and writes both output assets.
///
/// [adminBundlePath] — destination for `germany_admin.geojson.gz`.
/// [totalsPath]      — destination for `region_totals.json.gz`.
///
/// Returns a [StageHResult] summary. Throws [StageHError] on any hard
/// failure (budget exceeded, DB read error).
///
/// Set [toleranceOverride] to tighten DP simplification for L8/L9/L10 if
/// the bundle exceeds the 15 MB budget on a first pass.
StageHResult runStageH({
  required String osmSqlitePath,
  required String adminBundlePath,
  required String totalsPath,
  double? toleranceOverride,
}) {
  Logger.info('Stage H: emit admin bundle + per-region totals...');
  Logger.info('  reading: $osmSqlitePath');

  final db = sqlite3.open(osmSqlitePath, mode: OpenMode.readOnly);
  try {
    // -----------------------------------------------------------------------
    // 1. Emit per-region totals from osm.sqlite.
    // -----------------------------------------------------------------------
    Logger.info('  Stage H step 1: compute per-region Kfz totals...');
    final totals = _computeTotals(db);
    Logger.info('  ${totals.length} region totals computed.');

    final totalsJson = jsonEncode(totals);
    final totalsBytes = utf8.encode(totalsJson);
    final totalsGzipped = gzip.encode(totalsBytes);

    if (totalsGzipped.length > _kTotalsWarnBytes) {
      Logger.warn(
        '  totals file is ${totalsGzipped.length} bytes gzipped '
        '(> ${_kTotalsWarnBytes ~/ 1024} KB — check for unexpected rows).',
      );
    }

    final totalsFile = File(totalsPath);
    totalsFile.parent.createSync(recursive: true);
    totalsFile.writeAsBytesSync(totalsGzipped);

    Logger.info(
      '  totals written: $totalsPath '
      '(${totalsGzipped.length} bytes gzipped)',
    );

    // -----------------------------------------------------------------------
    // 2. Emit admin GeoJSON bundle from osm.sqlite.
    // -----------------------------------------------------------------------
    Logger.info('  Stage H step 2: emit admin GeoJSON bundle...');
    final tolerance = toleranceOverride;
    final result = _emitAdminBundle(db, adminBundlePath, tolerance);
    Logger.info(
      '  admin bundle written: $adminBundlePath '
      '(${result.gzippedBytes} bytes gzipped, '
      '${result.featureCount} features, '
      '${result.l9Count} L9)',
    );

    if (result.gzippedBytes > _kAdminBudgetBytes) {
      throw StageHError(
        'Admin bundle exceeds 15 MB budget: '
        '${result.gzippedBytes} bytes. '
        'Re-run with a stricter toleranceOverride (e.g. 150 m for L8/L9/L10).',
      );
    }

    return StageHResult(
      totalsPath: totalsPath,
      totalsGzippedBytes: totalsGzipped.length,
      regionCount: totals.length,
      adminBundlePath: adminBundlePath,
      adminGzippedBytes: result.gzippedBytes,
      featureCount: result.featureCount,
      l9Count: result.l9Count,
    );
  } finally {
    db.dispose();
  }
}

// ---------------------------------------------------------------------------
// Totals computation
// ---------------------------------------------------------------------------

/// Queries `osm.sqlite` for per-region Kfz road totals.
///
/// Covers BOTH attribution paths required by `kDenormAdminLevels = [2,4,6,8]`:
///
/// Path A — cross-border ways and ALL L9/L10 ways: these live in the `way_admin`
///   table (rows that were not eligible for denorm, or are at levels 9/10).
///   `SUM(w.length_m * (wa.fraction_end - wa.fraction_start))`
///
/// Path B — wholly-contained L4/L6/L8 ways: Stage E strips these from
///   `way_admin` into `ways.admin_region_id_l{4,6,8}` columns. We recover them
///   by joining back to `admin_regions` on those columns.
///   `SUM(w.length_m)` (fraction = 1.0 for wholly-contained ways).
///
/// The two paths are UNIONed and the outer query sums + groups by region_id.
/// L2 (Germany country boundary) is excluded — it would produce a meaningless
/// 645,000 km total and the runtime never displays it.
///
/// Key type: String (`CAST(osm_relation_id AS TEXT)`) to match
/// `coverage_cache.region_id` storage format.
Map<String, double> _computeTotals(Database db) {
  // language=SQLite
  const sql = '''
WITH cross_border AS (
  -- Path A: cross-border ways + all L9/L10 (all rows in way_admin).
  SELECT  CAST(ar.osm_relation_id AS TEXT)                          AS region_id,
          SUM(w.length_m * (wa.fraction_end - wa.fraction_start))   AS total_m
  FROM    way_admin wa
  JOIN    ways w           ON w.way_id    = wa.way_id
  JOIN    admin_regions ar ON ar.region_id = wa.region_id
  WHERE   ar.admin_level IN (4, 6, 8, 9, 10)
  GROUP   BY ar.osm_relation_id
),
denorm_l4 AS (
  -- Path B (L4): wholly-contained ways stored in denorm column.
  SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
          SUM(w.length_m)                  AS total_m
  FROM    ways w
  JOIN    admin_regions ar ON ar.region_id = w.admin_region_id_l4
  WHERE   w.admin_region_id_l4 IS NOT NULL
  GROUP   BY ar.osm_relation_id
),
denorm_l6 AS (
  SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
          SUM(w.length_m)                  AS total_m
  FROM    ways w
  JOIN    admin_regions ar ON ar.region_id = w.admin_region_id_l6
  WHERE   w.admin_region_id_l6 IS NOT NULL
  GROUP   BY ar.osm_relation_id
),
denorm_l8 AS (
  SELECT  CAST(ar.osm_relation_id AS TEXT) AS region_id,
          SUM(w.length_m)                  AS total_m
  FROM    ways w
  JOIN    admin_regions ar ON ar.region_id = w.admin_region_id_l8
  WHERE   w.admin_region_id_l8 IS NOT NULL
  GROUP   BY ar.osm_relation_id
),
all_paths AS (
  SELECT region_id, total_m FROM cross_border
  UNION ALL
  SELECT region_id, total_m FROM denorm_l4
  UNION ALL
  SELECT region_id, total_m FROM denorm_l6
  UNION ALL
  SELECT region_id, total_m FROM denorm_l8
)
SELECT  region_id,
        SUM(total_m) AS total_length_m
FROM    all_paths
GROUP   BY region_id
ORDER   BY region_id;
''';

  final rows = db.select(sql);
  final result = <String, double>{};
  for (final row in rows) {
    final regionId = row['region_id'] as String;
    final totalM = (row['total_length_m'] as num).toDouble();
    result[regionId] = totalM;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Admin bundle emission
// ---------------------------------------------------------------------------

class _AdminEmitResult {
  const _AdminEmitResult({
    required this.gzippedBytes,
    required this.featureCount,
    required this.l9Count,
  });
  final int gzippedBytes;
  final int featureCount;
  final int l9Count;
}

/// Emits a GeoJSON FeatureCollection from `admin_regions` in [db].
///
/// Applies Douglas-Peucker simplification (via [_simplifyRing]) with the
/// same level-dependent tolerances as `AdminPolygonSimplifier` in the
/// `admin_geometry` package. Excludes L2. Includes L9.
///
/// [toleranceOverride] replaces the L8/L9/L10 tolerance if the bundle would
/// otherwise exceed the 15 MB budget — mirrors `withStricterL8`.
_AdminEmitResult _emitAdminBundle(
  Database db,
  String outputPath,
  double? toleranceOverride,
) {
  final rows = db.select('''
SELECT  region_id,
        osm_relation_id,
        admin_level,
        name,
        geometry_wkb
FROM    admin_regions
WHERE   admin_level IN (4, 6, 8, 9, 10)
ORDER   BY admin_level, osm_relation_id;
''');

  final features = <Map<String, dynamic>>[];
  var l9Count = 0;

  for (final row in rows) {
    final osmRelationId = row['osm_relation_id'] as int;
    final adminLevel = row['admin_level'] as int;
    final name = row['name'] as String;
    final wkbBlob = row['geometry_wkb'] as Uint8List;

    final toleranceM = toleranceOverride != null && adminLevel >= 8
        ? toleranceOverride
        : _defaultTolerance(adminLevel);

    final multipolygonCoords = _decodeWkbToGeoJsonCoords(wkbBlob, toleranceM);
    if (multipolygonCoords == null) continue;

    final properties = <String, dynamic>{
      'osm_id': osmRelationId,
      'admin_level': adminLevel,
      'name': name,
      // name:de is NOT stored in the pipeline's admin_regions table
      // (the scratch schema only persists `name`). Omitted here.
    };

    features.add({
      'type': 'Feature',
      'properties': properties,
      'geometry': {
        'type': 'MultiPolygon',
        'coordinates': multipolygonCoords,
      },
    });

    if (adminLevel == 9) l9Count++;
  }

  final featureCollection = <String, dynamic>{
    'type': 'FeatureCollection',
    'features': features,
  };

  final jsonBytes = utf8.encode(jsonEncode(featureCollection));
  final gzipped = gzip.encode(jsonBytes);

  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(gzipped);

  return _AdminEmitResult(
    gzippedBytes: gzipped.length,
    featureCount: features.length,
    l9Count: l9Count,
  );
}

// ---------------------------------------------------------------------------
// DP tolerances (mirrors AdminPolygonSimplifier._toleranceMetersPerLevel)
// ---------------------------------------------------------------------------

double _defaultTolerance(int adminLevel) {
  return switch (adminLevel) {
    2 => 10,
    4 => 30,
    6 => 50,
    8 => 100,
    9 => 100,
    10 => 100,
    _ => 100,
  };
}

// ---------------------------------------------------------------------------
// WKB decoder → GeoJSON coordinate arrays
// ---------------------------------------------------------------------------

/// Decodes a WKB-encoded MultiPolygon and applies DP simplification.
///
/// Returns `null` if the WKB is malformed or produces no valid rings.
///
/// WKB layout (little-endian, OGC §8.2.7):
///   1 byte   byte order (0x01 = LE)
///   4 bytes  type = 6 (MultiPolygon)
///   4 bytes  polygon count N
///   for each of N polygons:
///     1 byte   byte order
///     4 bytes  type = 3 (Polygon)
///     4 bytes  ring count R
///     for each of R rings:
///       4 bytes  point count M
///       M × (8 bytes lng + 8 bytes lat)
///
/// Note: The WKB encoder in `wkb_writer.dart` writes lng first, lat second
/// (standard GIS convention). GeoJSON also uses [lng, lat] order.
List<List<List<List<double>>>>? _decodeWkbToGeoJsonCoords(
  Uint8List wkb,
  double toleranceM,
) {
  try {
    final bd = ByteData.sublistView(wkb);
    var offset = 0;

    // Read byte order.
    final byteOrder = bd.getUint8(offset);
    offset += 1;
    if (byteOrder != 1) return null; // only little-endian supported

    const endian = Endian.little;

    final type = bd.getUint32(offset, endian);
    offset += 4;
    if (type != 6) return null; // must be MultiPolygon

    final polyCount = bd.getUint32(offset, endian);
    offset += 4;

    final multiPolygonCoords = <List<List<List<double>>>>[];

    for (var p = 0; p < polyCount; p++) {
      // Polygon header.
      offset += 1; // byte order (ignored — always matches outer)
      final polyType = bd.getUint32(offset, endian);
      offset += 4;
      if (polyType != 3) return null; // must be Polygon

      final ringCount = bd.getUint32(offset, endian);
      offset += 4;

      final polygonRings = <List<List<double>>>[];

      for (var r = 0; r < ringCount; r++) {
        final pointCount = bd.getUint32(offset, endian);
        offset += 4;

        final rawPts = <List<double>>[];
        for (var i = 0; i < pointCount; i++) {
          final lng = bd.getFloat64(offset, endian);
          offset += 8;
          final lat = bd.getFloat64(offset, endian);
          offset += 8;
          rawPts.add([lng, lat]);
        }

        // Apply DP simplification.
        final simplified = _simplifyRing(rawPts, toleranceM);
        if (simplified.length >= 4) {
          polygonRings.add(simplified);
        }
      }

      if (polygonRings.isNotEmpty) {
        multiPolygonCoords.add(polygonRings);
      }
    }

    return multiPolygonCoords.isEmpty ? null : multiPolygonCoords;
  } on Exception {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Douglas-Peucker simplification for coordinate arrays
// ---------------------------------------------------------------------------

/// Douglas-Peucker simplification of a closed ring (GeoJSON format).
///
/// [ring] is a list of `[lng, lat]` pairs, first == last (closed).
/// [toleranceM] is the perpendicular-distance threshold in metres.
///
/// Returns the simplified ring (still closed), or [ring] unchanged if it
/// has ≤ 4 points. The output always has first == last.
List<List<double>> _simplifyRing(
  List<List<double>> ring,
  double toleranceM,
) {
  if (ring.length <= 4) return ring;
  // Convert tolerance from metres to degrees (≈ 111 km/degree, ~2% error).
  final toleranceDeg = toleranceM / 111000.0;
  // Treat the closed ring as an open polyline (skip closing duplicate).
  final open = ring.sublist(0, ring.length - 1);
  final kept = List<bool>.filled(open.length, false);
  kept[0] = true;
  kept[open.length - 1] = true;
  _dp(open, 0, open.length - 1, toleranceDeg, kept);

  final simplified = <List<double>>[
    for (var i = 0; i < open.length; i++)
      if (kept[i]) open[i],
  ];

  if (simplified.length < 3) return ring;
  // Close the ring.
  simplified.add(simplified.first);
  return simplified;
}

void _dp(
  List<List<double>> pts,
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

/// Perpendicular distance of point [p] from line [a]→[b] in degrees.
double _perpendicularDistance(
  List<double> p,
  List<double> a,
  List<double> b,
) {
  final dx = b[0] - a[0];
  final dy = b[1] - a[1];
  if (dx == 0 && dy == 0) {
    final ex = p[0] - a[0];
    final ey = p[1] - a[1];
    return ex * ex + ey * ey;
  }
  final t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy);
  final projX = a[0] + t * dx;
  final projY = a[1] + t * dy;
  final ex = p[0] - projX;
  final ey = p[1] - projY;
  return ex * ex + ey * ey;
}

// ---------------------------------------------------------------------------
// Public result + error types
// ---------------------------------------------------------------------------

/// Summary of a successful [runStageH] invocation.
class StageHResult {
  /// Create a result record.
  const StageHResult({
    required this.totalsPath,
    required this.totalsGzippedBytes,
    required this.regionCount,
    required this.adminBundlePath,
    required this.adminGzippedBytes,
    required this.featureCount,
    required this.l9Count,
  });

  /// Absolute path to the written `region_totals.json.gz`.
  final String totalsPath;

  /// Gzipped byte size of the totals file.
  final int totalsGzippedBytes;

  /// Number of region entries in the totals table.
  final int regionCount;

  /// Absolute path to the written `germany_admin.geojson.gz`.
  final String adminBundlePath;

  /// Gzipped byte size of the admin bundle.
  final int adminGzippedBytes;

  /// Total GeoJSON feature count.
  final int featureCount;

  /// Number of admin_level=9 (Ortsteil) features.
  final int l9Count;
}

/// Fatal Stage H failure (budget exceeded or DB error).
class StageHError extends Error {
  /// Create an error.
  StageHError(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => 'StageHError: $message';
}
