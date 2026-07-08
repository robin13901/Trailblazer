// Phase 5 (Plan 05-05): DrivenWayIntervalDraft — the matcher's output row,
// before tripId is attached at the DB boundary. Kept Drift-free so the
// matcher can run on the matcher isolate (Plan 05-06) without a Drift
// handle crossing the isolate boundary.

import 'package:meta/meta.dart';

/// Tripless draft of a `driven_way_intervals` DAO row.
///
/// Produced by `HmmMatcher.match` and passed to the coordinator (Plan 05-07),
/// which supplies a `tripId` before calling
/// `DrivenWayIntervalsDao.insertBatch`.
///
/// No Drift import allowed — this class must remain isolate-safe.
@immutable
class DrivenWayIntervalDraft {
  const DrivenWayIntervalDraft({
    required this.wayId,
    required this.startMeters,
    required this.endMeters,
    required this.direction,
  });

  /// OSM way id that was driven.
  final int wayId;

  /// Distance along the way from its first node to the first matched fix
  /// in this interval. Always >= 0 and <= [endMeters].
  final double startMeters;

  /// Distance along the way from its first node to the last matched fix
  /// in this interval. Always >= [startMeters].
  final double endMeters;

  /// Direction of travel: `'forward'` (along stored node order) or
  /// `'backward'` (against stored node order).
  ///
  /// Derived at flush time: `end_meters >= start_meters → 'forward'`;
  /// `end_meters < start_meters (before swap) → 'backward'`. The stored
  /// [startMeters]/[endMeters] pair always satisfies `start <= end`.
  final String direction;

  @override
  String toString() =>
      'DrivenWayIntervalDraft(way=$wayId, '
      '${startMeters.toStringAsFixed(1)}..'
      '${endMeters.toStringAsFixed(1)}m, dir=$direction)';
}
