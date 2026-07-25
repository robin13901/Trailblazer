// Trailblazer coverage recompute service tests — integration-style against an
// in-memory Drift database + fake collaborators.
//
// 2026-07-25 DURABLE CLIP-PER-REGION REWORK (#7): recompute() is now two-stage.
// These tests inject the REAL STAGE-1 clip (computeCoverageAttribution) as the
// off-isolate runner over a fake WayCandidateSource that returns a gzipped tile,
// and assert the STAGE-2 DB aggregation writes the correct driven/total lengths.
//
// Test inventory:
//  1. Empty DB (no intervals, null bbox) → recompute() == Ok(0), cache empty.
//  2. Trips exist but none matched → null bbox → Ok(0).
//  3. No matching admin region → Ok(0), no rows written.
//  4. One driven way inside a region → row with totalLengthM > 0 AND
//     drivenLengthM > 0 (overlap of the driven interval with the in-region range).
//  5. Un-driven way in region → totalLengthM > 0 but drivenLengthM == 0.
//  6. Re-population after simulated invalidation → row reappears (attribution
//     rows are durable; STAGE-1 is skipped, STAGE-2 rebuilds).
//  7. Level 2 is never written.
//  8. Bundled real total written from RegionTotalsLookup.
//  9. Missing bundled total → real_total_length_m null.
// 10. recomputeForTrip (incremental centroid path) — same numbers for a single
//     trip.
// 11. recomputeForTrip with null bbox → Ok(0).
// 12. Monotonic clip: driven interval covering only ONE region's range credits
//     only that region (boundary-crossing way, no double count).
// 13. Eviction-proof: attribution rows present but tile cache empty → coverage
//     still computed from durable rows.

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/db/daos/way_region_attribution_dao.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/regions/data/coverage_attribution.dart';
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
class _FakeAdminRegionLookup implements AdminRegionLookup {
  _FakeAdminRegionLookup(this._byLevel);

  final Map<int, AdminRegion?> _byLevel;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async =>
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

/// Gzip a single-tile Overpass envelope wrapping [ways].
Uint8List _gzTile(List<WayCandidate> ways) {
  final env = {
    'version': 0.6,
    'elements': [
      for (final w in ways)
        {
          'type': 'way',
          'id': w.wayId,
          'geometry': [
            for (final p in w.geometry) {'lat': p.latitude, 'lon': p.longitude},
          ],
          'tags': {'highway': w.highwayClass},
        },
    ],
  };
  return Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(env))));
}

/// Fake WayCandidateSource — returns a fixed way list. Its raw-tiles path
/// gzips those ways into one tile (so STAGE-1 clip runs) unless [emptyRawTiles]
/// is set (to exercise the eviction-proof STAGE-2-only path).
class _FixedWayCandidateSource implements WayCandidateSource {
  _FixedWayCandidateSource(this.ways, {this.emptyRawTiles = false});
  final List<WayCandidate> ways;
  final bool emptyRawTiles;

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
  }) async {
    if (emptyRawTiles || ways.isEmpty) return const [];
    return [
      RawTilePayload(
        payloadGzip: _gzTile(ways),
        bbox: LatLonBbox(
          minLat: minLat,
          minLon: minLon,
          maxLat: maxLat,
          maxLon: maxLon,
        ),
      ),
    ];
  }
}

/// Fake RegionTotalsLookup backed by a fixed map (osm_id string → meters).
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

/// Straight 3-point way at ~(49.80, 9.19) — inside `_regionLevel8`. Length
/// ~222 m (0.002° lat).
WayCandidate _fixtureWay({int wayId = 100001}) => WayCandidate(
      wayId: wayId,
      highwayClass: 'residential',
      geometry: const [
        LatLng(49.799, 9.190),
        LatLng(49.800, 9.190),
        LatLng(49.801, 9.190),
      ],
    );

double _wayLen(WayCandidate w) {
  final g = w.geometry;
  var total = 0.0;
  for (var i = 0; i < g.length - 1; i++) {
    total += haversineMeters(
        g[i].latitude, g[i].longitude, g[i + 1].latitude, g[i + 1].longitude);
  }
  return total;
}

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
  late WayRegionAttributionDao attributionDao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tripsDao = TripsDao(db);
    intervalsDao = DrivenWayIntervalsDao(db);
    cacheDao = CoverageCacheDao(db);
    attributionDao = WayRegionAttributionDao(db);
    // Trigger beforeOpen PRAGMAs (foreign_keys=ON, journal_mode=WAL).
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await db.close();
  });

  // Builds a service whose off-isolate STAGE-1 runner is the REAL clip
  // (computeCoverageAttribution) over the provided regionsByLevel. STAGE-2 (DB
  // aggregation) runs unchanged inside the service.
  CoverageComputeService buildService({
    required Map<int, AdminRegion?> byLevel,
    List<WayCandidate> ways = const [],
    _FakeRegionTotalsLookup? totalsLookup,
    bool emptyRawTiles = false,
  }) {
    final totals = totalsLookup ?? _FakeRegionTotalsLookup();
    final regionsByLevel = <int, List<AdminRegion>>{
      for (final e in byLevel.entries)
        if (e.value != null) e.key: [e.value!],
    };
    return CoverageComputeService(
      intervalsDao: intervalsDao,
      waySource: _FixedWayCandidateSource(ways, emptyRawTiles: emptyRawTiles),
      regionLookup: _FakeAdminRegionLookup(byLevel),
      cacheDao: cacheDao,
      tripsDao: tripsDao,
      totalsLookup: totals,
      attributionDao: attributionDao,
      compute: (gzippedTiles, tileBboxes, alreadyAttributedWayIds) async =>
          computeCoverageAttribution(
        regionsByLevel: regionsByLevel,
        gzippedTiles: gzippedTiles,
        tileBboxes: tileBboxes,
        alreadyAttributedWayIds: alreadyAttributedWayIds,
      ),
    );
  }

  group('CoverageComputeService.recompute', () {
    test('empty DB (no trips, no intervals) → Ok(0), getAllWithCoverage empty',
        () async {
      final service = buildService(byLevel: {8: _regionLevel8()});

      final result = await service.recompute();
      expect(result.isOk, isTrue);
      expect(result.when(ok: (v) => v, err: (_) => -1), 0);
      expect(await cacheDao.getAllWithCoverage(), isEmpty);
    });

    test('trips exist but none matched → null bbox → Ok(0), cache cleared',
        () async {
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

    test(
      'one driven way in level-8 region → totalLengthM > 0, drivenLengthM > 0',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final service = buildService(
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
        // Driven == overlap([0,100], [0, wayLen]) == 100 m.
        expect(row.drivenLengthM, closeTo(100, 0.5));

        final allWithCoverage = await cacheDao.getAllWithCoverage();
        expect(allWithCoverage.any((r) => r.regionId == regionId), isTrue);
      },
    );

    test(
      'un-driven way → totalLengthM > 0, drivenLengthM == 0, not in coverage',
      () async {
        await _seedMatchedTrip(db);
        // No interval seeded for wayId 100001 → driven == 0.

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        final result = await service.recompute();
        expect(result.when(ok: (v) => v, err: (_) => -1), 1);

        final regionId = _regionLevel8().osmId.toString();
        final row = await cacheDao.getByRegionId(regionId);
        expect(row, isNotNull);
        expect(row!.totalLengthM, greaterThan(0));
        expect(row.drivenLengthM, 0);

        expect(await cacheDao.getAllWithCoverage(), isEmpty);
      },
    );

    test(
      're-population: deleteByRegionIds then recompute() → row reappears '
      '(attribution rows durable)',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        await service.recompute();
        final regionId = _regionLevel8().osmId.toString();
        expect(await cacheDao.getByRegionId(regionId), isNotNull);
        // Attribution row persisted.
        expect(await attributionDao.getAllRows(), isNotEmpty);

        await cacheDao.deleteByRegionIds([regionId]);
        expect(await cacheDao.getByRegionId(regionId), isNull);

        final result2 = await service.recompute();
        expect(result2.when(ok: (v) => v, err: (_) => -1), 1);
        expect(await cacheDao.getByRegionId(regionId), isNotNull);
      },
    );

    test('level 2 region is never written', () async {
      final tripId = await _seedMatchedTrip(db);
      await _seedInterval(db, tripId: tripId, wayId: 100001);

      final l2Region = _regionLevel2();
      final l8Region = _regionLevel8();
      final service = buildService(
        byLevel: {2: l2Region, 4: null, 6: null, 8: l8Region, 9: null, 10: null},
        ways: [_fixtureWay()],
      );

      await service.recompute();

      expect(await cacheDao.getByRegionId(l2Region.osmId.toString()), isNull);
      expect(await cacheDao.getByRegionId(l8Region.osmId.toString()), isNotNull);
    });

    test('bundled total → real_total_length_m written from RegionTotalsLookup',
        () async {
      final tripId = await _seedMatchedTrip(db);
      await _seedInterval(db, tripId: tripId, wayId: 100001);

      final regionId = _regionLevel8().osmId.toString();
      const bundledTotal = 62638.0;

      final service = buildService(
        byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
        ways: [_fixtureWay()],
        totalsLookup: _FakeRegionTotalsLookup({regionId: bundledTotal}),
      );

      await service.recompute();

      final row = await cacheDao.getByRegionId(regionId);
      expect(row, isNotNull);
      expect(row!.realTotalLengthM, bundledTotal);
      expect(row.totalLengthM, greaterThan(0));
    });

    test('bundled total absent → real_total_length_m null', () async {
      final tripId = await _seedMatchedTrip(db);
      await _seedInterval(db, tripId: tripId, wayId: 100001);

      final service = buildService(
        byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
        ways: [_fixtureWay()],
      );

      await service.recompute();

      final regionId = _regionLevel8().osmId.toString();
      final row = await cacheDao.getByRegionId(regionId);
      expect(row, isNotNull);
      expect(row!.realTotalLengthM, isNull);
      expect(row.totalLengthM, greaterThan(0));
    });

    // -----------------------------------------------------------------------
    // (b) Monotonic clip: an interval covering only ONE region's range credits
    //     only that region — a boundary-crossing way, no double count.
    // -----------------------------------------------------------------------
    test(
      'boundary-crossing way: interval in region A only credits A, not B',
      () async {
        // Two level-8 regions split at lon 9.195.
        const west = AdminRegion(
          osmId: 111,
          adminLevel: 8,
          name: 'West',
          bboxMinLat: 49.78,
          bboxMinLon: 9.17,
          bboxMaxLat: 49.82,
          bboxMaxLon: 9.195,
          polygons: [
            [
              [
                [49.78, 9.17],
                [49.82, 9.17],
                [49.82, 9.195],
                [49.78, 9.195],
                [49.78, 9.17],
              ],
            ],
          ],
        );
        const east = AdminRegion(
          osmId: 222,
          adminLevel: 8,
          name: 'East',
          bboxMinLat: 49.78,
          bboxMinLon: 9.195,
          bboxMaxLat: 49.82,
          bboxMaxLon: 9.22,
          polygons: [
            [
              [
                [49.78, 9.195],
                [49.82, 9.195],
                [49.82, 9.22],
                [49.78, 9.22],
                [49.78, 9.195],
              ],
            ],
          ],
        );
        // Horizontal way crossing the boundary.
        const way = WayCandidate(
          wayId: 500,
          highwayClass: 'residential',
          geometry: [
            LatLng(49.80, 9.180),
            LatLng(49.80, 9.190),
            LatLng(49.80, 9.200),
            LatLng(49.80, 9.210),
          ],
        );

        final tripId = await _seedMatchedTrip(db);
        // Drive ONLY the first 200 m — falls in the WEST region's range.
        await _seedInterval(
          db,
          tripId: tripId,
          wayId: 500,
          endMeters: 200,
        );

        // Multi-level fake: return west OR east by level probe not needed;
        // regionsByLevel holds both at level 8 (clip picks by midpoint).
        final service = CoverageComputeService(
          intervalsDao: intervalsDao,
          waySource: _FixedWayCandidateSource([way]),
          regionLookup: _FakeAdminRegionLookup(const {}),
          cacheDao: cacheDao,
          tripsDao: tripsDao,
          totalsLookup: _FakeRegionTotalsLookup(),
          attributionDao: attributionDao,
          compute: (gz, bboxes, already) async => computeCoverageAttribution(
            regionsByLevel: {
              8: [west, east],
            },
            gzippedTiles: gz,
            tileBboxes: bboxes,
            alreadyAttributedWayIds: already,
          ),
        );

        await service.recompute();

        final wRow = await cacheDao.getByRegionId('111');
        final eRow = await cacheDao.getByRegionId('222');
        expect(wRow, isNotNull);
        expect(eRow, isNotNull);
        // West credited (driven interval [0,200] falls in its range); East not.
        expect(wRow!.drivenLengthM, greaterThan(0));
        expect(eRow!.drivenLengthM, 0,
            reason: 'the driven half does not spill into region B');
        // Totals split the way length across both regions (no double count).
        expect(
          wRow.totalLengthM + eRow.totalLengthM,
          closeTo(_wayLen(way), 1.0),
        );
      },
    );

    // -----------------------------------------------------------------------
    // (d) Eviction-proof: attribution rows already present but the tile cache
    //     is empty → coverage is still computed from the durable rows.
    // -----------------------------------------------------------------------
    test(
      'eviction-proof: attribution rows present, empty tile cache → still '
      'computes coverage from durable rows',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final regionId = _regionLevel8().osmId.toString();
        final wayLen = _wayLen(_fixtureWay());
        // Pre-seed a durable attribution row (simulating a prior STAGE-1 pass).
        await attributionDao.upsertBatch([
          WayRegionAttributionCompanion.insert(
            wayId: 100001,
            regionId: regionId,
            adminLevel: 8,
            rangeStartM: 0,
            rangeEndM: wayLen,
          ),
        ]);

        // Tile cache is EMPTY (emptyRawTiles) → STAGE-1 is skipped entirely.
        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
          emptyRawTiles: true,
        );

        final result = await service.recompute();
        expect(result.when(ok: (v) => v, err: (_) => -1), 1);

        final row = await cacheDao.getByRegionId(regionId);
        expect(row, isNotNull);
        expect(row!.totalLengthM, closeTo(wayLen, 0.01));
        expect(row.drivenLengthM, closeTo(100, 0.5),
            reason: 'driven from overlap of [0,100] with [0, wayLen]');
      },
    );

    // -----------------------------------------------------------------------
    // recomputeForTrip (incremental centroid path) — single trip
    // -----------------------------------------------------------------------
    test(
      'recomputeForTrip (incremental) produces same driven/total as full '
      'recompute for a single trip',
      () async {
        final tripId = await _seedMatchedTrip(db);
        await _seedInterval(db, tripId: tripId, wayId: 100001);

        final service = buildService(
          byLevel: {4: null, 6: null, 8: _regionLevel8(), 9: null, 10: null},
          ways: [_fixtureWay()],
        );

        await service.recompute();
        final regionId = _regionLevel8().osmId.toString();
        final fullRow = await cacheDao.getByRegionId(regionId);
        expect(fullRow, isNotNull);
        final fullDriven = fullRow!.drivenLengthM;
        final fullTotal = fullRow.totalLengthM;

        await cacheDao.deleteAll();
        expect(await cacheDao.getByRegionId(regionId), isNull);

        final result = await service.recomputeForTrip(tripId);
        expect(result.isOk, isTrue);
        expect(result.when(ok: (v) => v, err: (_) => -1), greaterThan(0));

        final incrRow = await cacheDao.getByRegionId(regionId);
        expect(incrRow, isNotNull);
        expect(incrRow!.drivenLengthM, closeTo(fullDriven, 0.01));
        expect(incrRow.totalLengthM, closeTo(fullTotal, 0.01));
      },
    );

    test('recomputeForTrip with null bbox → Ok(0), no rows written', () async {
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
    });
  });
}
