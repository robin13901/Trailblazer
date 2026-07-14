// Phase 5 (Plan 05-04): MatchedStep — one Viterbi decision per GPS fix.
// Collapsed into DrivenWayInterval rows by the HmmMatcher orchestrator
// (Plan 05-05).
//
// The `direction` field ('forward' | 'backward') is determined by the sign
// of the projection-fraction delta against the prior step on the same wayId.
// The 'both' case is a Phase 6 concern (bidirectional matching); the decoder
// always emits a definite direction.

import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:meta/meta.dart';

/// Per-fix result of the Viterbi HMM decoder.
///
/// One [MatchedStep] is produced for each GPS fix that the decoder was
/// able to match with sufficient confidence. Fixes that fall below the
/// confidence threshold yield `null` in the `ViterbiDecoder.decode` output.
///
/// The matcher orchestrator (Plan 05-05) collapses consecutive
/// [MatchedStep] values with the same [wayId] into a single
/// `DrivenWayInterval` row for the DAO.
@immutable
class MatchedStep {
  const MatchedStep({
    required this.wayId,
    required this.segIdx,
    required this.projectionFraction,
    required this.perpDistMeters,
    required this.emissionLogP,
    required this.direction,
    required this.highwayClass,
    required this.oneway,
    required this.snappedLat,
    required this.snappedLon,
  });

  /// OSM way id of the matched segment.
  final int wayId;

  /// Zero-based index of the matched segment within the way's geometry.
  final int segIdx;

  /// Fraction along the segment (0..1) where the GPS fix projects.
  /// 0.0 = at segment start node; 1.0 = at segment end node.
  final double projectionFraction;

  /// Perpendicular distance in meters from the GPS fix to the matched
  /// segment.
  final double perpDistMeters;

  /// Emission log-probability at this match (log-space; negative).
  final double emissionLogP;

  /// Direction of travel on the way: `'forward'` = along stored node order;
  /// `'backward'` = against stored node order.
  ///
  /// Determined by the sign of the projection-fraction delta against the
  /// prior step on the same [wayId]; defaults to `'forward'` on the first
  /// fix of a sub-track.
  final String direction;

  /// OSM `highway=` class of the matched way.
  final String highwayClass;

  /// Normalized `oneway=` tag of the matched way.
  final OnewayDirection oneway;

  /// The GPS fix's snapped position ON the matched road segment: the point on
  /// segment [segIdx] at [projectionFraction] between its two nodes. This is
  /// what the road-snapped coverage line draws for an on-road fix (2026-07-14
  /// coverage rework) — the line hugs the road rather than the noisy raw GPS.
  final double snappedLat;
  final double snappedLon;

  @override
  String toString() =>
      'MatchedStep(way=$wayId, seg=$segIdx, '
      'frac=${projectionFraction.toStringAsFixed(3)}, '
      'perp=${perpDistMeters.toStringAsFixed(1)}m, dir=$direction, '
      'snap=($snappedLat,$snappedLon))';
}
