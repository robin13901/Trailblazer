---
id: 05-03
phase: 05-overpass-matcher-and-golden-corpus
plan: 03
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/features/matching/domain/way_segment.dart
  - lib/features/matching/domain/way_segment_index.dart
  - pubspec.yaml
  - test/features/matching/domain/way_segment_test.dart
  - test/features/matching/domain/way_segment_index_test.dart
autonomous: true
requirements: [MMT-04]

must_haves:
  truths:
    - "`WaySegment` value type represents one edge of a `WayCandidate` polyline (wayId, segIdx, aLat, aLon, bLat, bLon, highwayClass, oneway, forward/backward derived flags) with structural equality by (wayId, segIdx)."
    - "`WaySegmentIndex.buildFromWays(List<WayCandidate>)` returns an index containing every consecutive-node pair across all input ways; empty and single-point ways produce no segments (do not throw)."
    - "`WaySegmentIndex.queryWithinRadius(lat, lon, radiusMeters)` returns a list of segments whose axis-aligned bbox overlaps the query bbox derived from the radius — computed with `metersPerDegreeLon(lat)` scaling so radius-in-meters is honored on the correct axis."
    - "`WaySegmentIndex.queryTopK(lat, lon, radiusMeters, k)` returns at most `k` segments ranked by perpendicular distance from (lat, lon) to the segment (using `perpDistanceToSegmentMeters` from 05-02); ties broken by wayId then segIdx for determinism."
    - "Segments from ways with fewer than 2 points are silently skipped."
    - "Bulk `load()` via rbush is used (not per-item insert) so index build for 15k segments takes < 200 ms on the test box; a benchmark test guards this."
  artifacts:
    - path: "lib/features/matching/domain/way_segment.dart"
      provides: "WaySegment value type + fromWayCandidate factory returning List<WaySegment>."
      min_lines: 60
    - path: "lib/features/matching/domain/way_segment_index.dart"
      provides: "WaySegmentIndex wrapping rbush RBushBase<WaySegment>; build/query top-K/query-within-radius."
      min_lines: 100
    - path: "test/features/matching/domain/way_segment_test.dart"
      provides: "Segment decomposition tests + equality/hashCode."
      min_lines: 60
    - path: "test/features/matching/domain/way_segment_index_test.dart"
      provides: "Index build + query tests with fixture ways (from test/helpers/fixture_way_candidate_source.dart)."
      min_lines: 120
  key_links:
    - from: "lib/features/matching/domain/way_segment_index.dart"
      to: "package:rbush/rbush.dart"
      via: "extend RBushBase<WaySegment>; call load() with the segment list bulk-built from way geometries"
      pattern: "RBushBase|rbush"
    - from: "lib/features/matching/domain/way_segment_index.dart"
      to: "lib/features/matching/domain/segment_geometry.dart"
      via: "reuse perpDistanceToSegmentMeters + metersPerDegreeLon for the radius-to-degrees conversion and the exact top-K ranking"
      pattern: "perpDistanceToSegment|metersPerDegreeLon"
---

## Goal

Ship the in-memory R-Tree the matcher isolate will build per trip: a `WaySegment` value type and a `WaySegmentIndex` (backed by `rbush`) with two query modes — `queryWithinRadius` (raw R-Tree hits, used for candidate pruning) and `queryTopK` (radius filter + exact perpendicular-distance ranking, used by the Viterbi decoder).

Resolves research §11 open question #7 — `rbush` version. Verify `dart pub add rbush` resolves and pin whatever version comes back (research documented ^1.1.1; if a newer version is on pub.dev, use it).

## Context

- Research §3 has the full library rationale, `RBushBase<WaySegment>` shape, and the Pythagorean-vs-Haversine caveat: rbush's `knn` uses coordinate-plane Euclidean distance, so we do a coarse radius filter with rbush and then re-rank with exact perpendicular distance from 05-02.
- `WayCandidate` (`lib/features/matching/domain/way_candidate.dart`) is the input. `geometry` is a `List<LatLng>` from `maplibre_gl`. Two consecutive entries form one segment. Ways with fewer than 2 points are dropped upstream by the Overpass parser but be defensive.
- Existing fixture helper: `test/helpers/fixture_way_candidate_source.dart` — `FixtureWayCandidateSource.fromGzippedOverpassJson(path)`. Fixture files exist at `test/fixtures/overpass/*.json.gz` (Phase 4 committed a Kreuzberg + Grebenhain fixture). Use them for the index-build integration tests.
- New dependency: `rbush` — verify with `dart pub add rbush` (research §11.7 flag). Alphabetize in `pubspec.yaml` per `sort_pub_dependencies`.
- The tight loop is `flutter analyze`; the index build performance test is a smoke test, not a strict SLA — mark it `@Skip` if it flakes on CI but keep it locally as a guardrail.
- No isolate work here — pure Dart, testable via `dart test` or `flutter test`.

## Tasks

<task type="auto">
  <name>Task 1: WaySegment value type + WayCandidate → segments factory</name>
  <files>
    lib/features/matching/domain/way_segment.dart
    test/features/matching/domain/way_segment_test.dart
  </files>
  <intent>Immutable segment value type; factory that flattens a WayCandidate to its segments.</intent>
  <action>
    **`lib/features/matching/domain/way_segment.dart`:**
    ```dart
    // Phase 5 (Plan 05-03): WaySegment — one edge between two consecutive
    // nodes of a WayCandidate's geometry. The R-Tree indexes SEGMENTS, not
    // whole ways, because a way can be hundreds of meters long and its
    // bbox would produce false-positive hits far from any actual road
    // point.

    import 'package:auto_explore/features/matching/domain/way_candidate.dart';
    import 'package:meta/meta.dart';

    @immutable
    class WaySegment {
      const WaySegment({
        required this.wayId,
        required this.segIdx,
        required this.aLat,
        required this.aLon,
        required this.bLat,
        required this.bLon,
        required this.highwayClass,
        required this.oneway,
      });

      /// OSM way id.
      final int wayId;

      /// Zero-based index of this segment inside its parent way's geometry:
      /// segment N connects `geometry[N]` → `geometry[N+1]`.
      final int segIdx;

      final double aLat;
      final double aLon;
      final double bLat;
      final double bLon;

      final String highwayClass;
      final OnewayDirection oneway;

      double get minLat => aLat < bLat ? aLat : bLat;
      double get maxLat => aLat > bLat ? aLat : bLat;
      double get minLon => aLon < bLon ? aLon : bLon;
      double get maxLon => aLon > bLon ? aLon : bLon;

      /// Explode a whole way into its ordered segments. Empty and single-point
      /// ways yield an empty list (no throw).
      static List<WaySegment> fromWay(WayCandidate way) {
        final geom = way.geometry;
        if (geom.length < 2) return const [];
        final out = <WaySegment>[];
        for (var i = 0; i + 1 < geom.length; i++) {
          final a = geom[i];
          final b = geom[i + 1];
          out.add(
            WaySegment(
              wayId: way.wayId,
              segIdx: i,
              aLat: a.latitude,
              aLon: a.longitude,
              bLat: b.latitude,
              bLon: b.longitude,
              highwayClass: way.highwayClass,
              oneway: way.oneway,
            ),
          );
        }
        return out;
      }

      @override
      bool operator ==(Object other) =>
          other is WaySegment && other.wayId == wayId && other.segIdx == segIdx;

      @override
      int get hashCode => Object.hash(wayId, segIdx);

      @override
      String toString() =>
          'WaySegment(way=$wayId, seg=$segIdx, class=$highwayClass)';
    }
    ```

    **Tests (`test/features/matching/domain/way_segment_test.dart`):**
    1. `fromWay on 3-point way returns 2 segments with correct segIdx`.
    2. `fromWay on 1-point way returns empty list`.
    3. `fromWay on 0-point way returns empty list`.
    4. `minLat/maxLat/minLon/maxLon computed correctly for a north-east-oriented segment and for a south-west-oriented segment (both orderings)`.
    5. `equality: two WaySegment with same (wayId, segIdx) are equal even if coords differ`. (Because upstream identity is by wayId; a re-densified geometry with different coords must still hash to the same segment slot.)
    6. `equality: WaySegment with same wayId but different segIdx are NOT equal`.
    7. `hashCode is consistent with equality`.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/domain/way_segment_test.dart
    ```
    Analyze clean; all 7 tests green.
  </verify>
  <done>WaySegment ships with a stable factory + structural equality; all 7 tests green.</done>
</task>

<task type="auto">
  <name>Task 2: Add rbush dep + WaySegmentIndex (build + queryWithinRadius + queryTopK)</name>
  <files>
    pubspec.yaml
    lib/features/matching/domain/way_segment_index.dart
    test/features/matching/domain/way_segment_index_test.dart
  </files>
  <intent>rbush-backed R-Tree over WaySegment, with a top-K query that re-ranks by exact perp distance.</intent>
  <action>
    **`pubspec.yaml`:**
    ```bash
    dart pub add rbush
    ```
    Then inspect the resulting entry — should be `rbush: ^1.1.1` or newer. Manually re-alphabetize `dependencies:` (must stay sorted per `sort_pub_dependencies`) — insert between `permission_handler` and `riverpod_annotation` (r-h before r-b before r-i — verify by re-running `flutter analyze` which enforces the lint).

    **`lib/features/matching/domain/way_segment_index.dart`:**
    ```dart
    // Phase 5 (Plan 05-03): WaySegmentIndex — in-memory R-Tree over the
    // segments of the ways returned by WayCandidateSource for a trip's bbox.
    //
    // Built once per trip on the matcher isolate. Query API:
    //   * queryWithinRadius — raw R-Tree hits by axis-aligned bbox (coarse).
    //   * queryTopK        — radius filter + exact perp-distance ranking.
    //
    // Uses rbush's Pythagorean-in-degrees knn as a coarse filter; the exact
    // perpendicular-distance ranking (via segment_geometry.dart) handles the
    // WGS84 anisotropy the R-Tree can't see. Research §3 has the rationale.

    import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
    import 'package:auto_explore/features/matching/domain/way_candidate.dart';
    import 'package:auto_explore/features/matching/domain/way_segment.dart';
    import 'package:rbush/rbush.dart';

    class WaySegmentIndex {
      WaySegmentIndex._(this._tree, this._segments);

      /// Bulk-build from a list of WayCandidate. Ways are exploded into
      /// segments; segments are bulk-loaded via rbush's STR pack (O(N log N)).
      factory WaySegmentIndex.buildFromWays(List<WayCandidate> ways) {
        final segments = <WaySegment>[];
        for (final w in ways) {
          segments.addAll(WaySegment.fromWay(w));
        }
        final tree = RBushBase<WaySegment>(
          maxEntries: 16,
          toBBox: (s) => RBushBox(
            minX: s.minLon,
            minY: s.minLat,
            maxX: s.maxLon,
            maxY: s.maxLat,
          ),
          getMinX: (s) => s.minLon,
          getMinY: (s) => s.minLat,
        )..load(segments);
        return WaySegmentIndex._(tree, segments);
      }

      final RBushBase<WaySegment> _tree;
      final List<WaySegment> _segments;

      /// All segments the index knows about. Exposed for size checks in tests
      /// and future dev-HUD instrumentation.
      List<WaySegment> get allSegments => List.unmodifiable(_segments);

      /// Coarse: every segment whose axis-aligned bbox intersects the
      /// query box derived from a metric radius centered on (lat, lon).
      List<WaySegment> queryWithinRadius({
        required double lat,
        required double lon,
        required double radiusMeters,
      }) {
        final radiusLat = radiusMeters / metersPerDegreeLat;
        final radiusLon = radiusMeters / metersPerDegreeLon(lat);
        final searchBox = RBushBox(
          minX: lon - radiusLon,
          minY: lat - radiusLat,
          maxX: lon + radiusLon,
          maxY: lat + radiusLat,
        );
        return _tree.search(searchBox);
      }

      /// Top-K segments by exact perpendicular metric distance from
      /// (lat, lon), restricted to segments within [radiusMeters]. Ties are
      /// broken by (wayId, segIdx) for determinism.
      ///
      /// Returns fewer than [k] entries when the radius set is smaller than
      /// [k].
      List<WaySegment> queryTopK({
        required double lat,
        required double lon,
        required double radiusMeters,
        required int k,
      }) {
        if (k <= 0) return const [];
        final coarse = queryWithinRadius(
          lat: lat,
          lon: lon,
          radiusMeters: radiusMeters,
        );
        if (coarse.isEmpty) return const [];

        final scored = <(WaySegment, double)>[];
        for (final s in coarse) {
          final d = perpDistanceToSegmentMeters(
            pLat: lat,
            pLon: lon,
            aLat: s.aLat,
            aLon: s.aLon,
            bLat: s.bLat,
            bLon: s.bLon,
          );
          if (d <= radiusMeters) scored.add((s, d));
        }
        scored.sort((a, b) {
          final c = a.$2.compareTo(b.$2);
          if (c != 0) return c;
          final wc = a.$1.wayId.compareTo(b.$1.wayId);
          if (wc != 0) return wc;
          return a.$1.segIdx.compareTo(b.$1.segIdx);
        });
        return scored.take(k).map((e) => e.$1).toList(growable: false);
      }
    }
    ```

    **Tests (`test/features/matching/domain/way_segment_index_test.dart`):**
    Use a mix of hand-built `WayCandidate` fixtures + one fixture-loaded case.
    1. `buildFromWays([]) yields an index with 0 segments`.
    2. `buildFromWays with 3 ways of 5 nodes each yields 12 segments`.
    3. `ways with < 2 points are silently skipped`.
    4. `queryWithinRadius(radius=5m) around a point exactly on a segment returns that segment`.
    5. `queryWithinRadius returns no segments when the point is 200 m away and radius = 25 m`.
    6. `queryTopK(k=5, radius=25m) returns segments ordered by perp distance`. Seed 6 parallel east-west segments; assert order.
    7. `queryTopK with k > coarse-result size returns all coarse hits (not padded)`.
    8. `queryTopK with k = 0 returns empty list`.
    9. `queryTopK ties broken by (wayId, segIdx) deterministically` — two segments at exactly the same distance; assert ordering.
    10. `queryTopK excludes segments beyond radius even when they're in the coarse bbox` (a segment whose bbox overlaps but whose perp distance > radius).
    11. `integration: buildFromWays(FixtureWayCandidateSource.fromGzippedOverpassJson('test/fixtures/overpass/...'))` runs; assert non-zero segment count. (Skip the fixture load if the file is absent — mark that test `@Tags(['fixture'])` so CI can gate it later.)
    12. `benchmark smoke: buildFromWays with a synthetic 5000-way × 4-node list (= 15k segments) completes in < 500 ms`. Wrap in `Stopwatch`; log the time; only FAIL if it takes > 2 s (leaving CI headroom).
  </action>
  <verify>
    ```bash
    flutter pub get
    flutter analyze
    flutter test test/features/matching/domain/way_segment_index_test.dart
    ```
    Analyze clean; all 12 tests green; benchmark test logs an elapsed time (advisory).
  </verify>
  <done>Index builds from real fixtures + synthetic loads; top-K ranking uses exact perp distance; deterministic ties.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- `rbush` in `pubspec.yaml`, alphabetized; `flutter pub get` succeeds without conflicts.
- All 19 tests across the two files green.
- Grep-verify: `lib/features/matching/domain/way_segment_index.dart` imports rbush; `lib/features/matching/domain/way_segment.dart` does NOT (pure value type).

## Ralph Loop

- Tight loop: `flutter analyze`.
- Behavior-sensitive (all algorithmic): `flutter test test/features/matching/domain/` after each task.
- Behavior-sensitive on Task 2's pubspec change: `flutter pub get` before analyze (already in Task 2 verify).

## Deviations

- If `rbush` resolves to a version > 1.1.1, use it — pin the exact version to whatever `flutter pub get` picks.
- If `rbush` fails to resolve (Dart 3 compat regression), fall back to `r_tree ^3.0.2` (research §3 alt) and rework `WaySegmentIndex` — no `RBushBase`, so use a plain composition + `knn` (which r_tree lacks; would need a manual bbox-scan). This is a MEDIUM-risk fallback; escalate to the user if it triggers.
- Fixture test #11 depends on a Phase 4 committed fixture file. If that file is absent, keep the test in place but mark it `@Skip('fixture required — will pass in 05-08')` — it will be re-enabled when 05-08 lands the golden fixture directory.

## Commit Strategy

- Task 1 commit: `feat(05-03): WaySegment value type + fromWay factory`
- Task 2 commit: `feat(05-03): WaySegmentIndex (rbush) with radius + top-K queries`
