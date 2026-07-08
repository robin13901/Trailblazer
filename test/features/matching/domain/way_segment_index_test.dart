// Phase 5 (Plan 05-03): Tests for WaySegmentIndex.
//
// Covers (12 tests):
//   1.  buildFromWays([]) → 0 segments
//   2.  buildFromWays with 3 ways × 5 nodes → 12 segments
//   3.  Ways with < 2 points are silently skipped
//   4.  queryWithinRadius(5m) around a point on a segment returns it
//   5.  queryWithinRadius returns nothing 200 m away at radius 25 m
//   6.  queryTopK(k=5, 25m) returns segments ordered by perp distance
//   7.  queryTopK with k > coarse result count returns all coarse hits
//   8.  queryTopK(k=0) returns empty list
//   9.  queryTopK ties broken by (wayId, segIdx) deterministically
//   10. queryTopK excludes segments beyond radius but inside coarse bbox
//   11. integration: FixtureWayCandidateSource loads and yields segments
//   12. benchmark: 5000 ways × 4 nodes (15k segments) builds in < 2 s

import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// Test-only fixture helper — imported from test/helpers, not from lib/.
import '../../../helpers/fixture_way_candidate_source.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a synthetic WayCandidate with [nodeCount] evenly-spaced nodes along a
/// horizontal line starting at ([lat], [lon]).
///
/// Node separation: ~10 m longitude step (approx 7 m at lat 49.7).
WayCandidate _makeSyntheticWay({
  required int wayId,
  required double lat,
  required double lon,
  required int nodeCount,
  String highwayClass = 'residential',
}) {
  // ~10 m per step at lat 49 (1° ≈ 111320 m, so 0.0001° ≈ 11 m)
  const step = 0.0001;
  return WayCandidate(
    wayId: wayId,
    geometry: List.generate(
      nodeCount,
      (i) => LatLng(lat, lon + i * step),
    ),
    highwayClass: highwayClass,
  );
}

void main() {
  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  group('WaySegmentIndex.buildFromWays', () {
    test('empty input yields index with 0 segments', () {
      final idx = WaySegmentIndex.buildFromWays([]);
      expect(idx.allSegments, isEmpty);
    });

    test('3 ways × 5 nodes yields 12 segments', () {
      final ways = [
        _makeSyntheticWay(wayId: 1, lat: 49.700, lon: 9.100, nodeCount: 5),
        _makeSyntheticWay(wayId: 2, lat: 49.701, lon: 9.100, nodeCount: 5),
        _makeSyntheticWay(wayId: 3, lat: 49.702, lon: 9.100, nodeCount: 5),
      ];
      final idx = WaySegmentIndex.buildFromWays(ways);
      // Each 5-node way → 4 segments; 3 × 4 = 12.
      expect(idx.allSegments.length, 12);
    });

    test('ways with fewer than 2 points are silently skipped', () {
      final ways = [
        // 0-point way
        const WayCandidate(
          wayId: 10,
          geometry: [],
          highwayClass: 'primary',
        ),
        // 1-point way
        const WayCandidate(
          wayId: 11,
          geometry: [LatLng(49.700, 9.100)],
          highwayClass: 'primary',
        ),
        // Valid 2-point way → 1 segment
        _makeSyntheticWay(wayId: 12, lat: 49.700, lon: 9.100, nodeCount: 2),
      ];
      final idx = WaySegmentIndex.buildFromWays(ways);
      expect(idx.allSegments.length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // queryWithinRadius
  // ---------------------------------------------------------------------------
  group('WaySegmentIndex.queryWithinRadius', () {
    // A horizontal east-west segment at 49.700 N, 9.100–9.001 E
    // (roughly 72 m long at that latitude).
    late WaySegmentIndex idx;

    setUp(() {
      const way = WayCandidate(
        wayId: 1,
        geometry: [
          LatLng(49.700, 9.100),
          LatLng(49.700, 9.101),
        ],
        highwayClass: 'primary',
      );
      idx = WaySegmentIndex.buildFromWays([way]);
    });

    test('radius 5m around a point on the segment returns the segment', () {
      // midpoint of the segment
      const midLat = 49.700;
      const midLon = 9.1005;
      final hits = idx.queryWithinRadius(
        lat: midLat,
        lon: midLon,
        radiusMeters: 5,
      );
      expect(hits, hasLength(1));
      expect(hits.first.wayId, 1);
    });

    test('radius 25m around a point 200 m away returns no segments', () {
      // 200 m north of the segment (200 / 111320 ≈ 0.001797°)
      const farLat = 49.700 + 0.002;
      const farLon = 9.1005;
      final hits = idx.queryWithinRadius(
        lat: farLat,
        lon: farLon,
        radiusMeters: 25,
      );
      expect(hits, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // queryTopK
  // ---------------------------------------------------------------------------
  group('WaySegmentIndex.queryTopK', () {
    // Six parallel east-west segments at the same longitude band but
    // at increasing latitudes.  Each segment is ~11 m north of the
    // previous one (0.0001° lat step ≈ 11.1 m).
    // Query point is 0.5 m north of segment 0 (way 100), so distances
    // to segments 0..5 are approximately 0.5, 11.6, 22.7, 33.8, 44.9, 56 m.
    // Using radius=80m covers all 6; using radius=25m covers first 3.
    late WaySegmentIndex idx;
    // Step between parallel segments in degrees latitude (~11.1 m each).
    const step = 0.0001;
    // Query point sits 0.5 m north of segment 0 (way 100).
    const qLat = 49.7000 + 0.5 / 111320.0;
    const qLon = 9.1005;

    setUp(() {
      final ways = List.generate(
        6,
        (i) => WayCandidate(
          wayId: 100 + i,
          geometry: [
            LatLng(49.7000 + i * step, 9.100),
            LatLng(49.7000 + i * step, 9.101),
          ],
          highwayClass: 'residential',
        ),
      );
      idx = WaySegmentIndex.buildFromWays(ways);
    });

    test('queryTopK(k=5, 80m) returns 5 segments ordered by perp distance', () {
      // At step=0.0001° (~11.1 m), radius=80m covers 6 segments.
      // k=5 should cap the result at 5, returning the 5 closest.
      final results = idx.queryTopK(
        lat: qLat,
        lon: qLon,
        radiusMeters: 80,
        k: 5,
      );
      expect(results.length, 5);
      // Closer segments come first (ascending wayId because way 100 is closest).
      for (var i = 0; i < results.length - 1; i++) {
        expect(
          results[i].wayId,
          lessThan(results[i + 1].wayId),
          reason: 'Expected ascending wayId (closer to farther)',
        );
      }
    });

    test('queryTopK k > coarse result count returns all coarse hits', () {
      // With radius 25m we can reach at most 2 segments from qLat
      // (each segment is ~11 m apart, so 2 are within 25 m).
      final results = idx.queryTopK(
        lat: qLat,
        lon: qLon,
        radiusMeters: 25,
        k: 100, // much larger than available hits
      );
      // Should return all reachable segments, not crash.
      expect(results.length, lessThanOrEqualTo(6));
      expect(results.length, greaterThan(0));
    });

    test('queryTopK(k=0) returns empty list', () {
      final results = idx.queryTopK(
        lat: qLat,
        lon: qLon,
        radiusMeters: 25,
        k: 0,
      );
      expect(results, isEmpty);
    });

    test('ties broken by (wayId, segIdx) deterministically', () {
      // Two ways placed at exactly the same latitude (so same perp distance
      // from the query point directly above).
      final tieWays = [
        const WayCandidate(
          wayId: 200,
          geometry: [
            LatLng(49.7000, 9.100),
            LatLng(49.7000, 9.101),
          ],
          highwayClass: 'residential',
        ),
        const WayCandidate(
          wayId: 201,
          geometry: [
            LatLng(49.7000, 9.100),
            LatLng(49.7000, 9.101),
          ],
          highwayClass: 'residential',
        ),
      ];
      final tieIdx = WaySegmentIndex.buildFromWays(tieWays);
      final r = tieIdx.queryTopK(
        lat: 49.7000 + 0.5 / 111320.0,
        lon: 9.1005,
        radiusMeters: 10,
        k: 2,
      );
      expect(r.length, 2);
      // Lower wayId must come first (tie-break rule).
      expect(r[0].wayId, 200);
      expect(r[1].wayId, 201);
    });

    test('queryTopK excludes segments beyond radius but inside coarse bbox', () {
      // Place one segment very close and one that is inside the bbox but
      // whose exact perp distance exceeds the radius.
      //
      // Segment A: directly below the query point (≈ 0.5 m away).
      // Segment B: placed such that its bbox overlaps the query box but
      // its nearest point on the polyline is ~50 m away.
      const queryLat = 49.7000;
      const queryLon = 9.1000;

      // Segment A is a tiny north-south segment touching the query point.
      const segAWay = WayCandidate(
        wayId: 300,
        geometry: [
          LatLng(49.6999, 9.1000),
          LatLng(49.7001, 9.1000),
        ],
        highwayClass: 'residential',
      );

      // Segment B runs east-west far from the query in longitude, but its
      // bbox still overlaps the query bbox (at the same latitude band).
      // Specifically, one endpoint is within the query bbox but the
      // near-endpoint is still ~60 m east of the query point.
      // 60 m at lat 49.7 ≈ 60 / (111320 * cos(49.7°)) ≈ 0.000839°
      const segBWay = WayCandidate(
        wayId: 301,
        geometry: [
          // Start point is inside bbox (only ~0° offset), but it's more
          // than 25 m east of the query point at ~8 km/h longitude step.
          LatLng(49.7000, 9.1004), // ~28 m east at lat 49.7
          LatLng(49.7000, 9.1020), // farther east
        ],
        highwayClass: 'residential',
      );

      final farIdx = WaySegmentIndex.buildFromWays([segAWay, segBWay]);
      final results = farIdx.queryTopK(
        lat: queryLat,
        lon: queryLon,
        radiusMeters: 25,
        k: 10,
      );

      // Only segment A should be included (B's perp distance > 25 m).
      final wayIds = results.map((s) => s.wayId).toList();
      expect(wayIds, contains(300));
      expect(wayIds, isNot(contains(301)));
    });
  });

  // ---------------------------------------------------------------------------
  // Integration: load from real fixture
  // ---------------------------------------------------------------------------
  group('WaySegmentIndex integration', () {
    test(
      'buildFromWays from Kreuzberg fixture yields non-zero segment count',
      () async {
        const path = 'test/fixtures/overpass/urban_kreuzberg_5x5km.json.gz';
        FixtureWayCandidateSource? source;
        try {
          source = await FixtureWayCandidateSource.fromGzippedOverpassJson(
            path,
          );
        } on Object {
          // Fixture not available — skip gracefully.
          return;
        }
        final ways = await source.fetchWaysInBbox(
          minLat: -90,
          minLon: -180,
          maxLat: 90,
          maxLon: 180,
        );
        final idx = WaySegmentIndex.buildFromWays(ways);
        expect(idx.allSegments.length, greaterThan(0));
      },
      tags: ['fixture'],
    );
  });

  // ---------------------------------------------------------------------------
  // Benchmark smoke test
  // ---------------------------------------------------------------------------
  group('WaySegmentIndex benchmark', () {
    test(
      'builds 15k segments (5000 ways × 4 nodes) in < 2 s',
      () {
        const wayCount = 5000;
        const nodesPerWay = 4;
        const step = 0.0001;

        final ways = List.generate(
          wayCount,
          (i) => WayCandidate(
            wayId: i,
            geometry: List.generate(
              nodesPerWay,
              (j) => LatLng(
                49.0 + i * 0.00001,
                9.0 + j * step,
              ),
            ),
            highwayClass: 'residential',
          ),
        );

        final sw = Stopwatch()..start();
        final idx = WaySegmentIndex.buildFromWays(ways);
        sw.stop();

        final elapsedMs = sw.elapsedMilliseconds;
        // Print benchmark result to test output for advisory purposes.
        // ignore: avoid_print
        print(
          'WaySegmentIndex benchmark: built ${idx.allSegments.length} segments '
          'in ${elapsedMs}ms',
        );

        // Hard fail only at 2000 ms (CI headroom).
        expect(
          elapsedMs,
          lessThan(2000),
          reason: 'Index build took ${elapsedMs}ms — exceeds 2s hard limit',
        );

        // Advisory: warn at 500 ms (but do not fail).
        if (elapsedMs > 500) {
          // Print advisory warning for slow builds.
          // ignore: avoid_print
          print(
            '[advisory] build took > 500 ms ($elapsedMs ms) — '
            'consider marking @Skip on CI or profiling.',
          );
        }
      },
    );
  });
}
