// Trailblazer Phase 6, Plan 06-02 Task 2:
// TripsInboxDao — custom Drift queries backing the inbox / history / in-flight
// streams and the Keep status-flip.
//
// Lives alongside `TripsDao` (does NOT modify it — file-ownership hygiene)
// and reuses the same tables via a plain `DatabaseAccessor<AppDatabase>`.
//
// The list queries use `customSelect(...).watch()` because they subquery
// `trip_points` (first/last by seq) and `driven_way_intervals` (count) —
// cleaner as raw SQL than the fluent join API (which would fan out).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/converters/trip_status_converter.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart';

/// Read/flip queries for the Phase-6 inbox and history lists.
class TripsInboxDao extends DatabaseAccessor<AppDatabase> {
  TripsInboxDao(super.attachedDatabase);

  static const TripStatusConverter _statusConverter = TripStatusConverter();

  $TripsTable get _trips => attachedDatabase.trips;
  $TripPointsTable get _points => attachedDatabase.tripPoints;
  $DrivenWayIntervalsTable get _intervals =>
      attachedDatabase.drivenWayIntervals;

  /// Shared SELECT — trip columns + derived start/end coords + interval
  /// count. `:statuses` placeholder is expanded by the caller.
  String _listQuery(String statusPlaceholders) => '''
SELECT
  t.id                AS id,
  t.status            AS status,
  t.started_at        AS started_at,
  t.ended_at          AS ended_at,
  t.distance_meters   AS distance_meters,
  t.duration_seconds  AS duration_seconds,
  t.vehicle_id        AS vehicle_id,
  t.bbox_min_lat      AS bbox_min_lat,
  t.bbox_min_lon      AS bbox_min_lon,
  t.bbox_max_lat      AS bbox_max_lat,
  t.bbox_max_lon      AS bbox_max_lon,
  (SELECT lat FROM trip_points WHERE trip_id = t.id ORDER BY seq ASC  LIMIT 1) AS start_lat,
  (SELECT lon FROM trip_points WHERE trip_id = t.id ORDER BY seq ASC  LIMIT 1) AS start_lon,
  (SELECT lat FROM trip_points WHERE trip_id = t.id ORDER BY seq DESC LIMIT 1) AS end_lat,
  (SELECT lon FROM trip_points WHERE trip_id = t.id ORDER BY seq DESC LIMIT 1) AS end_lon,
  (SELECT COUNT(*) FROM driven_way_intervals WHERE trip_id = t.id) AS interval_count
FROM trips t
WHERE t.status IN ($statusPlaceholders)
ORDER BY t.ended_at DESC''';

  /// Inbox = trips awaiting a Keep/Discard decision (status == matched),
  /// newest first (INB-01, INB-06).
  Stream<List<TripListItem>> watchInboxTrips() {
    return _watchByStatuses(const [TripStatus.matched]);
  }

  /// History = confirmed trips + in-flight matching trips (Q8, INB-06):
  /// matched + confirmed + pending + pendingRoadData, newest first.
  Stream<List<TripListItem>> watchHistoryTrips() {
    return _watchByStatuses(const [
      TripStatus.matched,
      TripStatus.confirmed,
      TripStatus.pending,
      TripStatus.pendingRoadData,
    ]);
  }

  /// Global queue indicator (Q8): count of pending + pendingRoadData trips.
  Stream<int> watchInFlightCount() {
    return customSelect(
      'SELECT COUNT(*) AS c FROM trips '
      "WHERE status IN ('pending', 'pendingRoadData')",
      readsFrom: {_trips},
    ).watchSingle().map((row) => row.read<int>('c'));
  }

  /// Keep action (INB-03) — status flip matched → confirmed only.
  /// Cache invalidation is orchestrated by `TripsInboxRepository` (Task 3).
  Future<void> transitionToConfirmed(int tripId) {
    return (update(_trips)..where((t) => t.id.equals(tripId))).write(
      const TripsCompanion(status: Value(TripStatus.confirmed)),
    );
  }

  /// Single-row lookup with intervalCount — for the Trip detail screen.
  Future<TripListItem?> getTripWithIntervalCount(int tripId) async {
    final rows = await customSelect(
      '''
SELECT
  t.id                AS id,
  t.status            AS status,
  t.started_at        AS started_at,
  t.ended_at          AS ended_at,
  t.distance_meters   AS distance_meters,
  t.duration_seconds  AS duration_seconds,
  t.vehicle_id        AS vehicle_id,
  t.bbox_min_lat      AS bbox_min_lat,
  t.bbox_min_lon      AS bbox_min_lon,
  t.bbox_max_lat      AS bbox_max_lat,
  t.bbox_max_lon      AS bbox_max_lon,
  (SELECT lat FROM trip_points WHERE trip_id = t.id ORDER BY seq ASC  LIMIT 1) AS start_lat,
  (SELECT lon FROM trip_points WHERE trip_id = t.id ORDER BY seq ASC  LIMIT 1) AS start_lon,
  (SELECT lat FROM trip_points WHERE trip_id = t.id ORDER BY seq DESC LIMIT 1) AS end_lat,
  (SELECT lon FROM trip_points WHERE trip_id = t.id ORDER BY seq DESC LIMIT 1) AS end_lon,
  (SELECT COUNT(*) FROM driven_way_intervals WHERE trip_id = t.id) AS interval_count
FROM trips t
WHERE t.id = ?''',
      variables: [Variable.withInt(tripId)],
      readsFrom: {_trips, _points, _intervals},
    ).get();
    if (rows.isEmpty) return null;
    return _mapRow(rows.first);
  }

  Stream<List<TripListItem>> _watchByStatuses(List<TripStatus> statuses) {
    final placeholders = List.filled(statuses.length, '?').join(', ');
    return customSelect(
      _listQuery(placeholders),
      variables: [
        for (final s in statuses) Variable.withString(_statusConverter.toSql(s)),
      ],
      readsFrom: {_trips, _points, _intervals},
    ).watch().map((rows) => rows.map(_mapRow).toList());
  }

  TripListItem _mapRow(QueryRow row) {
    return TripListItem(
      id: row.read<int>('id'),
      status: _statusConverter.fromSql(row.read<String>('status')),
      startedAt: row.read<DateTime>('started_at'),
      endedAt: row.readNullable<DateTime>('ended_at'),
      distanceMeters: row.readNullable<double>('distance_meters'),
      durationSeconds: row.readNullable<int>('duration_seconds'),
      startLat: row.readNullable<double>('start_lat'),
      startLon: row.readNullable<double>('start_lon'),
      endLat: row.readNullable<double>('end_lat'),
      endLon: row.readNullable<double>('end_lon'),
      intervalCount: row.read<int>('interval_count'),
      vehicleId: row.readNullable<int>('vehicle_id'),
      bboxMinLat: row.readNullable<double>('bbox_min_lat'),
      bboxMinLon: row.readNullable<double>('bbox_min_lon'),
      bboxMaxLat: row.readNullable<double>('bbox_max_lat'),
      bboxMaxLon: row.readNullable<double>('bbox_max_lon'),
    );
  }
}
