// Trailblazer Phase 6, Plan 06-02 Task 3 tests:
// TripsInboxRepository — Keep (confirm + invalidate) and Discard (invalidate
// → delete intervals → delete trip) flows against an in-memory Drift DB with
// a recording fake CoverageInvalidator + recording DAO subclasses.
//
// Phase 8 (08-02): added _NoopComputeService to satisfy the new required
// `computeService` constructor parameter. The service is fire-and-forget;
// these tests do not verify recompute behavior (that is covered by
// coverage_compute_service_test.dart).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_invalidator.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records calls into a shared log and returns a canned Result. `invalidateAll`
/// is unused by the repository under test but must be implemented.
class _RecordingInvalidator implements CoverageInvalidator {
  _RecordingInvalidator(this.log, {this.result = const Ok(1)});

  final List<String> log;

  /// Canned result returned by both trip-scoped triggers.
  Result<int> result;

  int? lastForTripId;
  int? lastForTripDeleteId;

  @override
  Future<Result<int>> invalidateForTrip(int tripId) async {
    log.add('invalidateForTrip');
    lastForTripId = tripId;
    return result;
  }

  @override
  Future<Result<int>> invalidateForTripDelete(int tripId) async {
    log.add('invalidateForTripDelete');
    lastForTripDeleteId = tripId;
    return result;
  }

  @override
  Future<Result<int>> invalidateAll() async {
    log.add('invalidateAll');
    return result;
  }
}

/// Logs `deleteTrip` calls before delegating to the real implementation.
class _RecordingTripsDao extends TripsDao {
  _RecordingTripsDao(super.attachedDatabase, this.log);
  final List<String> log;

  @override
  Future<void> deleteTrip(int tripId) {
    log.add('deleteTrip');
    return super.deleteTrip(tripId);
  }
}

/// Logs `deleteByTrip` calls before delegating to the real implementation.
class _RecordingIntervalsDao extends DrivenWayIntervalsDao {
  _RecordingIntervalsDao(super.attachedDatabase, this.log);
  final List<String> log;

  @override
  Future<int> deleteByTrip(int tripId) {
    log.add('deleteByTrip');
    return super.deleteByTrip(tripId);
  }
}

/// Minimal fake AdminRegionLookup — always returns null; ensureLoaded is a no-op.
/// Used to construct _NoopComputeService without loading the real bundle.
class _NullAdminRegionLookup implements AdminRegionLookup {
  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async =>
      null;

  @override
  void invalidate() {}

  @override
  AdminRegion? regionByOsmId(int osmId) => null;

  @override
  int get regionCount => 0;

  @override
  int get bundleLoadCount => 0;
}

/// Minimal fake WayCandidateSource — always returns empty lists.
/// Used to construct _NoopComputeService without hitting the network.
class _EmptyWayCandidateSource implements WayCandidateSource {
  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    bool cacheOnly = false,
    void Function(int done, int total)? onTileProgress,
  }) async =>
      const [];

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
    Set<TileId>? restrictTiles,
    bool cacheOnly = false,
    void Function(int done, int total)? onTileProgress,
  }) async =>
      const [];
}

/// No-op CoverageComputeService — overrides recompute() so that the
/// fire-and-forget call in confirmTrip completes immediately with Ok(0).
/// Tests for the actual recompute behavior live in
/// test/features/regions/data/coverage_compute_service_test.dart.
class _NoopComputeService extends CoverageComputeService {
  _NoopComputeService(AppDatabase db)
      : super(
          intervalsDao: DrivenWayIntervalsDao(db),
          waySource: _EmptyWayCandidateSource(),
          regionLookup: _NullAdminRegionLookup(),
          cacheDao: CoverageCacheDao(db),
          tripsDao: TripsDao(db),
          totalsLookup: RegionTotalsLookup(),
        );

  @override
  Future<Result<int>> recompute() async => const Ok(0);
}

void main() {
  late AppDatabase db;
  late TripsInboxDao inboxDao;
  late TripsDao tripsDao;
  late DrivenWayIntervalsDao intervalsDao;
  late List<String> log;
  late _NoopComputeService computeService;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    log = <String>[];
    inboxDao = TripsInboxDao(db);
    tripsDao = _RecordingTripsDao(db, log);
    intervalsDao = _RecordingIntervalsDao(db, log);
    computeService = _NoopComputeService(db);
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON for cascade + SET NULL).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTrip({
    required TripStatus status,
    bool withBbox = true,
  }) {
    return db.into(db.trips).insert(
          TripsCompanion.insert(
            startedAt: DateTime(2026, 7, 9, 8),
            endedAt: Value(DateTime(2026, 7, 9, 9)),
            status: Value(status),
            manuallyStarted: const Value(false),
            bboxMinLat: Value(withBbox ? 49.79 : null),
            bboxMinLon: Value(withBbox ? 9.18 : null),
            bboxMaxLat: Value(withBbox ? 49.80 : null),
            bboxMaxLon: Value(withBbox ? 9.20 : null),
          ),
        );
  }

  Future<void> seedIntervals(int tripId, int count) async {
    for (var i = 0; i < count; i++) {
      await db.into(db.drivenWayIntervals).insert(
            DrivenWayIntervalsCompanion.insert(
              wayId: 1000 + i,
              tripId: Value(tripId),
              startMeters: 0,
              endMeters: 100,
              matchedAt: Value(DateTime(2026, 7, 9, 10)),
            ),
          );
    }
  }

  Future<TripStatus?> statusOf(int tripId) async {
    final trip = await (db.select(db.trips)..where((t) => t.id.equals(tripId)))
        .getSingleOrNull();
    return trip?.status;
  }

  Future<int> tripCount(int tripId) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM trips WHERE id = ?',
          variables: [Variable.withInt(tripId)],
          readsFrom: {db.trips},
        )
        .getSingle();
    return row.read<int>('c');
  }

  Future<int> orphanIntervalCount() async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM driven_way_intervals '
          'WHERE trip_id IS NULL',
          readsFrom: {db.drivenWayIntervals},
        )
        .getSingle();
    return row.read<int>('c');
  }

  TripsInboxRepository buildRepo(_RecordingInvalidator invalidator) {
    return TripsInboxRepository(
      inboxDao: inboxDao,
      tripsDao: tripsDao,
      intervalsDao: intervalsDao,
      invalidator: invalidator,
      computeService: computeService,
    );
  }

  group('confirmTrip', () {
    test('flips matched → confirmed AND invalidates once with the tripId',
        () async {
      final id = await seedTrip(status: TripStatus.matched);
      final invalidator = _RecordingInvalidator(log);
      final repo = buildRepo(invalidator);

      final result = await repo.confirmTrip(id);
      expect(result.isOk, isTrue);
      expect(await statusOf(id), TripStatus.confirmed);
      expect(invalidator.lastForTripId, id);
      expect(
        log.where((c) => c == 'invalidateForTrip').length,
        1,
      );
    });

    test('invalidator error → status flip STILL succeeds, error swallowed',
        () async {
      final id = await seedTrip(status: TripStatus.matched);
      final invalidator = _RecordingInvalidator(
        log,
        result: const Err(UnknownError('boom')),
      );
      final repo = buildRepo(invalidator);

      final result = await repo.confirmTrip(id);
      expect(result.isOk, isTrue);
      expect(await statusOf(id), TripStatus.confirmed);
    });

    test('non-matched trip: flip is idempotent no-op, invalidator still called',
        () async {
      final id = await seedTrip(status: TripStatus.pending);
      final invalidator = _RecordingInvalidator(log);
      final repo = buildRepo(invalidator);

      final result = await repo.confirmTrip(id);
      expect(result.isOk, isTrue);
      // transitionToConfirmed writes confirmed unconditionally; the point
      // is that the invalidator is invoked regardless (both idempotent).
      expect(invalidator.lastForTripId, id);
    });
  });

  group('discardTrip', () {
    test('call ordering: invalidateForTripDelete → deleteByTrip → deleteTrip',
        () async {
      final id = await seedTrip(status: TripStatus.matched);
      await seedIntervals(id, 3);
      final invalidator = _RecordingInvalidator(log);
      final repo = buildRepo(invalidator);

      final result = await repo.discardTrip(id);
      expect(result.isOk, isTrue);
      expect(log, ['invalidateForTripDelete', 'deleteByTrip', 'deleteTrip']);
    });

    test('deletes intervals + trip with no orphans left', () async {
      final id = await seedTrip(status: TripStatus.matched);
      await seedIntervals(id, 3);
      final repo = buildRepo(_RecordingInvalidator(log));

      await repo.discardTrip(id);

      expect(await orphanIntervalCount(), 0);
      expect(await tripCount(id), 0);
    });

    test('invalidator error → discard STILL deletes (error swallowed)',
        () async {
      final id = await seedTrip(status: TripStatus.matched);
      await seedIntervals(id, 2);
      final invalidator = _RecordingInvalidator(
        log,
        result: const Err(UnknownError('boom')),
      );
      final repo = buildRepo(invalidator);

      final result = await repo.discardTrip(id);
      // A cache-invalidation hiccup must NOT strand the card: the delete
      // proceeds and the trip is gone (regression for the 2026-07-10
      // "Discard does nothing" report — invalidation was OOM-failing behind
      // the 43 MB admin parse and aborting the delete).
      expect(result.isOk, isTrue);
      expect(await tripCount(id), 0);
      expect(await orphanIntervalCount(), 0);
      // The deletes were still issued despite the invalidation error.
      expect(log, ['invalidateForTripDelete', 'deleteByTrip', 'deleteTrip']);
    });

    test('fail-matched trip (bbox null): invalidator Ok(0), delete completes',
        () async {
      final id = await seedTrip(status: TripStatus.matched, withBbox: false);
      final invalidator = _RecordingInvalidator(log, result: const Ok(0));
      final repo = buildRepo(invalidator);

      final result = await repo.discardTrip(id);
      expect(result.isOk, isTrue);
      expect(await tripCount(id), 0);
    });
  });

  group('stream pass-throughs', () {
    test('watchInboxItems / watchHistoryItems / watchInFlightCount', () async {
      await seedTrip(status: TripStatus.matched);
      await seedTrip(status: TripStatus.confirmed);
      await seedTrip(status: TripStatus.pending);
      final repo = buildRepo(_RecordingInvalidator(log));

      expect(await repo.watchInboxItems().first, hasLength(1));
      expect(await repo.watchHistoryItems().first, hasLength(3));
      expect(await repo.watchInFlightCount().first, 1);
    });
  });
}
