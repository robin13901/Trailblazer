import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/domain/trip_summary.dart';
import 'package:drift/drift.dart';

/// Drift DAO for the trips and trip_points tables.
///
/// Accesses tables via [attachedDatabase] to avoid the circular-import
/// issue that arises when listing table types in @DriftAccessor.
///
/// This is the sole Drift-level write path for trip and point data.
/// All callers should go through TripsRepository, which wraps these calls
/// in Result and handles error translation.
class TripsDao extends DatabaseAccessor<AppDatabase> {
  TripsDao(super.attachedDatabase);

  $TripsTable get trips => attachedDatabase.trips;
  $TripPointsTable get tripPoints => attachedDatabase.tripPoints;

  /// Insert a new trip row with status=recording and return the new row id.
  Future<int> openTrip({
    required DateTime startedAt,
    required bool manuallyStarted,
    int? vehicleId,
  }) =>
      into(trips).insert(
        TripsCompanion.insert(
          startedAt: startedAt,
          status: const Value(TripStatus.recording),
          manuallyStarted: Value(manuallyStarted),
          vehicleId: Value(vehicleId),
        ),
      );

  /// Batch-insert GPS point rows for [tripId].
  Future<void> appendPointsBatch(
    int tripId,
    List<TripPointsCompanion> points,
  ) =>
      batch((b) => b.insertAll(tripPoints, points));

  /// Close [tripId] by writing summary fields and flipping status.
  ///
  /// [status] defaults to [TripStatus.pending] for back-compat with the pre-04-15
  /// call sites. Plan 04-15's coordinator path passes
  /// [TripStatus.pendingRoadData] instead so the trip is parked while the
  /// Overpass road-fetch runs (or is enqueued for later).
  Future<void> closeTrip(
    int tripId,
    TripSummary s, {
    TripStatus status = TripStatus.pending,
  }) =>
      (update(trips)..where((t) => t.id.equals(tripId))).write(
        TripsCompanion(
          endedAt: Value(s.endedAt),
          durationSeconds: Value(s.durationSeconds),
          distanceMeters: Value(s.distanceMeters),
          avgSpeedKmh: Value(s.avgSpeedKmh),
          maxSpeedKmh: Value(s.maxSpeedKmh),
          pointCount: Value(s.pointCount),
          bboxMinLat: Value(s.bboxMinLat),
          bboxMinLon: Value(s.bboxMinLon),
          bboxMaxLat: Value(s.bboxMaxLat),
          bboxMaxLon: Value(s.bboxMaxLon),
          autoStopped: Value(s.autoStopped),
          status: Value(status),
        ),
      );

  /// Delete [tripId] and its points (CASCADE on trip_points FK).
  Future<void> deleteTrip(int tripId) =>
      (delete(trips)..where((t) => t.id.equals(tripId))).go();

  /// Flip [tripId] to [TripStatus.pendingRoadData] — used by the 04-15 trip
  /// road-fetch coordinator after a trip stops but BEFORE the Overpass road
  /// data has arrived. Idempotent (no-op if the trip is already in that
  /// state).
  Future<void> transitionToPendingRoadData(int tripId) =>
      (update(trips)..where((t) => t.id.equals(tripId))).write(
        const TripsCompanion(status: Value(TripStatus.pendingRoadData)),
      );

  /// Flip [tripId] to [TripStatus.pending] once road data has been cached.
  /// Used by the 04-15 coordinator's `onTripStopped` (online path) and
  /// `drainQueue` (offline-recovery path).
  Future<void> transitionToPending(int tripId) =>
      (update(trips)..where((t) => t.id.equals(tripId))).write(
        const TripsCompanion(status: Value(TripStatus.pending)),
      );

  /// Flip [tripId] to [TripStatus.matched] once the Phase 5 matcher has
  /// written its intervals. Idempotent — calling this on an already-matched
  /// trip is a no-op from the DB perspective.
  Future<void> transitionToMatched(int tripId) =>
      (update(trips)..where((t) => t.id.equals(tripId))).write(
        const TripsCompanion(status: Value(TripStatus.matched)),
      );

  /// All trips with `status == TripStatus.pending`, ordered by `endedAt`
  /// ascending (oldest ready-to-match trip first). Used by the Phase 5
  /// match coordinator on app resume.
  Future<List<Trip>> listPendingTrips() =>
      (select(trips)
            ..where((t) => t.status.equalsValue(TripStatus.pending))
            ..orderBy([(t) => OrderingTerm.asc(t.endedAt)]))
          .get();

  /// All trip_points for [tripId], ordered by `seq`. Returned as plain
  /// Drift rows; conversion to GpsFix happens on the caller side.
  Future<List<TripPoint>> listPointsForTrip(int tripId) =>
      (select(tripPoints)
            ..where((p) => p.tripId.equals(tripId))
            ..orderBy([(p) => OrderingTerm.asc(p.seq)]))
          .get();

  /// Return the newest open trip (endedAt IS NULL), or null if none.
  ///
  /// Used for cold-start hydration in TrackingNotifier.
  Future<Trip?> activeTrip() =>
      (select(trips)
            ..where((t) => t.endedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.id)])
            ..limit(1))
          .getSingleOrNull();

  /// Watch all points for [tripId] ordered by sequence number.
  Stream<List<TripPoint>> watchPoints(int tripId) =>
      (select(tripPoints)
            ..where((p) => p.tripId.equals(tripId))
            ..orderBy([(p) => OrderingTerm.asc(p.seq)]))
          .watch();

  /// Delete `trip_points` rows for trips whose matched intervals are all
  /// older than [cutoff]. Returns the number of point rows deleted.
  ///
  /// A trip is eligible for point-sweep only if it has AT LEAST ONE row in
  /// `driven_way_intervals` (i.e. it has been matched). Unmatched trips
  /// retain their points indefinitely — the matcher must run first before
  /// the 30-day clock starts.
  ///
  /// Uses MAX(matched_at) in a HAVING clause so that a trip with any
  /// recent interval (even if older intervals exist) is NOT swept:
  ///
  ///   DELETE FROM trip_points
  ///   WHERE trip_id IN (
  ///     SELECT d.trip_id FROM driven_way_intervals d
  ///     WHERE d.trip_id IS NOT NULL
  ///     GROUP BY d.trip_id
  ///     HAVING MAX(d.matched_at) < ?
  ///   );
  Future<int> deleteTripPointsForMatchedTripsOlderThan(
    DateTime cutoff,
  ) async {
    final rows = await customUpdate(
      'DELETE FROM trip_points '
      'WHERE trip_id IN ('
      '  SELECT d.trip_id FROM driven_way_intervals d '
      '  WHERE d.trip_id IS NOT NULL '
      '  GROUP BY d.trip_id '
      '  HAVING MAX(d.matched_at) < ?'
      ' )',
      variables: [Variable.withDateTime(cutoff)],
      updates: {tripPoints},
      updateKind: UpdateKind.delete,
    );
    return rows;
  }
}
