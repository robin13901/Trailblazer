// Phase 5 (Plan 05-03): WaySegment — one edge between two consecutive
// nodes of a WayCandidate's geometry. The R-Tree indexes SEGMENTS, not
// whole ways, because a way can be hundreds of meters long and its
// bbox would produce false-positive hits far from any actual road
// point.

import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:meta/meta.dart';

/// One directed edge of a [WayCandidate]'s geometry: from
/// `geometry[segIdx]` to `geometry[segIdx + 1]`.
///
/// Structural equality is defined by ([wayId], [segIdx]) only — two
/// segments with the same (way, index) slot are considered equal even
/// if their coordinates differ (e.g. after upstream re-densification).
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
    this.aNodeId = 0,
    this.bNodeId = 0,
  });

  /// OSM way id.
  final int wayId;

  /// Zero-based index of this segment inside its parent way's geometry:
  /// segment N connects `geometry[N]` → `geometry[N+1]`.
  final int segIdx;

  /// Latitude of the start node (degrees WGS84).
  final double aLat;

  /// Longitude of the start node (degrees WGS84).
  final double aLon;

  /// Latitude of the end node (degrees WGS84).
  final double bLat;

  /// Longitude of the end node (degrees WGS84).
  final double bLon;

  /// OSM `highway=` tag value (guaranteed member of [kfzHighwayClasses]).
  final String highwayClass;

  /// Normalized `oneway=` direction for this way.
  final OnewayDirection oneway;

  /// OSM node id of the start node (`geometry[segIdx]`), or a coordinate-hash
  /// surrogate when the source supplied no node ids (see [nodeKeyFor]). Two
  /// segments meet at a junction iff they share a node id — this is what the
  /// route-distance graph keys on, replacing coordinate-proximity matching.
  final int aNodeId;

  /// OSM node id of the end node (`geometry[segIdx + 1]`); see [aNodeId].
  final int bNodeId;

  // ---------------------------------------------------------------------------
  // Axis-aligned bounding box helpers (used by the R-Tree and by tests).
  // ---------------------------------------------------------------------------

  /// Minimum latitude of the segment's bbox.
  double get minLat => aLat < bLat ? aLat : bLat;

  /// Maximum latitude of the segment's bbox.
  double get maxLat => aLat > bLat ? aLat : bLat;

  /// Minimum longitude of the segment's bbox.
  double get minLon => aLon < bLon ? aLon : bLon;

  /// Maximum longitude of the segment's bbox.
  double get maxLon => aLon > bLon ? aLon : bLon;

  // ---------------------------------------------------------------------------
  // Factory
  // ---------------------------------------------------------------------------

  /// Explode a [WayCandidate] into its ordered segments. Ways with fewer
  /// than 2 geometry points yield an empty list (no throw).
  ///
  /// Node ids come from [WayCandidate.nodeIds] when present (exact topology);
  /// otherwise each vertex gets a deterministic coordinate-hash surrogate via
  /// [nodeKeyFor], so segments that share a vertex still share a node key even
  /// without OSM ids (hand-authored fixtures).
  static List<WaySegment> fromWay(WayCandidate way) {
    final geom = way.geometry;
    if (geom.length < 2) return const [];
    final ids = way.nodeIds;
    final hasIds = ids.length == geom.length;
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
          aNodeId: hasIds ? ids[i] : nodeKeyFor(a.latitude, a.longitude),
          bNodeId: hasIds ? ids[i + 1] : nodeKeyFor(b.latitude, b.longitude),
        ),
      );
    }
    return out;
  }

  /// Deterministic surrogate node key from a coordinate, used when the source
  /// supplied no OSM node ids. Quantizes lat/lon to ~1e-6° (~0.1 m) so two
  /// vertices at the same location hash equal, then packs into a single int.
  /// Negative to avoid colliding with real (positive) OSM node ids.
  static int nodeKeyFor(double lat, double lon) {
    final qLat = (lat * 1e6).round();
    final qLon = (lon * 1e6).round();
    return -(qLat * 1000000007 + qLon).abs() - 1;
  }

  // ---------------------------------------------------------------------------
  // Equality, hashCode, toString
  // ---------------------------------------------------------------------------

  /// Structural equality by (wayId, segIdx).
  @override
  bool operator ==(Object other) =>
      other is WaySegment &&
      other.wayId == wayId &&
      other.segIdx == segIdx;

  @override
  int get hashCode => Object.hash(wayId, segIdx);

  @override
  String toString() =>
      'WaySegment(way=$wayId, seg=$segIdx, class=$highwayClass)';
}
