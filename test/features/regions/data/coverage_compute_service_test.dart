// Trailblazer Phase 8, Plan 08-02 (Wave 1) / updated Phase 10, Plan 10-04:
// CoverageComputeService unit tests — integration-style against an in-memory
// Drift database + fake collaborators.
//
// Test inventory:
//  1. Empty DB (no intervals, null bbox) → recompute() == Ok(0), cache empty.
//  2. Ways present but null bbox (no matched/confirmed trips) → Ok(0), no rows.
//  3. No matching admin region (regionAt all null) → Ok(0), no rows written.
//  4. One driven way inside a known region → row written with totalLengthM > 0
//     AND drivenLengthM > 0; getAllWithCoverage() contains the region.
//  5. Un-driven way in region → totalLengthM > 0 but drivenLengthM == 0;
//     getAllWithCoverage() does NOT contain it (driven > 0 filter).
//  6. Re-population: deleteByRegionIds simulates the invalidator; recompute()
//     again → row reappears.
//  7. Level 2 is never written (explicit assertion when the fake injects
//     a level-2 region alongside level 8).
//  8. Bundled real total: when RegionTotalsLookup provides a total for the
//     region, recompute() writes real_total_length_m from the bundled table.
//  9. Missing bundled total: when RegionTotalsLookup returns null for a
//     region, real_total_length_m is written as null (no error, no crash).

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_job.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_service.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Fake AdminRegionLookup backed by a map from admin_level → region.
/// A null entry explicitly signals "no region at this level".
class _FakeAdminRegionLookup implements AdminRegionLookup {
  _FakeAdminRegionLookup(this._byLevel);

  final Map<int, AdminRegion?> _byLevel;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<AdminRegion?> regionAt(
    double lat,
    double lon,
    int adminLevel,
  ) async =>
      _byLevel[adminLevel];

  @override
  void invalidate() {}

  @override
  AdminRegion? regionByOsmId(int osmId) {
    for (final r in _byLevel.values) {
      if (r != null && r.osmId == osmId) return r;
    }
    return null;
  }

  @override
  int get regionCount => _byLevel.length;

  @override
  int get bundleLoadCount => 0;
}

/// Fake WayCandidateSource — returns a fixed list of ways for any bbox.
class _FixedWayCandidateSource implements WayCandidateSource {
  _FixedWayCandidateSource(this.ways);
  final List<WayCandidate> ways;

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
      ways;

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

/// Fake RegionTotalsLookup backed by a fixed map (osm_id string → meters).
/// Null map means "asset absent": all [totalFor] calls return null.
class _FakeRegionTotalsLookup extends RegionTotalsLookup {
  _FakeRegionTotalsLookup([this._totals]);

  final Map<String, double>? _totals;

  @override
  Future<void> ensureLoaded() async {}

  @override
  double? totalFor(String osmId) => _totals?[osmId];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// One AdminRegion covering a tiny bbox around Kleinheubach, level 8.
AdminRegion _regionLevel8({int osmId = 151999}) => AdminRegion(
      osmId: osmId,
      adminLevel: 8,
      name: 'Kleinheubach',
      bboxMinLat: 49.78,
      bboxMinLon: 9.17,
      bboxMaxLat: 49.82,
      bboxMaxLon: 9.22,
      // Simple square polygon; must be a closed ring (first == last), ≥4 pts.
      polygons: const [
        [
          [
            [49.78, 9.17],
            [49.82, 9.17],
            [49.82, 9.22],
            [49.78, 9.22],
            [49.78, 9.17],
          ],
        ],
      ],
    );

/// One AdminRegion at level 2 (Germany). Used to assert level 2 is excluded.
AdminRegion _regionLevel2({int osmId = 51477}) => AdminRegion(
      osmId: osmId,
      adminLevel: 2,
      name: 'Deutschland',
      bboxMinLat: 47,
      bboxMinLon: 5,
      bboxMaxLat: 55.1,
      bboxMaxLon: 15.1,
      polygons: const [
        [
          [
            [47.0, 5.0],
            [55.1, 5.0],
            [55.1, 15.1],
            [47.0, 15.1],
            [47.0, 5.0],
          ],
        ],
      ],
    );

/// Straight 3-point way at ~(49.80, 9.19) — inside `_regionLevel8`.
WayCandidate _fixtureWay({int wayId = 100001}) => WayCandidate(
      wayId: wayId,
      highwayClass: 'residential',
      geometry: const [
        LatLng(49.799, 9.190),
        LatLng(49.800, 9.190),
        LatLng(49.801, 9.190),
      ],
    );

/// Seed a matched trip with a bbox covering Kleinheubach in [db].
Future<int> _seedMatchedTrip(AppDatabase db) async {
  return db.into(db.trips).insert(
        TripsCompanion.insert(
          startedAt: DateTime(2026, 7, 11, 8),
          endedAt: Value(DateTime(2026, 7, 11, 9)),
          durationSeconds: const Value(3600),
          distanceMeters: const Value(5000),
          avgSpeedKmh: const Value(5),
          maxSpeedKmh: const Value(50),
          pointCount: const Value(20),
          bboxMinLat: const Value(49.78),
          bboxMinLon: const Value(9.17),
          bboxMaxLat: const Value(49.82),
          bboxMaxLon: const Value(9.22),
          autoStopped: const Value(false),
          status: const Value(TripStatus.matched),
          manuallyStarted: const Value(true),
        ),
      );
}

/// Seed a driven interval for [wayId] on [tripId] in [db].
Future<void> _seedInterval(
  AppDatabase db, {
  required int tripId,
  required int wayId,
  double startMeters = 0,
  double endMeters = 100,
}) {
  return db.into(db.drivenWayIntervals).insert(
        DrivenWayIntervalsCompanion.insert(
          wayId: wayId,
          tripId: Value(tripId),
          startMeters: startMeters,
          endMeters: endMeters,
          matchedAt: Value(DateTime(2026, 7, 11, 9, 30)),
        ),
      );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late AppDatabase db;
  late TripsDao tripsDao;
  late DrivenWayIntervalsDao intervalsDao;
  late CoverageCacheDao cacheDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tripsDao = TripsDao(db);
    intervalsDao = DrivenWayIntervalsDao(db);
    cacheDao = CoverageCacheDao(db);
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON, journal_mode=WAL).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  // Local helper — no leading underscore (no_leading_underscores_for_local_identifiers).
  //
  // The heavy attribution now runs off-isolate via an injected runner; in these
  // plumbing tests we inject a SYNCHRONOUS closure that attributes the fixture
  // `ways` against `byLevel` directly (same centroid → containsPoint → union
  // logic as the production coverage_attribution.dart, exercised end-to-end in
  // coverage_attribution_test.dart). This keeps these tests focused on the
  // service's Drift read/write plumbing (null-bbox → Ok(0), transactional
  // deleteAll+upsert, realTotal passthrough, Ok(count)).
  CoverageComputeService buildService({
    required Map<int, AdminRegion?> byLevel,
    List<WayCandidate> ways = const [],
    _FakeRegionTotalsLookup? totalsLookup,
  }) {
    final totals = totalsLookup ?? _FakeRegionTotalsLookup();
    final regionsByLevel = <int, List<AdminRegion>>{
      for (final e in byLevel.entries)
        if (e.value != null) e.key: [e.value!],
    };
    return CoverageComputeService(
      intervalsDao: intervalsDao,
      waySource: _FixedWayCandidateSource(ways),
      regionLookup: _FakeAdminRegionLookup(byLevel),
      cacheDao: cacheDao,
      tripsDao: tripsDao,
      totalsLookup: totals,
      compute: (gzippedTiles, tileBboxes, intervalsByWayId) async {
        // Rebuild union length per wayId from the flattened intervals.
        final unionLenByWay = <int, double>{};
        for (final entry in intervalsByWayId.entries) {
          final flat = entry.value;
          var sum = 0.0;
          for (var i = 0; i + 1 < flat.length; i += 2) {
            sum += (flat[i + 1] - flat[i]).abs();
          }
          unionLenByWay[entry.key] = sum;
        }
        final total = <String, double>{};
        final driven = <String, double>{};
        for (final way in ways) {
          if (way.geometry.isEmpty) continue;
          var sumLat = 0.0;
          var sumLon = 0.0;
          for (final p in way.geometry) {
            sumLat += p.latitude;
            sumLon += p.longitude;
          }
          final cLat = sumLat / way.geometry.length;
          final cLon = sumLon / way.geometry.length;
          var wayLen = 0.0;
          for (var i = 0; i < way.geometry.length - 1; i++) {
            wayLen += haversineMeters(
              way.geometry[i].latitude,
              way.geometry[i].longitude,
              way.geometry[i + 1].latitude,
              way.geometry[i + 1].longitude,
            );
          }
          final unionLen = unionLenByWay[way.wayId] ?? 0.0;
          for (final level in kComputeAdminLevels) {
            final region = regionsByLevel[level];
            if (region == null) continue;
            if (!region.first.containsPoint(cLat, cLon)) continue;
            final id = region.first.osmId.toString();
            total[id] = (total[id] ?? 0) + wayLen;
            if (unionLen > 0) driven[id] = (driven[id] ?? 0) + unionLen;
          }
        }
        return {
          for (final id in total.keys)
            id: RegionAccum(
              driven: driven[id] ?? 0,
              total: total[id]!,
              realTotal: totals.totalFor(id),
            ),
        };
      },
    );
  }

  group('CoverageComputeService.recompute', () {
    // -----------------------------------------------------------------------
    // Test 1: Empty DB → Ok(0), cache empty
    // -----------------------------------------------------------------------
    test('empty DB (no trips, no intervals) → Ok(0), getAllWithCoverage empty',
        () async {
      final service = buildService(byLevel: {8: _regionLevel8()});

      final result = await service.recompute();
      expect(result.isOk, isTrue);
      expect(result.when(ok: (v) => v, err: (_) => -1), 0);
      expect(await cacheDao.getAllWithCoverage(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // Test 2: No matched trips → null bbox → Ok(0)
    // -----------------------------------------------------------------------
    test('trips exist but none matched → null bbox → Ok(0), cache cleared',
        () async {
      // Insert a recording-status trip (not matched → not in union bbox).
      await db.into(db.trips).insert(
            TripsCompanion.insert(
              startedAt: DateTime(2026, 7, 11, 8),
              status: const Value(TripStatus.recording),
              manuallyStarted: const Value(true),
            ),
          );
      final service = buildService(byLevel: {8: _regionLevel8()});

      final result = await service.recompute();
      expect(result.when(ok: (v) => v, err: (_) => -1), 0);
    });

    // -----------------------------------------------------------------------
    // Test 3: All regionAt calls return null → Ok(0), no rows written
    // -----------------------------------------------------------------------
    test('regionAt returns null for all levels → Ok(0), no cache rows',
        () async {
      final tripId = await _seedMatchedTrip(db);
      await _seedInterval(db, tripId: tripId, wayId: 100001);
      final service = buildService(
        byLevel: {4: null, 6: null, 8: null, 9: null, 10: null},
        ways: [_fixtureWay()],
      );

      final result = await service.recompute();
      expect(result.when(ok: (v) => v, err: (_) => -1), 0);
      expect(await cacheDao.getAllWithCoverage(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // Test 4: One driven way in a known region → row with both lengths > 0
    // -----------------------------------------------------------------------
    test(
      'one driven way in level-8 region → '
      'totalLengthM > 0, drivenLengthM > 0, '
      'getByRegionId non-null, getAllWithCoverage contains region',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(
          db,
          tripId: tripId,
          wayId: 100001,
          // 100 m driven
        );

        final service = buildService(
          // Provide level-8 region only; other levels return null.
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        final result = await service.recompute();
        expect(result.when(ok: (v) => v, err: (_) => -1), 1);

        final regionId = _regionLevel8().osmId.toString();
        final row = await cacheDao.getByRegionId(regionId);
        expect(row, isNotNull);
        expect(row!.totalLengthM, greaterThan(0));
        expect(row.drivenLengthM, greaterThan(0));
        expect(row.drivenLengthM, lessThanOrEqualTo(row.totalLengthM));

        final allWithCoverage = await cacheDao.getAllWithCoverage();
        expect(
          allWithCoverage.any((r) => r.regionId == regionId),
          isTrue,
        );
      },
    );

    // -----------------------------------------------------------------------
    // Test 5: Un-driven way → total > 0, driven == 0, not in getAllWithCoverage
    // -----------------------------------------------------------------------
    test(
      'un-driven way (no intervals for that wayId) → '
      'totalLengthM > 0, drivenLengthM == 0, not in getAllWithCoverage',
      () async {
        await _seedMatchedTrip(db);
        // No interval seeded for wayId 100001 → driven == 0.

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        final result = await service.recompute();
        // One row written (total > 0), but driven == 0.
        expect(result.when(ok: (v) => v, err: (_) => -1), 1);

        final regionId = _regionLevel8().osmId.toString();
        final row = await cacheDao.getByRegionId(regionId);
        expect(row, isNotNull);
        expect(row!.totalLengthM, greaterThan(0));
        expect(row.drivenLengthM, 0);

        // getAllWithCoverage filters driven > 0.
        expect(await cacheDao.getAllWithCoverage(), isEmpty);
      },
    );

    // -----------------------------------------------------------------------
    // Test 6: Re-population after simulated invalidation
    // -----------------------------------------------------------------------
    test(
      're-population: deleteByRegionIds (simulated invalidator) then '
      'recompute() → row reappears',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        // First recompute — establishes the row.
        await service.recompute();
        final regionId = _regionLevel8().osmId.toString();
        expect(await cacheDao.getByRegionId(regionId), isNotNull);

        // Simulate CoverageInvalidator deleting the row.
        await cacheDao.deleteByRegionIds([regionId]);
        expect(await cacheDao.getByRegionId(regionId), isNull);

        // Second recompute — row must reappear.
        final result2 = await service.recompute();
        expect(result2.when(ok: (v) => v, err: (_) => -1), 1);
        expect(await cacheDao.getByRegionId(regionId), isNotNull);
        expect(
          (await cacheDao.getAllWithCoverage())
              .any((r) => r.regionId == regionId),
          isTrue,
        );
      },
    );

    // -----------------------------------------------------------------------
    // Test 7: Level 2 is never written
    // -----------------------------------------------------------------------
    test(
      'level 2 region is never written, even when regionAt(level=2) returns one',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        // Provide BOTH level-2 and level-8 regions from the fake lookup.
        // The compute service ONLY iterates kComputeAdminLevels = [4,6,8,9,10]
        // which explicitly excludes level 2.
        final l2Region = _regionLevel2();
        final l8Region = _regionLevel8();
        final service = buildService(
          byLevel: {
            2: l2Region, // NOT in kComputeAdminLevels → must never be written
            4: null,
            6: null,
            8: l8Region,
            9: null,
            10: null,
          },
          ways: [_fixtureWay()],
        );

        await service.recompute();

        // Level-2 row must NOT exist.
        expect(
          await cacheDao.getByRegionId(l2Region.osmId.toString()),
          isNull,
        );
        // Level-8 row MUST exist.
        expect(
          await cacheDao.getByRegionId(l8Region.osmId.toString()),
          isNotNull,
        );
      },
    );

    // -----------------------------------------------------------------------
    // Test 8: Bundled real total → real_total_length_m written from lookup
    // -----------------------------------------------------------------------
    test(
      'bundled total available → real_total_length_m written from RegionTotalsLookup',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final regionId = _regionLevel8().osmId.toString(); // '151999'
        const bundledTotal = 62638.0; // realistic Kleinheubach km total

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
          totalsLookup: _FakeRegionTotalsLookup({regionId: bundledTotal}),
        );

        await service.recompute();

        final row = await cacheDao.getByRegionId(regionId);
        expect(row, isNotNull);
        // real_total_length_m must come from the bundled table, not haversine.
        expect(row!.realTotalLengthM, bundledTotal,
            reason: 'real_total_length_m must be the bundled value');
        // haversine total is written separately (backward compat).
        expect(row.totalLengthM, greaterThan(0),
            reason: 'haversine total_length_m still written for backward compat');
      },
    );

    // -----------------------------------------------------------------------
    // Test 9: Missing bundled total → real_total_length_m written as null
    // -----------------------------------------------------------------------
    test(
      'bundled total absent (asset not yet generated) → real_total_length_m null',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
          // Default _FakeRegionTotalsLookup(null) — returns null for all ids.
        );

        await service.recompute();

        final regionId = _regionLevel8().osmId.toString();
        final row = await cacheDao.getByRegionId(regionId);
        expect(row, isNotNull);
        expect(row!.realTotalLengthM, isNull,
            reason: 'null from lookup → real_total_length_m written as null');
        // haversine total still present (backward compat).
        expect(row.totalLengthM, greaterThan(0));
      },
    );

    // -----------------------------------------------------------------------
    // Test 10: recomputeForTrip (incremental path) — single-trip scenario
    //          produces same driven/total lengths as full recompute()
    // -----------------------------------------------------------------------
    test(
      'recomputeForTrip (incremental) produces same driven/total as full recompute for a single trip',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        // Baseline: full recompute.
        await service.recompute();
        final regionId = _regionLevel8().osmId.toString();
        final fullRow = await cacheDao.getByRegionId(regionId);
        expect(fullRow, isNotNull);
        final fullDriven = fullRow!.drivenLengthM;
        final fullTotal = fullRow.totalLengthM;

        // Reset cache so incremental path starts fresh.
        await cacheDao.deleteAll();
        expect(await cacheDao.getByRegionId(regionId), isNull);

        // Incremental recomputeForTrip — should produce the same numbers.
        final result = await service.recomputeForTrip(tripId);
        expect(result.isOk, isTrue);
        expect(result.when(ok: (v) => v, err: (_) => -1), greaterThan(0));

        final incrRow = await cacheDao.getByRegionId(regionId);
        expect(incrRow, isNotNull,
            reason: 'recomputeForTrip must upsert the region row');
        expect(incrRow!.drivenLengthM, closeTo(fullDriven, 0.01),
            reason: 'incremental driven length must equal full recompute');
        expect(incrRow.totalLengthM, closeTo(fullTotal, 0.01),
            reason: 'incremental total length must equal full recompute');
      },
    );

    // -----------------------------------------------------------------------
    // Test 11: recomputeForTrip with no bbox → Ok(0), no rows written
    // -----------------------------------------------------------------------
    test(
      'recomputeForTrip with null bbox → Ok(0), no rows written',
      () async {
        // Trip with no bbox.
        final tripId = await db.into(db.trips).insert(
              TripsCompanion.insert(
                startedAt: DateTime(2026, 7, 17, 8),
                manuallyStarted: const Value(true),
              ),
            );

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        final result = await service.recomputeForTrip(tripId);
        expect(result.when(ok: (v) => v, err: (_) => -1), 0);
        expect(await cacheDao.getAllWithCoverage(), isEmpty);
      },
    );
  });
}
