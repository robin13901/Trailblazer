// Trailblazer Phase 6, Plan 06-01 (Wave 1 Task 3):
// CoverageInvalidator — orchestrates the P6 coverage-cache invalidation
// triggers.
//
// Three trigger surfaces (COV-06):
//   1. new driven_way_intervals written after a match (called by
//      TripsInboxRepository.confirmTrip in 06-02 — AFTER the status flip),
//   2. trip deleted from Trip History (called by discardTrip BEFORE the
//      row is removed, so bbox is still readable),
//   3. OSM extract updated (P10 concern; P6 stub truncates the cache).
//
// The invalidator is agnostic of the caller — 06-02 wires it into the
// TripsInboxRepository (both confirm and discard paths). It resolves the
// affected admin regions by sampling the trip bbox's four corners and
// centroid at each admin level in [4, 6, 8, 10] (STATE Plan 04-16 —
// L2/L4/L6/L8/L9/L10 are covered by the bundled admin polygons; L9 is
// intentionally skipped to match COV-06's coarse-to-fine sampling —
// L4/L6/L8/L10 is the plan-specified sample set).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';

/// Admin levels sampled per trip bbox. See COV-06 trigger 1.
///
/// L2 (country) is intentionally excluded — the full-DE region row would
/// invalidate on every trip, defeating the point of the cache.
const List<int> kCoverageAdminLevels = [4, 6, 8, 10];

/// Orchestrator for coverage-cache invalidation triggers.
///
/// Every public method returns `Result<int>`; the int is the number of
/// `coverage_cache` rows removed. Non-DomainError throwables are wrapped
/// via [DomainError.wrap] at the boundary (STATE 01-04).
class CoverageInvalidator {
  CoverageInvalidator({
    required CoverageCacheDao cacheDao,
    required AdminRegionLookup regionLookup,
    required TripsDao tripsDao,
  })  : _cacheDao = cacheDao,
        _regionLookup = regionLookup,
        _tripsDao = tripsDao;

  final CoverageCacheDao _cacheDao;
  final AdminRegionLookup _regionLookup;
  final TripsDao _tripsDao;

  /// Trigger 1: called after a trip has been confirmed AND matched
  /// (`TripsInboxRepository.confirmTrip` in 06-02, once the status has
  /// flipped from matched → confirmed).
  ///
  /// Missing trip or a fail-matched trip with null bbox both return
  /// `Ok(0)` — nothing to invalidate is a valid outcome, not an error.
  ///
  /// Idempotent: a second call for the same trip after cache rows are
  /// already gone returns `Ok(0)`.
  Future<Result<int>> invalidateForTrip(int tripId) =>
      _invalidateByTripBbox(tripId);

  /// Trigger 2: called by `TripsInboxRepository.discardTrip` BEFORE the
  /// trip row is deleted, so its bbox is still readable. Shares the same
  /// implementation as [invalidateForTrip].
  Future<Result<int>> invalidateForTripDelete(int tripId) =>
      _invalidateByTripBbox(tripId);

  /// Trigger 3: OSM-extract-updated stub for P6 — wired to the real
  /// extract-swap event in P10 (Settings > Backup). Truncates the cache
  /// wholesale.
  Future<Result<int>> invalidateAll() async {
    try {
      final deleted = await _cacheDao.deleteAll();
      return Ok(deleted);
      // DomainError.wrap accepts Object — must catch all throwables including
      // Drift's SqliteException and Error subtypes, not only Exception.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  Future<Result<int>> _invalidateByTripBbox(int tripId) async {
    try {
      final trip = await _loadTrip(tripId);
      if (trip == null) return const Ok(0);

      final minLat = trip.bboxMinLat;
      final minLon = trip.bboxMinLon;
      final maxLat = trip.bboxMaxLat;
      final maxLon = trip.bboxMaxLon;
      if (minLat == null ||
          minLon == null ||
          maxLat == null ||
          maxLon == null) {
        // Fail-matched trip: no bbox, no coverage impact.
        return const Ok(0);
      }

      final centreLat = (minLat + maxLat) / 2;
      final centreLon = (minLon + maxLon) / 2;
      final samplePoints = <List<double>>[
        [minLat, minLon],
        [minLat, maxLon],
        [maxLat, minLon],
        [maxLat, maxLon],
        [centreLat, centreLon],
      ];

      final regionIds = <String>{};
      for (final p in samplePoints) {
        for (final level in kCoverageAdminLevels) {
          final region = await _regionLookup.regionAt(p[0], p[1], level);
          if (region == null) continue;
          // NOTE: OSM relation IDs are globally unique across admin
          // levels (04-01 pitfall). Do NOT prefix with "$level:".
          regionIds.add(region.osmId.toString());
        }
      }

      if (regionIds.isEmpty) return const Ok(0);
      final deleted = await _cacheDao.deleteByRegionIds(regionIds);
      return Ok(deleted);
      // DomainError.wrap accepts Object — must catch all throwables including
      // Drift's SqliteException and Error subtypes, not only Exception.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      return Err(DomainError.wrap(e, st));
    }
  }

  Future<Trip?> _loadTrip(int tripId) {
    // Query directly against the attached database — TripsDao does not
    // (yet) expose a getById method, and adding one here would require
    // touching a file outside this plan's ownership manifest.
    final db = _tripsDao.attachedDatabase;
    return (db.select(db.trips)..where((t) => t.id.equals(tripId)))
        .getSingleOrNull();
  }
}
