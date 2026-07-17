// Build-time key-set equality assertion for the admin bundle and the
// region totals table (invariant 5 from 10-03-PLAN.md).
//
// Reads BOTH shipped assets:
//   assets/admin/germany_admin.geojson.gz  → set of feature osm_id values
//   assets/admin/region_totals.json.gz     → set of JSON map keys
//
// Asserts exact set equality. On mismatch, prints a symmetric difference
// (capped sample) and exits 1. On match, prints the count and exits 0.
//
// Run from inside tool/osm_pipeline/ (or from the repo root with an
// explicit --assets-dir):
//
//   # From tool/osm_pipeline/:
//   dart run bin/verify_bundle_totals_keys.dart
//
//   # From repo root:
//   dart run tool/osm_pipeline/bin/verify_bundle_totals_keys.dart \
//     --assets-dir=assets/admin
//
// MUST be run after any regeneration of the two assets to verify they came
// from the same pipeline run. The CI pipeline should call this as a
// post-build gate.
//
// Exit codes:
//   0  — sets are equal (OK)
//   1  — sets differ (mismatch — check symmetric difference in output)
//   2  — I/O error or malformed asset

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'assets-dir',
      abbr: 'd',
      help: 'Directory containing germany_admin.geojson.gz and '
          'region_totals.json.gz. Default: ../../assets/admin (from inside '
          'tool/osm_pipeline/).',
      defaultsTo: '../../assets/admin',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr
      ..writeln('Error: ${e.message}')
      ..writeln(parser.usage);
    exit(2);
  }

  if (args['help'] as bool) {
    stdout
      ..writeln('Verify that the admin bundle and totals table share '
          'the same osm_id key-set (invariant 5).')
      ..writeln()
      ..writeln(parser.usage);
    exit(0);
  }

  final assetsDir = args['assets-dir'] as String;
  final adminBundlePath = '$assetsDir/germany_admin.geojson.gz';
  final totalsPath = '$assetsDir/region_totals.json.gz';

  // Load + decode both assets.
  Set<String> polygonIds;
  Set<String> totalsKeys;

  try {
    polygonIds = await _loadPolygonOsmIds(adminBundlePath);
  } on Exception catch (e) {
    stderr
      ..writeln('ERROR loading admin bundle: $e')
      ..writeln('  path: $adminBundlePath');
    exit(2);
  }

  try {
    totalsKeys = await _loadTotalsKeys(totalsPath);
  } on Exception catch (e) {
    stderr
      ..writeln('ERROR loading totals table: $e')
      ..writeln('  path: $totalsPath');
    exit(2);
  }

  stdout
    ..writeln(
      'Admin bundle: ${polygonIds.length} osm_ids from $adminBundlePath',
    )
    ..writeln('Totals table: ${totalsKeys.length} keys from $totalsPath');

  if (polygonIds == totalsKeys) {
    stdout.writeln('OK — both assets contain the same ${polygonIds.length} '
        'osm_ids. Invariant 5 satisfied.');
    exit(0);
  }

  // Sets differ — print symmetric difference (capped).
  const kSampleCap = 20;
  final onlyInPolygons = polygonIds.difference(totalsKeys);
  final onlyInTotals = totalsKeys.difference(polygonIds);

  stderr
    ..writeln('MISMATCH — key-sets differ!')
    ..writeln('  polygon bundle: ${polygonIds.length} osm_ids')
    ..writeln('  totals table:   ${totalsKeys.length} keys')
    ..writeln('  only in polygon bundle (${onlyInPolygons.length}):');
  for (final id in onlyInPolygons.take(kSampleCap)) {
    stderr.writeln('    $id');
  }
  if (onlyInPolygons.length > kSampleCap) {
    stderr.writeln('    ... and ${onlyInPolygons.length - kSampleCap} more');
  }
  stderr.writeln('  only in totals table (${onlyInTotals.length}):');
  for (final id in onlyInTotals.take(kSampleCap)) {
    stderr.writeln('    $id');
  }
  if (onlyInTotals.length > kSampleCap) {
    stderr.writeln('    ... and ${onlyInTotals.length - kSampleCap} more');
  }
  stderr
    ..writeln()
    ..writeln('Both assets must be regenerated from the same pipeline run:')
    ..writeln(
      '  dart run bin/osm_pipeline.dart '
      '--pbf=<path/to/germany-latest.osm.pbf> '
      '--no-pmtiles '
      '--emit-admin-bundle=../../assets/admin/germany_admin.geojson.gz '
      '--emit-totals=../../assets/admin/region_totals.json.gz',
    );
  exit(1);
}

/// Reads `germany_admin.geojson.gz` and returns the set of `osm_id` values
/// from all feature properties, formatted as strings.
Future<Set<String>> _loadPolygonOsmIds(String path) async {
  final bytes = await File(path).readAsBytes();
  final decompressed = gzip.decode(bytes);
  final jsonStr = utf8.decode(decompressed);
  final Object? decoded = jsonDecode(jsonStr);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object at root');
  }
  final features = decoded['features'];
  if (features is! List) {
    throw const FormatException('Expected features array');
  }
  final ids = <String>{};
  for (final feature in features) {
    if (feature is! Map<String, dynamic>) continue;
    final props = feature['properties'];
    if (props is! Map<String, dynamic>) continue;
    final osmId = props['osm_id'];
    if (osmId == null) continue;
    // osm_id is stored as int in the GeoJSON properties; normalise to string.
    ids.add(osmId.toString());
  }
  return ids;
}

/// Reads `region_totals.json.gz` and returns its key-set.
Future<Set<String>> _loadTotalsKeys(String path) async {
  final bytes = await File(path).readAsBytes();
  final decompressed = gzip.decode(bytes);
  final jsonStr = utf8.decode(decompressed);
  final Object? decoded = jsonDecode(jsonStr);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object at root');
  }
  return decoded.keys.toSet();
}
