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

  /// Close [tripId] by writing summary fields and flipping status to pending.
  Future<void> closeTrip(int tripId, TripSummary s) =>
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
          status: const Value(TripStatus.pending),
        ),
      );

  /// Delete [tripId] and its points (CASCADE on trip_points FK).
  Future<void> deleteTrip(int tripId) =>
      (delete(trips)..where((t) => t.id.equals(tripId))).go();

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
}
