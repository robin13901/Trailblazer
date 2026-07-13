// Trailblazer Phase 6, Plan 06-02 Task 2:
// TripListItem — read-model DTO for the inbox / history card lists.
//
// Populated by `TripsInboxDao` custom queries. Carries the trip's summary
// stats plus the start/end coordinates (derived from the first/last
// `trip_points` row by `seq`) and the count of `driven_way_intervals`
// matched to the trip (Q10 — the UI chips "No roads matched" when zero).

import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:meta/meta.dart';

/// Immutable read-model for one row in the inbox or history list.
///
/// Field nullability mirrors the trips schema: `endedAt`, `distanceMeters`,
/// `durationSeconds` and the four bbox corners are nullable; the derived
/// start/end coordinates are null for zero-point trips.
@immutable
class TripListItem {
  const TripListItem({
    required this.id,
    required this.status,
    required this.startedAt,
    required this.endedAt,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
    required this.intervalCount,
    this.bboxMinLat,
    this.bboxMinLon,
    this.bboxMaxLat,
    this.bboxMaxLon,
  });

  final int id;
  final TripStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double? distanceMeters;
  final int? durationSeconds;

  /// Derived from the first/last `trip_points` row by `seq`. Null for
  /// zero-point trips.
  final double? startLat;
  final double? startLon;
  final double? endLat;
  final double? endLon;

  /// Count of `driven_way_intervals` rows for this trip (Q10).
  final int intervalCount;

  final double? bboxMinLat;
  final double? bboxMinLon;
  final double? bboxMaxLat;
  final double? bboxMaxLon;

  /// A matched trip with zero intervals — the matcher ran but found no
  /// road coverage. The card UI chips "No roads matched".
  bool get isFailMatched =>
      status == TripStatus.matched && intervalCount == 0;

  /// In-flight = still awaiting or running the matcher pipeline.
  bool get isInFlight =>
      status == TripStatus.pending || status == TripStatus.pendingRoadData;

  Duration? get duration =>
      durationSeconds == null ? null : Duration(seconds: durationSeconds!);
}
