// CoverageComputeIsolate round-trip tests (2026-07-22; reworked 2026-07-25).
// Mirrors matcher_isolate_test.dart: spawns the real isolate, ships in-memory
// bundle bytes, runs a STAGE-1 clip job, asserts the returned attribution rows.
// Timeout 30s to fail fast on hangs; dispose in tearDown.

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
    test('round-trip: clips a way to its region → one attribution row',
        () async {
      final iso = CoverageComputeIsolate(
        loadAdminBytes: () async => _gzAdminBundle(),
        loadTotalsBytes: () async => null,
      );
      addTearDown(iso.dispose);
      await iso.start();

      final way = _fixtureWay();
      final rows = await iso.computeAttribution(
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
      );

      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.wayId, way.wayId);
      expect(r.regionId, '151999');
      expect(r.adminLevel, 8);
      expect(r.rangeEndM, greaterThan(r.rangeStartM));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('round-trip: already-attributed wayIds are skipped', () async {
      final iso = CoverageComputeIsolate(
        loadAdminBytes: () async => _gzAdminBundle(),
        loadTotalsBytes: () async => null,
      );
      addTearDown(iso.dispose);
      await iso.start();

      final way = _fixtureWay();
      final rows = await iso.computeAttribution(
        gzippedTiles: [_gzTile([way])],
        tileBboxes: const [_bbox],
        alreadyAttributedWayIds: {way.wayId},
      );
      expect(rows, isEmpty);
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
      );
      final fb = iso.computeAttribution(
        gzippedTiles: [_gzTile([wayB])],
        tileBboxes: const [_bbox],
      );
      final results = await Future.wait([fa, fb]);
      expect(results[0].single.wayId, 1);
      expect(results[1].single.wayId, 2);
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
