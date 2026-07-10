// Trailblazer Phase 7, Plan 07-03:
// Immutable value types for the coverage overlay pipeline (REN-01, REN-03).
//
// CoverageWay pairs a resolved OSM way (geometry) with its CoverageDatum
// (fraction + isFull). CoverageOverlayData is the flat collection passed
// from DrivenWayGeometryResolver to the 07-04 render bridge.
//
// LatLng is from maplibre_gl — consistent with WayCandidate.geometry and
// the existing TripDetailScreen overlay geometry types.

import 'package:auto_explore/features/coverage/domain/coverage_datum.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:meta/meta.dart';

/// Immutable pairing of an OSM way's resolved geometry with its per-way
/// coverage classification.
///
/// Produced by `DrivenWayGeometryResolver.resolve` and consumed by the
/// 07-04 GeoJSON render bridge to paint covered roads on the map.
@immutable
class CoverageWay {
  const CoverageWay({
    required this.wayId,
    required this.geometry,
    required this.datum,
  });

  /// OSM way ID — stable across sessions, matches the driven_way_intervals
  /// `way_id` column.
  final int wayId;

  /// Ordered polyline from the Overpass cache (WayCandidate.geometry).
  /// Two or more points guaranteed by WayCandidate invariant.
  final List<LatLng> geometry;

  /// Coverage classification for this way (fraction in [0,1] + isFull flag).
  final CoverageDatum datum;

  @override
  bool operator ==(Object other) =>
      other is CoverageWay &&
      other.wayId == wayId &&
      other.datum == datum;

  @override
  int get hashCode => Object.hash(wayId, datum);

  @override
  String toString() =>
      'CoverageWay(wayId: $wayId, points: ${geometry.length}, datum: $datum)';
}

/// Flat collection of resolved [CoverageWay]s ready for GeoJSON rendering.
///
/// `empty` is returned by `DrivenWayGeometryResolver` when there are no
/// driven intervals or when an unexpected error forces graceful degradation
/// (per the 06-05 on-device crash lesson: rendering must never crash the map).
@immutable
class CoverageOverlayData {
  const CoverageOverlayData(this.ways);

  /// All resolved ways with above-floor coverage. May be empty.
  final List<CoverageWay> ways;

  /// Canonical empty instance — returned on cache-miss/offline or on error.
  static const empty = CoverageOverlayData(<CoverageWay>[]);

  @override
  bool operator ==(Object other) =>
      other is CoverageOverlayData && other.ways == ways;

  @override
  int get hashCode => ways.hashCode;

  @override
  String toString() => 'CoverageOverlayData(${ways.length} ways)';
}
