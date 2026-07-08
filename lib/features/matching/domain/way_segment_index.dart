// Phase 5 (Plan 05-03): WaySegmentIndex — in-memory R-Tree over the
// segments of the ways returned by WayCandidateSource for a trip's bbox.
//
// Built once per trip on the matcher isolate. Query API:
//   * queryWithinRadius — raw R-Tree hits by axis-aligned bbox (coarse).
//   * queryTopK        — radius filter + exact perp-distance ranking.
//
// Uses rbush's bulk load (STR pack, O(N log N)) for fast index construction.
// The R-Tree's coordinate-plane Euclidean distance is used as a coarse
// filter; the exact perpendicular-distance ranking (via segment_geometry.dart)
// handles the WGS84 anisotropy the R-Tree can't see. Research §3 has the
// rationale.

import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:rbush/rbush.dart';

/// In-memory R-Tree index over [WaySegment] instances.
///
/// Build via [WaySegmentIndex.buildFromWays]; query via [queryWithinRadius]
/// (coarse R-Tree hits) or [queryTopK] (radius filter + exact perp-distance
/// ranking).
class WaySegmentIndex {
  WaySegmentIndex._(this._tree, this._segments);

  // ---------------------------------------------------------------------------
  // Construction
  // ---------------------------------------------------------------------------

  /// Bulk-build from a list of [WayCandidate]. Each way is exploded into
  /// its ordered segments; segments are bulk-loaded via rbush's STR pack
  /// (O(N log N)).
  ///
  /// Ways with fewer than 2 geometry points are silently skipped.
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

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  /// All segments in the index. Exposed for size checks in tests and future
  /// dev-HUD instrumentation.
  List<WaySegment> get allSegments => List.unmodifiable(_segments);

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Coarse query: every segment whose axis-aligned bbox intersects the
  /// query box derived from a metric radius centered on ([lat], [lon]).
  ///
  /// The query box is computed with [metersPerDegreeLon] scaling so the
  /// radius-in-meters is honored on the longitude axis.
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

  /// Top-K query: segments within [radiusMeters] of ([lat], [lon]), ranked
  /// by exact perpendicular metric distance. Ties are broken by
  /// `(wayId, segIdx)` for determinism.
  ///
  /// Returns fewer than [k] entries when the coarse hit set is smaller than
  /// [k]. Returns an empty list when [k] ≤ 0.
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
