// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// One-shot dev CLI to fetch Germany admin-boundary relations from Overpass,
// simplify them, and write a gzipped GeoJSON FeatureCollection to disk.
//
// Consumes the shared `admin_geometry` leaf package (also consumed by the
// runtime `AdminBundleRefresher` in the main Flutter app) — single source of
// truth for Overpass fetch + multipolygon assembly + Douglas-Peucker
// simplification.
//
// Usage (from inside tool/osm_pipeline/):
//   dart run bin/fetch_admin_polygons.dart ../../assets/admin/germany_admin.geojson.gz
//
// The Overpass query can take up to ~10 minutes; do not retry mid-flight
// unless the process fails outright.

import 'dart:convert';
import 'dart:io';

import 'package:admin_geometry/admin_geometry.dart';

Future<void> main(List<String> args) async {
  final outputPath = args.isNotEmpty
      ? args[0]
      : '../../assets/admin/germany_admin.geojson.gz';

  stderr.writeln('[fetch_admin_polygons] Fetching DE admin relations from '
      'Overpass — this can take up to ~10 minutes...');
  final downloader = AdminPolygonDownloader();
  final raw = await downloader.fetchDeAdminRelations();
  stderr.writeln('[fetch_admin_polygons] Received '
      '${(raw.length / 1024).toStringAsFixed(1)} KB. '
      'Assembling multipolygons + simplifying...');

  const simplifier = AdminPolygonSimplifier();
  final featureCollection = simplifier.assembleAndSimplify(raw);
  final featureCount =
      (featureCollection['features']! as List).length;
  stderr
    ..writeln('[fetch_admin_polygons] $featureCount features assembled.')
    ..writeln(
      '[fetch_admin_polygons] Writing gzipped GeoJSON to $outputPath...',
    );
  final bytes = utf8.encode(jsonEncode(featureCollection));
  final gzipped = gzip.encode(bytes);
  final outFile = File(outputPath);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsBytes(gzipped);

  final sizeMb = (gzipped.length / 1024 / 1024).toStringAsFixed(2);
  stderr.writeln('[fetch_admin_polygons] Done. '
      '${gzipped.length} bytes ($sizeMb MB gzipped).');
  if (gzipped.length > 15 * 1024 * 1024) {
    stderr.writeln('[fetch_admin_polygons] WARNING: size exceeds 15 MB '
        'budget. Consider stricter DP tolerances.');
    exitCode = 1;
  }
  downloader.close();
}
