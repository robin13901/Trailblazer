import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:auto_explore/features/trips/domain/trip_summary.dart';

/// Domain-facing repository for trips and trip-point writes.
///
/// All non-stream methods return `Result<T>`; any exception that is not already
/// a DomainError is wrapped via DomainError.wrap (STATE.md 01-04).
///
/// [TripPointsCompanion] is accessible via this import so callers
/// (TrackingNotifier) can build point batches without importing Drift directly.
class TripsRepository {
  TripsRepository(this._dao);

  final TripsDao _dao;

  /// Open a new recording trip and return its id.
  Future<Result<int>> openTrip({
    required DateTime startedAt,
    required bool manuallyStarted,
  }) async {
    try {
      final id = await _dao.openTrip(
        startedAt: startedAt,
        manuallyStarted: manuallyStarted,
      );
      return Ok(id);
      // DomainError.wrap accepts Object — must catch all throwables including
      // Drift's SqliteException and Error subtypes, not only Exception.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Append a batch of GPS points to [tripId].
  Future<Result<void>> appendPoints(
    int tripId,
    List<TripPointsCompanion> points,
  ) async {
    try {
      await _dao.appendPointsBatch(tripId, points);
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Close [tripId] with [summary] (writes bbox, pointCount, durations).
  ///
  /// [status] defaults to `pending` (matches pre-04-15 behaviour). The 04-15
  /// coordinator invokes this with `pendingRoadData` so the trip is parked
  /// while the Overpass road-fetch runs, then flips to `pending` via
  /// [transitionToPending] on success.
  Future<Result<void>> closeTrip(
    int tripId,
    TripSummary summary, {
    TripStatus status = TripStatus.pending,
  }) async {
    try {
      await _dao.closeTrip(tripId, summary, status: status);
      // Denormalize start/end coords onto the trip row now, while its raw
      // `trip_points` still exist, so reverse-geocoded place names survive a
      // later retention sweep of the points (v7). Best-effort: the close
      // itself already succeeded, so a backfill hiccup must not fail it.
      await _dao.backfillEndpoints(tripId);
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Delete [tripId] and all its points (CASCADE).
  Future<Result<void>> deleteTrip(int tripId) async {
    try {
      await _dao.deleteTrip(tripId);
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Flip [tripId] to `pendingRoadData` (04-15 coordinator entry point).
  Future<Result<void>> transitionToPendingRoadData(int tripId) async {
    try {
      await _dao.transitionToPendingRoadData(tripId);
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Flip [tripId] to `pending` (04-15 coordinator success path).
  Future<Result<void>> transitionToPending(int tripId) async {
    try {
      await _dao.transitionToPending(tripId);
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Flip [tripId] to `matched` (Phase 5 coordinator success path).
  ///
  /// Called by TripMatchCoordinator after successfully inserting all
  /// DrivenWayInterval rows for the trip.
  Future<Result<void>> transitionToMatched(int tripId) async {
    try {
      await _dao.transitionToMatched(tripId);
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Return the newest open trip row, or null if none (cold-start hydration).
  Future<Result<Trip?>> activeTrip() async {
    try {
      final trip = await _dao.activeTrip();
      return Ok(trip);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Load all persisted GPS fixes for [tripId] (seq order) as [FixInput]s —
  /// used by cold-start crash recovery to REPLAY an interrupted `recording`
  /// trip through a fresh ingestor and finalize it as a completed (truncated)
  /// trip. Returns the persisted points only; any fixes buffered in RAM at the
  /// time of the crash are already lost (never reached the DB).
  ///
  /// A stored point carries no per-fix UUID (dedup is a live-only concern), so
  /// `uuid` is null on replay — harmless: the points were already accepted once
  /// and their seq order guarantees no duplicates.
  Future<Result<List<FixInput>>> loadFixInputs(int tripId) async {
    try {
      final points = await _dao.listPointsForTrip(tripId);
      final fixes = [
        for (final p in points)
          FixInput(
            ts: p.ts,
            lat: p.lat,
            lon: p.lon,
            // Stored accuracy already passed the ingestor's accuracy gate when
            // first accepted; default to 0 (best) when the column is null so a
            // null never re-fails the filter on replay.
            accuracyMeters: p.accuracyMeters ?? 0,
            speedMps: p.speedKmh != null ? p.speedKmh! / 3.6 : null,
            altitudeMeters: p.altitudeMeters,
            activityType: p.motionType,
          ),
      ];
      return Ok(fixes);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Watch all points for [tripId] in sequence order.
  ///
  /// Returns a raw stream — the caller handles errors via StreamBuilder /
  /// Riverpod's AsyncValue machinery.
  Stream<List<TripPoint>> watchPoints(int tripId) =>
      _dao.watchPoints(tripId);

  /// 30-day raw-GPS retention sweep (MMT-10). Deletes trip_points rows
  /// for trips whose matched intervals are all older than [retention].
  ///
  /// Delegates to [TripsDao.deleteTripPointsForMatchedTripsOlderThan].
  /// Wraps throwables in [DomainError] per the repository contract.
  ///
  /// [retention] defaults to 30 days; Phase 10 will override this from
  /// AppPrefs when the settings UI ships.
  Future<Result<int>> sweepRawGpsRetention({
    Duration retention = const Duration(days: 30),
    DateTime? now,
  }) async {
    try {
      final cutoff = (now ?? DateTime.now()).subtract(retention);
      final n = await _dao.deleteTripPointsForMatchedTripsOlderThan(cutoff);
      return Ok(n);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }
}
