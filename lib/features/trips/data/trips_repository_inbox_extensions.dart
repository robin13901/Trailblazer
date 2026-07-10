// Trailblazer Phase 6, Plan 06-02 Task 3:
// TripsInboxRepository — inbox-facing repository wrapping TripsInboxDao +
// CoverageInvalidator + DrivenWayIntervalsDao at the Result<T> boundary.
//
// Shipped as a companion class (NOT modifying `trips_repository.dart`) to
// keep file ownership clean across the wave.
//
// Two critical ordering rules (RESEARCH Pitfalls #3 + Issue 1 / SC3):
//   * confirmTrip: flip status FIRST, THEN invalidate coverage cache —
//     Keep is the observable moment coverage may change (SC3).
//   * discardTrip: invalidate cache FIRST (needs bbox), THEN delete
//     intervals (FK is ON DELETE SET NULL, not CASCADE), THEN delete the
//     trip row (which cascades trip_points).

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/coverage/data/coverage_invalidator.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

/// Repository for the Phase-6 inbox Keep/Discard flows and list streams.
class TripsInboxRepository {
  TripsInboxRepository({
    required TripsInboxDao inboxDao,
    required TripsDao tripsDao,
    required DrivenWayIntervalsDao intervalsDao,
    required CoverageInvalidator invalidator,
    Logger? logger,
  })  : _inboxDao = inboxDao,
        _tripsDao = tripsDao,
        _intervalsDao = intervalsDao,
        _invalidator = invalidator,
        _log = logger ?? Logger('TripsInboxRepository');

  final TripsInboxDao _inboxDao;
  final TripsDao _tripsDao;
  final DrivenWayIntervalsDao _intervalsDao;
  final CoverageInvalidator _invalidator;
  final Logger _log;

  /// Keep (INB-03 + COV-06 trigger 1 / SC3).
  ///
  /// 1. Flip status matched → confirmed.
  /// 2. Invalidate the coverage cache so the next coverage read recomputes.
  ///
  /// The status flip is idempotent (a no-op on non-matched trips). The
  /// invalidator is also idempotent — a second call returns Ok(0). If the
  /// invalidator ERRORS, it is logged and swallowed: the user's Keep must
  /// not be lost just because the cache could not be dropped (a subsequent
  /// coverage read still triggers a recompute in P8).
  Future<Result<void>> confirmTrip(int tripId) async {
    try {
      // 1. Flip status — matched → confirmed.
      await _inboxDao.transitionToConfirmed(tripId);
      // 2. Invalidate coverage cache — COV-06 trigger 1 / SC3.
      final invalidation = await _invalidator.invalidateForTrip(tripId);
      if (invalidation.isErr) {
        // Non-fatal: the status flip already committed. Log + swallow so
        // the user's Keep is preserved.
        invalidation.when(
          ok: (_) {},
          err: (e) => _log.warning(
            'confirmTrip($tripId): coverage invalidation failed '
            '(status flip preserved): $e',
          ),
        );
      }
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Discard (INB-04 + INB-08 + COV-06 trigger 2).
  ///
  /// Hard delete in strict order:
  /// 1. Invalidate cache FIRST — the invalidator reads the trip's bbox,
  ///    which must still exist. Best-effort: if it fails, we log + swallow
  ///    and STILL delete (mirrors [confirmTrip]). A discard must never be
  ///    stranded by a cache-layer hiccup — the user asked for the trip gone.
  ///    A stale cache row at worst triggers a recompute on the next read.
  /// 2. Delete `driven_way_intervals` explicitly — the FK is
  ///    ON DELETE SET NULL, so deleting the trip would orphan them.
  /// 3. Delete the trip row (cascades `trip_points`).
  Future<Result<void>> discardTrip(int tripId) async {
    try {
      // 1. Invalidate cache FIRST — needs the bbox from the trip row. If it
      //    errors, log + swallow: the delete below is what the user asked
      //    for and must proceed regardless (was: aborted here, which left
      //    the card stuck in the inbox whenever invalidation hiccupped).
      final invalidation = await _invalidator.invalidateForTripDelete(tripId);
      if (invalidation.isErr) {
        invalidation.when(
          ok: (_) {},
          err: (e) => _log.warning(
            'discardTrip($tripId): coverage invalidation failed '
            '(proceeding with delete anyway): $e',
          ),
        );
      }
      // 2. Delete intervals (FK is SET NULL, not CASCADE).
      await _intervalsDao.deleteByTrip(tripId);
      // 3. Delete the trip row (cascades trip_points).
      await _tripsDao.deleteTrip(tripId);
      return const Ok(null);
      // Catches all throwables (Error + Exception) for DomainError.wrap.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  /// Inbox list stream (status == matched).
  Stream<List<TripListItem>> watchInboxItems() => _inboxDao.watchInboxTrips();

  /// History list stream (matched + confirmed + pending + pendingRoadData).
  Stream<List<TripListItem>> watchHistoryItems() =>
      _inboxDao.watchHistoryTrips();

  /// Global in-flight queue count (pending + pendingRoadData).
  Stream<int> watchInFlightCount() => _inboxDao.watchInFlightCount();
}

/// Singleton [TripsInboxRepository] — plain `Provider<T>` per STATE 01-01.
final tripsInboxRepositoryProvider = Provider<TripsInboxRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return TripsInboxRepository(
    inboxDao: TripsInboxDao(db),
    tripsDao: ref.watch(tripsDaoProvider),
    intervalsDao: DrivenWayIntervalsDao(db),
    invalidator: ref.watch(coverageInvalidatorProvider),
  );
});
