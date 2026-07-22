// CoverageComputeIsolate round-trip tests (2026-07-22). Mirrors
// matcher_isolate_test.dart: spawns the real isolate, ships in-memory bundle
// bytes, runs a compute job, asserts the accum. Timeout 30s to fail fast on
// hangs; dispose in tearDown.

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_isolate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

const _bbox = LatLonBbox(minLat: 49.7, minLon: 9.1, maxLat: 49.9, maxLon: 9.3);

/// Gzip a synthetic Overpass tile wrapping [ways].
Uint8List _gzTile(List<WayCandidate> ways) {
  final env = {
    'version': 0.6,
    'elements': [
      for (final w in ways)
        {
          'type': 'way',
          'id': w.wayId,
          'geometry': [
            for (final p in w.geometry) {'lat': p.latitude, 'lon': p.longitude},
          ],
          'tags': {'highway': w.highwayClass},
        },
    ],
  };
  return Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(env))));
}

/// Gzip a one-feature admin GeoJSON FeatureCollection: level-8 square around
/// Kleinheubach, osm_id 151999.
Uint8List _gzAdminBundle() {
  final fc = {
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'properties': {
          'osm_id': 151999,
          'admin_level': 8,
          'name': 'Kleinheubach',
        },
        'geometry': {
          'type': 'Polygon',
          // GeoJSON is [lon, lat].
          'coordinates': [
            [
              [9.17, 49.78],
              [9.17, 49.82],
              [9.22, 49.82],
              [9.22, 49.78],
              [9.17, 49.78],
            ],
          ],
        },
      },
    ],
  };
  return Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(fc))));
}

Uint8List _gzTotals(Map<String, double> totals) =>
    Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(totals))));

WayCandidate _fixtureWay({int wayId = 100001}) => WayCandidate(
      wayId: wayId,
      highwayClass: 'residential',
      geometry: const [
        LatLng(49.799, 9.190),
        LatLng(49.800, 9.190),
        LatLng(49.801, 9.190),
      ],
    );

void main() {
  group('CoverageComputeIsolate', () {
    test('round-trip: attributes a driven way to its region (totals null)',
        () async {
      final iso = CoverageComputeIsolate(
        loadAdminBytes: () async => _gzAdminBundle(),
        loadTotalsBytes: () async => null,
      );
      addTearDown(iso.dispose);
      await iso.start();

      final way = _fixtureWay();
      final accum = await iso.computeAttribution(
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
        intervalsByWayId: {way.wayId: [0, 100]},
      );

      final acc = accum['151999'];
      expect(acc, isNotNull);
      expect(acc!.total, greaterThan(0));
      expect(acc.driven, greaterThan(0));
      expect(acc.realTotal, isNull, reason: 'totals bytes were null');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('round-trip: realTotal resolved from shipped totals bytes', () async {
      final iso = CoverageComputeIsolate(
        loadAdminBytes: () async => _gzAdminBundle(),
        loadTotalsBytes: () async => _gzTotals({'151999': 5000}),
      );
      addTearDown(iso.dispose);
      await iso.start();

      final way = _fixtureWay();
      final accum = await iso.computeAttribution(
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
        intervalsByWayId: {way.wayId: [0, 100]},
      );
      expect(accum['151999']!.realTotal, 5000);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('two concurrent jobs resolve with correctly-keyed results', () async {
      final iso = CoverageComputeIsolate(
        loadAdminBytes: () async => _gzAdminBundle(),
        loadTotalsBytes: () async => null,
      );
      addTearDown(iso.dispose);
      await iso.start();

      final wayA = _fixtureWay(wayId: 1);
      final wayB = _fixtureWay(wayId: 2);
      final fa = iso.computeAttribution(
        gzippedTiles: [_gzTile([wayA])],
        tileBboxes: const [_bbox],
        intervalsByWayId: {1: [0, 100]},
      );
      final fb = iso.computeAttribution(
        gzippedTiles: [_gzTile([wayB])],
        tileBboxes: const [_bbox],
        intervalsByWayId: {2: [0, 100]},
      );
      final results = await Future.wait([fa, fb]);
      // Both attribute to the same region (same geometry) — both non-empty.
      expect(results[0]['151999'], isNotNull);
      expect(results[1]['151999'], isNotNull);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('start then dispose without hanging (no jobs)', () async {
      final iso = CoverageComputeIsolate(
        loadAdminBytes: () async => _gzAdminBundle(),
        loadTotalsBytes: () async => null,
      );
      await iso.start();
      iso.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
