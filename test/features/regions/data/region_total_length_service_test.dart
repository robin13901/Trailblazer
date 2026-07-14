// Trailblazer 2026-07-14 (region-total resilience + resumability):
// RegionTotalLengthService unit tests — integration-style against an in-memory
// Drift database + a real CoverageCacheDao + a real OverpassClient driven by a
// MockClient so the full HTTP-200-classify gate is exercised.
//
// Focus: a flaky per-cell failure must NEVER discard completed work; a resumed
// run must skip already-summed cells; no exception type may nuke a region.

import 'dart:convert';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_lookup.dart';
import 'package:auto_explore/features/coverage/data/coverage_cache_dao.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:auto_explore/features/regions/data/region_total_length_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Fake lookup that resolves regions by osm id.
class _FakeLookup implements AdminRegionLookup {
  _FakeLookup(AdminRegion region) : _byId = {region.osmId: region};
  _FakeLookup.multi(List<AdminRegion> regions)
      : _byId = {for (final r in regions) r.osmId: r};

  final Map<int, AdminRegion> _byId;

  @override
  Future<void> ensureLoaded() async {}

  @override
  AdminRegion? regionByOsmId(int osmId) => _byId[osmId];

  @override
  Future<AdminRegion?> regionAt(double lat, double lon, int adminLevel) async =>
      null;

  @override
  void invalidate() {}

  @override
  int get regionCount => _byId.length;

  @override
  int get bundleLoadCount => 0;
}

AdminRegion _region({
  required int osmId,
  required double minLat,
  required double minLon,
  required double maxLat,
  required double maxLon,
}) =>
    AdminRegion(
      osmId: osmId,
      adminLevel: 8,
      name: 'Testregion',
      bboxMinLat: minLat,
      bboxMinLon: minLon,
      bboxMaxLat: maxLat,
      bboxMaxLon: maxLon,
      polygons: const [],
    );

http.Response _lengthOk(double meters) => http.Response.bytes(
      utf8.encode(
        '{"version":0.6,"elements":[{"type":"count",'
        '"tags":{"total_m":"$meters"}}]}',
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// A transient "too busy" HTML error served under HTTP 200 (the live bug).
http.Response _busy200() => http.Response(
      '<?xml version="1.0"?><html><body><p>Error: runtime error: '
      'The server is probably too busy.</p></body></html>',
      200,
      headers: {'content-type': 'text/html'},
    );

void main() {
  late AppDatabase db;
  late CoverageCacheDao cacheDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    cacheDao = CoverageCacheDao(db);
  });

  tearDown(() => db.close());

  RegionTotalLengthService buildService(
    Future<http.Response> Function(http.Request) handler,
  ) {
    final region = _region(
      osmId: 42,
      minLat: 49.7,
      minLon: 9.1,
      // Two cells wide × one tall at 0.1° → exactly 2 cells.
      maxLat: 49.79,
      maxLon: 9.29,
    );
    final overpass = OverpassClient(
      client: MockClient(handler),
      backoffBuilder: (_) => Duration.zero,
    );
    return RegionTotalLengthService(
      regionLookup: _FakeLookup(region),
      overpassClient: overpass,
      cacheDao: cacheDao,
    );
  }

  // Seed a coverage_cache row so getRegionsNeedingRealTotal() picks it up.
  Future<void> seedRegion() => cacheDao.upsert(
        regionId: '42',
        drivenLengthM: 100,
        totalLengthM: 200,
        updatedAt: DateTime(2026, 7, 14),
      );

  test('all cells succeed → real total == sum, progress cleared', () async {
    await seedRegion();
    final service = buildService((req) async => _lengthOk(1000));

    final done = await service.computeMissingTotals();

    expect(done, 1);
    final row = await cacheDao.getByRegionId('42');
    expect(row!.realTotalLengthM, 2000); // 2 cells × 1000 m
    expect(row.realTotalProgressJson, isNull); // accumulator cleared
  });

  test('one flaky cell first pass → region pending, partial progress kept',
      () async {
    await seedRegion();
    // Cell A is the only cell whose minLon is exactly the region minLon (9.1) —
    // a loop start value, never a float-computed edge. Everything else is cell
    // B, which always errors under 200 (burning its retry+fallback attempts).
    final service = buildService((req) async {
      final isCellA = req.body.contains('9.1');
      if (isCellA) return _lengthOk(1500);
      return _busy200();
    });

    final done = await service.computeMissingTotals();

    expect(done, 0, reason: 'region not complete → not counted as done');
    final row = await cacheDao.getByRegionId('42');
    expect(row!.realTotalLengthM, isNull, reason: 'no final total written');
    expect(row.realTotalProgressJson, isNotNull,
        reason: 'partial progress persisted for resume');
    expect(row.realTotalProgressJson, contains('1500'),
        reason: 'the succeeded cell is recorded');
  });

  test('resume: only the previously-failed cell is refetched, total completes',
      () async {
    await seedRegion();

    // Pass 1: cell B fails.
    var failB = true;
    final calls = <String>[];
    final service = buildService((req) async {
      calls.add(req.body);
      final isCellA = req.body.contains('9.1');
      if (!isCellA && failB) return _busy200();
      return _lengthOk(1500);
    });
    await service.computeMissingTotals();

    // Pass 2: cell B now succeeds. Count only the fresh cell-length queries.
    calls.clear();
    failB = false;
    final done = await service.computeMissingTotals();

    expect(done, 1, reason: 'region now completes');
    final row = await cacheDao.getByRegionId('42');
    expect(row!.realTotalLengthM, 3000); // both cells × 1500
    expect(row.realTotalProgressJson, isNull);
    // The already-summed cell A must NOT be refetched on the resume — only
    // cell B (the previously-failed one) is queried in pass 2.
    final refetchedCellA = calls.where((b) => b.contains('9.1')).length;
    expect(refetchedCellA, 0,
        reason: 'already-summed cell A must not be refetched on resume');
  });

  test('non-network throwable per cell is swallowed — region not nuked',
      () async {
    await seedRegion();
    // Return a 200 body that passes the classify gate (looks like clean JSON)
    // but is structurally junk → _parseTotalMeters returns 0 (no throw). To
    // force a throwable we instead make the mock throw a raw error, which the
    // client wraps; the service's broad catch must swallow it → region pending,
    // NOT an uncaught exception.
    final service = buildService((req) async {
      throw const FormatException('boom from transport');
    });

    // Must not throw.
    final done = await service.computeMissingTotals();
    expect(done, 0);
    final row = await cacheDao.getByRegionId('42');
    expect(row!.realTotalLengthM, isNull);
  });

  test('computes SMALLEST region first (fewest cells)', () async {
    // Big region (osmId 100, ~1° box → many cells) + tiny region (osmId 7,
    // one cell). Both pending. The tiny one must be queried first.
    final big = _region(
      osmId: 100,
      minLat: 48,
      minLon: 8,
      maxLat: 49,
      maxLon: 9,
    );
    final tiny = _region(
      osmId: 7,
      minLat: 49.70,
      minLon: 9.10,
      maxLat: 49.72,
      maxLon: 9.12,
    );
    await cacheDao.upsert(
      regionId: '100',
      drivenLengthM: 100,
      totalLengthM: 200,
      updatedAt: DateTime(2026, 7, 14),
    );
    await cacheDao.upsert(
      regionId: '7',
      drivenLengthM: 100,
      totalLengthM: 200,
      updatedAt: DateTime(2026, 7, 14),
    );

    // Record the area id (3600000000 + osmId) of the FIRST cell query.
    final areaOrder = <int>[];
    final overpass = OverpassClient(
      client: MockClient((req) async {
        final body = req.body;
        // area:3600000007 (tiny) vs area:3600000100 (big).
        final isTiny = body.contains('3600000007');
        final id = isTiny ? 7 : 100;
        if (areaOrder.isEmpty || areaOrder.last != id) areaOrder.add(id);
        return _lengthOk(500);
      }),
      backoffBuilder: (_) => Duration.zero,
    );
    final service = RegionTotalLengthService(
      regionLookup: _FakeLookup.multi([big, tiny]),
      overpassClient: overpass,
      cacheDao: cacheDao,
    );

    await service.computeMissingTotals();

    expect(areaOrder.first, 7,
        reason: 'the 1-cell region must be computed before the big one');
  });
}
