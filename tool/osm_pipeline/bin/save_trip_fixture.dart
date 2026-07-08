// Phase 5 (Plan 05-08): CLI that reads a GPS trace JSON, computes its
// bbox, calls the live Overpass API for the ways in that bbox, and
// writes ways.json.gz next to the trace.
//
// Usage:
//   dart run tool/osm_pipeline/bin/save_trip_fixture.dart --trace path/to/gps_trace.json
//
// Requires an internet connection (hits the primary Overpass endpoint).
// Output: writes ways.json.gz next to the input gps_trace.json file.

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> argv) async {
  final traceArg = argv.indexOf('--trace');
  if (traceArg == -1 || traceArg + 1 >= argv.length) {
    stderr.writeln('Usage: save_trip_fixture --trace <path>');
    exit(2);
  }
  final tracePath = argv[traceArg + 1];
  final traceFile = File(tracePath);
  if (!traceFile.existsSync()) {
    stderr.writeln('Trace file not found: $tracePath');
    exit(2);
  }
  final list = (jsonDecode(traceFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  if (list.isEmpty) {
    stderr.writeln('Trace file is empty: $tracePath');
    exit(2);
  }
  var minLat = 90.0;
  var minLon = 180.0;
  var maxLat = -90.0;
  var maxLon = -180.0;
  for (final m in list) {
    final lat = (m['lat'] as num).toDouble();
    final lon = (m['lon'] as num).toDouble();
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lon < minLon) minLon = lon;
    if (lon > maxLon) maxLon = lon;
  }
  // Small padding to catch ways along the boundary.
  const pad = 0.001;
  minLat -= pad;
  maxLat += pad;
  minLon -= pad;
  maxLon += pad;

  final query = '[out:json][timeout:60];'
      '(way[highway]($minLat,$minLon,$maxLat,$maxLon););'
      'out body geom;';
  const endpoint = 'https://overpass-api.de/api/interpreter';
  stderr.writeln(
    'Fetching Overpass for bbox ($minLat, $minLon, $maxLat, $maxLon) ...',
  );
  final httpClient = HttpClient();
  try {
    final req = await httpClient.postUrl(Uri.parse(endpoint));
    req.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded');
    req.write('data=${Uri.encodeComponent(query)}');
    final resp = await req.close();
    if (resp.statusCode != 200) {
      stderr.writeln('Overpass returned ${resp.statusCode}');
      exit(1);
    }
    final body = await resp.transform(utf8.decoder).join();

    final outPath = tracePath.replaceAll(
      RegExp(r'gps_trace\.json$'),
      'ways.json.gz',
    );
    final gz = gzip.encode(utf8.encode(body));
    File(outPath).writeAsBytesSync(gz);
    stderr.writeln('Wrote $outPath (${gz.length} bytes)');
  } finally {
    httpClient.close();
  }
}
