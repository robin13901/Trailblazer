// Trailblazer Phase 6, Plan 06-01 Task 3 tests: CoverageInvalidator over
// three triggers, with a fake AdminRegionLookup + a fake TripsDao seeded
// on an in-memory Drift database.

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/coverage/data/coverage_invalidator.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic fake — returns a preseeded [AdminRegion] for `(level)`,
/// null otherwise. Fake regionId is the region's osmId as a string
/// (matches the invalidator's real conversion).
class _FakeAdminRegionLookup implements AdminRegionLookup {
  _FakeAdminRegionLookup(this.byLevel);

  /// Map from admin_level → AdminRegion (or null to force a null return).
  final Map<int, AdminRegion?> byLevel;

  int calls = 0;

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async {
    calls++;
    return byLevel[adminLevel];
  }

  @override
  Future<void> ensureLoaded() async {}

  @override
  void invalidate() {}

  @override
  AdminRegion? regionByOsmId(int osmId) {
    for (final r in byLevel.values) {
      if (r != null && r.osmId == osmId) return r;
    }
    return null;
  }

  @override
  int get regionCount => byLevel.length;

  @override
  int get bundleLoadCount => 0;
}

AdminRegion _region(int osmId, int level, String name) => AdminRegion(
      osmId: osmId,
      adminLevel: level,
      name: name,
      // Bbox and polygons unused by CoverageInvalidator — the fake
      // returns pre-canned regions without geometry checks.
      bboxMinLat: 0,
      bboxMinLon: 0,
      bboxMaxLat: 0,
      bboxMaxLon: 0,
      polygons: const [],
    );

void main() {
  late AppDatabase db;
  late TripsDao tripsDao;
  late CoverageCacheDao cacheDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tripsDao = TripsDao(db);
    cacheDao = CoverageCacheDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> insertTripWithBbox({
    required double? minLat,
    required double? minLon,
    required double? maxLat,
    required double? maxLon,
  }) {
    return db.into(db.trips).insert(
          TripsCompanion.insert(
            startedAt: DateTime(2026, 7, 9, 12),
            status: const Value(TripStatus.matched),
            manuallyStarted: const Value(false),
            bboxMinLat: Value(minLat),
            bboxMinLon: Value(minLon),
            bboxMaxLat: Value(maxLat),
            bboxMaxLon: Value(maxLon),
          ),
        );
  }

  Future<void> seedCoverageRows(Iterable<String> regionIds) async {
    for (final id in regionIds) {
      await cacheDao.upsert(
        regionId: id,
        drivenLengthM: 10,
        totalLengthM: 100,
        updatedAt: DateTime(2026, 7, 9),
      );
    }
  }

  group('CoverageInvalidator.invalidateForTrip', () {
    test('Kleinheubach-ish bbox deletes rows for 4 sampled admin regions',
        () async {
      final lookup = _FakeAdminRegionLookup({
        4: _region(2145268, 4, 'Bayern'),
        6: _region(62422, 6, 'Landkreis Miltenberg'),
        8: _region(151999, 8, 'Kleinheubach'),
        10: _region(555555, 10, 'Kleinheubach Ortsteil'),
      });
      await seedCoverageRows(const [
        '2145268',
        '62422',
        '151999',
        '555555',
        // unrelated region — must survive
        'unrelated-region',
      ]);
      final tripId = await insertTripWithBbox(
        minLat: 49.79,
        minLon: 9.18,
        maxLat: 49.80,
        maxLon: 9.20,
      );

      final invalidator = CoverageInvalidator(
        cacheDao: cacheDao,
        regionLookup: lookup,
        tripsDao: tripsDao,
      );

      final result = await invalidator.invalidateForTrip(tripId);
      final deleted = result.when(ok: (v) => v, err: (_) => -1);
      expect(deleted, 4);

      expect(await cacheDao.getByRegionId('2145268'), isNull);
      expect(await cacheDao.getByRegionId('62422'), isNull);
      expect(await cacheDao.getByRegionId('151999'), isNull);
      expect(await cacheDao.getByRegionId('555555'), isNull);
      expect(await cacheDao.getByRegionId('unrelated-region'), isNotNull);

      // 5 samples × 4 admin levels = 20 lookup calls (idempotent per
      // level — dedup happens in the invalidator).
      expect(lookup.calls, 20);
    });

    test('null bbox returns Ok(0), no lookup issued', () async {
      final lookup = _FakeAdminRegionLookup({
        4: _region(1, 4, 'DE'),
      });
      await seedCoverageRows(const ['1']);
      final tripId = await insertTripWithBbox(
        minLat: null,
        minLon: null,
        maxLat: null,
        maxLon: null,
      );

      final invalidator = CoverageInvalidator(
        cacheDao: cacheDao,
        regionLookup: lookup,
        tripsDao: tripsDao,
      );
      final result = await invalidator.invalidateForTrip(tripId);
      expect(result.when(ok: (v) => v, err: (_) => -1), 0);
      expect(lookup.calls, 0);
      expect(await cacheDao.getByRegionId('1'), isNotNull);
    });

    test('missing tripId returns Ok(0), no lookup issued', () async {
      final lookup = _FakeAdminRegionLookup({
        4: _region(1, 4, 'DE'),
      });
      final invalidator = CoverageInvalidator(
        cacheDao: cacheDao,
        regionLookup: lookup,
        tripsDao: tripsDao,
      );

      final result = await invalidator.invalidateForTrip(999999);
      expect(result.when(ok: (v) => v, err: (_) => -1), 0);
      expect(lookup.calls, 0);
    });

    test('second call on same trip is idempotent (returns Ok(0))', () async {
      final lookup = _FakeAdminRegionLookup({
        6: _region(62422, 6, 'Landkreis Miltenberg'),
      });
      await seedCoverageRows(const ['62422']);
      final tripId = await insertTripWithBbox(
        minLat: 49.79,
        minLon: 9.18,
        maxLat: 49.80,
        maxLon: 9.20,
      );

      final invalidator = CoverageInvalidator(
        cacheDao: cacheDao,
        regionLookup: lookup,
        tripsDao: tripsDao,
      );

      final first = await invalidator.invalidateForTrip(tripId);
      expect(first.when(ok: (v) => v, err: (_) => -1), 1);

      final second = await invalidator.invalidateForTrip(tripId);
      expect(second.when(ok: (v) => v, err: (_) => -1), 0);
    });

    test('AdminRegionLookup returning null at some levels does not crash',
        () async {
      final lookup = _FakeAdminRegionLookup({
        4: _region(1, 4, 'DE'),
        // 6 + 8 + 10 return null (Bundesländer only, ocean lookup, etc.)
        6: null,
        8: null,
        10: null,
      });
      await seedCoverageRows(const ['1', '2', '3']);
      final tripId = await insertTripWithBbox(
        minLat: 49.79,
        minLon: 9.18,
        maxLat: 49.80,
        maxLon: 9.20,
      );

      final invalidator = CoverageInvalidator(
        cacheDao: cacheDao,
        regionLookup: lookup,
        tripsDao: tripsDao,
      );

      final result = await invalidator.invalidateForTrip(tripId);
      expect(result.when(ok: (v) => v, err: (_) => -1), 1);
      expect(await cacheDao.getByRegionId('1'), isNull);
      expect(await cacheDao.getByRegionId('2'), isNotNull);
      expect(await cacheDao.getByRegionId('3'), isNotNull);
    });
  });

  group('CoverageInvalidator.invalidateForTripDelete', () {
    test('shares behavior with invalidateForTrip', () async {
      final lookup = _FakeAdminRegionLookup({
        4: _region(1, 4, 'DE'),
        6: _region(62422, 6, 'Landkreis Miltenberg'),
      });
      await seedCoverageRows(const ['1', '62422', 'other']);
      final tripId = await insertTripWithBbox(
        minLat: 49.79,
        minLon: 9.18,
        maxLat: 49.80,
        maxLon: 9.20,
      );

      final invalidator = CoverageInvalidator(
        cacheDao: cacheDao,
        regionLookup: lookup,
        tripsDao: tripsDao,
      );

      final result = await invalidator.invalidateForTripDelete(tripId);
      expect(result.when(ok: (v) => v, err: (_) => -1), 2);
      expect(await cacheDao.getByRegionId('1'), isNull);
      expect(await cacheDao.getByRegionId('62422'), isNull);
      expect(await cacheDao.getByRegionId('other'), isNotNull);
    });
  });

  group('CoverageInvalidator.invalidateAll', () {
    test('truncates the coverage_cache table and reports the count',
        () async {
      final lookup = _FakeAdminRegionLookup(const {});
      await seedCoverageRows(const ['a', 'b', 'c', 'd']);

      final invalidator = CoverageInvalidator(
        cacheDao: cacheDao,
        regionLookup: lookup,
        tripsDao: tripsDao,
      );

      final result = await invalidator.invalidateAll();
      expect(result.when(ok: (v) => v, err: (_) => -1), 4);
      for (final id in const ['a', 'b', 'c', 'd']) {
        expect(await cacheDao.getByRegionId(id), isNull);
      }
    });
  });
}
