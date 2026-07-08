// Phase 5 (Plan 05-08): Golden corpus regression test.
//
// Iterates over every subdirectory in test/fixtures/golden_trips/ and
// asserts HmmMatcher.match(loaded_trace, loaded_ways) produces the
// interval-wayId sequence in expected_ways.json.
//
// The test SKIPS an empty corpus (no directories) — this keeps the test
// green on a fresh checkout, but ANY committed fixture MUST pass.
//
// How to add a fixture: see test/fixtures/golden_trips/README.md.

import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

// Test-only fixture helper — imported from test/helpers, not from lib/.
import '../../helpers/fixture_way_candidate_source.dart';

void main() {
  final corporaDir = Directory('test/fixtures/golden_trips');
  if (!corporaDir.existsSync()) {
    test('golden corpus: directory missing (skipped)', () {}, skip: true);
    return;
  }

  final tripDirs = corporaDir
      .listSync()
      .whereType<Directory>()
      .where((d) => File('${d.path}/gps_trace.json').existsSync())
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (tripDirs.isEmpty) {
    test('golden corpus: no fixtures (skipped)', () {}, skip: true);
    return;
  }

  for (final tripDir in tripDirs) {
    final slug = tripDir.path.split(RegExp(r'[\\/]')).last;
    test('golden trip: $slug', () async {
      final trace = _loadGpsTrace(tripDir);
      final source = await FixtureWayCandidateSource.fromGzippedOverpassJson(
        '${tripDir.path}/ways.json.gz',
      );
      final bbox = _bboxOfTrace(trace);
      final ways = await source.fetchWaysInBbox(
        minLat: bbox.minLat,
        minLon: bbox.minLon,
        maxLat: bbox.maxLat,
        maxLon: bbox.maxLon,
      );

      final result = const HmmMatcher().match(fixes: trace, ways: ways);

      final expected = _loadExpectedWays(tripDir);
      final actualIds = result.intervals.map((i) => i.wayId).toList();
      final expectedIds = expected.map((e) => e['wayId'] as int).toList();
      expect(
        actualIds,
        equals(expectedIds),
        reason: 'golden trip $slug — wayId sequence mismatch\n'
            'expected: $expectedIds\nactual:   $actualIds',
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<GpsFix> _loadGpsTrace(Directory dir) {
  final raw = File('${dir.path}/gps_trace.json').readAsStringSync();
  final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  return list
      .map(
        (m) => GpsFix(
          lat: (m['lat'] as num).toDouble(),
          lon: (m['lon'] as num).toDouble(),
          accuracyMeters:
              (m['accuracy'] as num?)?.toDouble() ?? double.nan,
          speedKmh: (m['speedKmh'] as num?)?.toDouble() ?? 0.0,
          ts: DateTime.parse(m['ts'] as String),
        ),
      )
      .toList();
}

List<Map<String, dynamic>> _loadExpectedWays(Directory dir) {
  final raw = File('${dir.path}/expected_ways.json').readAsStringSync();
  return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
}

({double minLat, double minLon, double maxLat, double maxLon}) _bboxOfTrace(
  List<GpsFix> fixes,
) {
  var minLat = 90.0;
  var minLon = 180.0;
  var maxLat = -90.0;
  var maxLon = -180.0;
  for (final f in fixes) {
    if (f.lat < minLat) minLat = f.lat;
    if (f.lat > maxLat) maxLat = f.lat;
    if (f.lon < minLon) minLon = f.lon;
    if (f.lon > maxLon) maxLon = f.lon;
  }
  return (minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon);
}
