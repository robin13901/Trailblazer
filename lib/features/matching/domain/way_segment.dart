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
