import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/domain/trip_summary.dart';
import 'package:drift/drift.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

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
  }) =>
      into(trips).insert(
        TripsCompanion.insert(
          startedAt: startedAt,
          status: const Value(TripStatus.recording),
          manuallyStarted: Value(manuallyStarted),
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

  /// Persist the trimmed on-road coverage polyline for [tripId] (2026-07-13
  /// coverage-from-trail rework). [json] is the encoded segment list from
  /// `encodeCoveragePath`; `null` clears it. Stored on the trip row so it
  /// survives raw-GPS retention deletion of `trip_points`.
  Future<void> writeCoveragePath(int tripId, String? json) =>
      (update(trips)..where((t) => t.id.equals(tripId))).write(
        TripsCompanion(coveragePathJson: Value(json)),
      );

  /// Reactive stream of every trip's stored coverage-path JSON (non-null only).
  ///
  /// Drives the persistent coverage overlay: each recorded trip contributes
  /// its trimmed on-road polyline. Re-emits whenever any trip's
  /// `coverage_path_json` changes (new match, re-match, discard).
  Stream<List<String>> watchCoveragePaths() {
    final query = selectOnly(trips)
      ..addColumns([trips.coveragePathJson])
      ..where(trips.coveragePathJson.isNotNull());
    return query.watch().map(
          (rows) => [
            for (final r in rows)
              r.read(trips.coveragePathJson) ?? '',
          ]..removeWhere((s) => s.isEmpty),
        );
  }

  /// All trips with `status == TripStatus.pending`, ordered by `endedAt`
  /// ascending (oldest ready-to-match trip first). Used by the Phase 5
  /// match coordinator on app resume.
  Future<List<Trip>> listPendingTrips() =>
      (select(trips)
            ..where((t) => t.status.equalsValue(TripStatus.pending))
            ..orderBy([(t) => OrderingTerm.asc(t.endedAt)]))
          .get();

  /// All trips still parked at `status == TripStatus.pendingRoadData`, ordered
  /// by `endedAt` ascending. Used by the startup orphan-reconcile
  /// (`app.dart`): a trip left here with no `pending_road_fetches` row (e.g.
  /// app killed mid-fetch after a long drive) is invisible to both `drainQueue`
  /// (walks the queue) and `processPending` (matches `pending` only), so it
  /// would spin forever. Reconcile re-enqueues these so `drainQueue` completes
  /// them.
  Future<List<Trip>> listPendingRoadDataTrips() =>
      (select(trips)
            ..where((t) => t.status.equalsValue(TripStatus.pendingRoadData))
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

  /// Reactive stream of the union bounding-box across all matched and
  /// confirmed trips.
  ///
  /// Returns `null` when no trips with bbox columns populated exist (e.g.
  /// fresh install or all trips deleted). Returns a [LatLngBounds] otherwise.
  ///
  /// **Reactivity mechanism (MANDATORY for 07-06 truth #3):**
  /// Implemented via `customSelect(...).watchSingle()` with an EXPLICIT
  /// `readsFrom: {trips, drivenWayIntervals}` set. Drift invalidates the
  /// stream on ANY write to either table — including a `matched→confirmed`
  /// status flip by `TripsInboxDao.transitionToConfirmed` (which writes to
  /// `trips`) AND any new interval write by the matcher (which writes to
  /// `drivenWayIntervals`). The aggregate query targets only `trips`, but
  /// the `readsFrom` set deliberately includes `drivenWayIntervals` so a
  /// future intervals-only mutation path (background re-match, Phase 8
  /// backfill) also triggers a recompute without extra wiring.
  ///
  /// **Do NOT optimise this trigger** to fire only when the aggregated
  /// MIN/MAX value actually changes — the table-write invalidation is the
  /// mechanism, not value-diff. A `matched→confirmed` flip does not change
  /// the `status IN ('matched','confirmed')` membership but still re-emits,
  /// which is correct: the resolver re-reads `getAllIntervals()` on every
  /// call and picks up any freshly-written intervals.
  ///
  /// **Live-refresh chain:**
  ///   confirmTrip (TripsInboxDao.transitionToConfirmed)
  ///     → trips table write
  ///     → watchUnionBbox re-emits
  ///     → tripsUnionBoundsProvider emits
  ///     → coverageOverlayDataProvider re-calls resolve()
  ///     → 07-06 bridge re-applies GeoJSON overlay
  Stream<LatLngBounds?> watchUnionBbox() {
    return customSelect(
      '''
SELECT
  MIN(bbox_min_lat) AS min_lat,
  MIN(bbox_min_lon) AS min_lon,
  MAX(bbox_max_lat) AS max_lat,
  MAX(bbox_max_lon) AS max_lon
FROM trips
WHERE status IN ('matched', 'confirmed')''',
      readsFrom: {trips, attachedDatabase.drivenWayIntervals},
    ).watchSingle().map((row) {
      final minLat = row.readNullable<double>('min_lat');
      final minLon = row.readNullable<double>('min_lon');
      final maxLat = row.readNullable<double>('max_lat');
      final maxLon = row.readNullable<double>('max_lon');
      if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
        return null;
      }
      return LatLngBounds(
        southwest: LatLng(minLat, minLon),
        northeast: LatLng(maxLat, maxLon),
      );
    });
  }
}
