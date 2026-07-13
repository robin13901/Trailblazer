// Phase 9 (Plan 09-06): Unit tests for OverpassWayCandidateSource cache
// hit/miss counters.
//
// Reuses the same in-memory DB scaffolding as
// test/features/matching/overpass_way_candidate_source_test.dart (real Drift
// NativeDatabase.memory() + real OverpassWayCacheDao).
//
// Scenarios:
//   1. Fresh instance reports cacheHitRate == null (no calls yet).
//   2. All-cache-hit fetch: cacheHits > 0, cacheMisses == 0, rate == 1.0.
//   3. All-miss fetch:  cacheMisses > 0, cacheHits == 0, rate == 0.0.
//   4. Mixed hit+miss fetch: both > 0, rate in (0, 1).

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/overpass_way_cache_dao.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:auto_explore/features/matching/data/overpass_way_candidate_source.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ─── helpers (mirrors overpass_way_candidate_source_test.dart) ──────────────

String _syntheticJson({required int wayId, required double lat, required double lon}) {
  return jsonEncode({
    'version': 0.6,
    'generator': 'test',
    'elements': [
      {
        'type': 'way',
        'id': wayId,
        'geometry': [
          {'lat': lat, 'lon': lon},
          {'lat': lat + 0.00001, 'lon': lon + 0.00001},
        ],
        'tags': {'highway': 'residential'},
      },
    ],
  });
}

http.Response _okJson(String body) => http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Uint8List _gzipUtf8(String s) =>
    Uint8List.fromList(gzip.encode(utf8.encode(s)));

OverpassClient _stubClient(MockClientHandler handler) {
  return OverpassClient(
    client: MockClient(handler),
    primaryEndpoint: Uri.parse('https://primary.test/api/interpreter'),
    fallbackEndpoint: Uri.parse('https://fallback.test/api/interpreter'),
    backoffBuilder: (_) => Duration.zero,
    requestTimeout: const Duration(seconds: 30),
  );
}

// Bbox centred on Berlin-Kreuzberg (single z12 tile).
const _lat = 52.4995;
const _lon = 13.4035;
const _half = 0.001;

// ─── tests ───────────────────────────────────────────────────────────────────

void main() {
  late AppDatabase db;
  late OverpassWayCacheDao cacheDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    cacheDao = OverpassWayCacheDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('OverpassWayCandidateSource cache counters', () {
    test('fresh instance has null cacheHitRate before any call', () {
      final source = OverpassWayCandidateSource(
        client: _stubClient((_) async => fail('should not be called')),
        cacheDao: cacheDao,
      );
      expect(source.cacheHits, 0);
      expect(source.cacheMisses, 0);
      expect(source.cacheHitRate, isNull);
    });

    test('all-cache-hit: cacheHits > 0, cacheMisses == 0, rate == 1.0',
        () async {
      const tileMath = TileBboxMath();
      // Seed every tile that the bbox touches.
      final tiles = tileMath.bboxToZ12Tiles(
        _lat - _half,
        _lon - _half,
        _lat + _half,
        _lon + _half,
      );
      for (final t in tiles) {
        await cacheDao.put(
          z: t.z,
          x: t.x,
          y: t.y,
          payloadGzip:
              _gzipUtf8(_syntheticJson(wayId: t.x, lat: _lat, lon: _lon)),
          wayCount: 1,
        );
      }

      final source = OverpassWayCandidateSource(
        client: _stubClient((_) async {
          fail('network should not be hit — everything is pre-cached');
        }),
        cacheDao: cacheDao,
      );

      await source.fetchWaysInBbox(
        minLat: _lat - _half,
        minLon: _lon - _half,
        maxLat: _lat + _half,
        maxLon: _lon + _half,
      );

      expect(source.cacheHits, greaterThan(0));
      expect(source.cacheMisses, 0);
      expect(source.cacheHitRate, 1.0);
    });

    test('all-miss: cacheMisses > 0, cacheHits == 0, rate == 0.0', () async {
      // Cache is empty — every tile is a miss and must be fetched.
      var fetchCalls = 0;
      final source = OverpassWayCandidateSource(
        client: _stubClient((req) async {
          fetchCalls++;
          return _okJson(_syntheticJson(wayId: fetchCalls, lat: _lat, lon: _lon));
        }),
        cacheDao: cacheDao,
      );

      await source.fetchWaysInBbox(
        minLat: _lat - _half,
        minLon: _lon - _half,
        maxLat: _lat + _half,
        maxLon: _lon + _half,
      );

      expect(source.cacheMisses, greaterThan(0));
      expect(source.cacheHits, 0);
      expect(source.cacheHitRate, 0.0);
    });

    test('mixed hit+miss: both counters > 0, rate in (0, 1)', () async {
      // Use a bbox spanning at least 2 tiles so we can seed one tile and
      // leave the other(s) empty.
      const tileMath = TileBboxMath();
      const bigHalf = 0.1; // lon span that typically crosses a tile boundary
      final tiles = tileMath.bboxToZ12Tiles(
        _lat - _half,
        _lon - bigHalf,
        _lat + _half,
        _lon + bigHalf,
      );
      // Seed only the first tile; the rest will be network misses.
      final firstTile = tiles.first;
      await cacheDao.put(
        z: firstTile.z,
        x: firstTile.x,
        y: firstTile.y,
        payloadGzip: _gzipUtf8(
          _syntheticJson(wayId: firstTile.x, lat: _lat, lon: _lon),
        ),
        wayCount: 1,
      );

      var fetchCalls = 0;
      final source = OverpassWayCandidateSource(
        client: _stubClient((req) async {
          fetchCalls++;
          return _okJson(
            _syntheticJson(wayId: 9000 + fetchCalls, lat: _lat, lon: _lon),
          );
        }),
        cacheDao: cacheDao,
      );

      await source.fetchWaysInBbox(
        minLat: _lat - _half,
        minLon: _lon - bigHalf,
        maxLat: _lat + _half,
        maxLon: _lon + bigHalf,
      );

      // Guard: test is only valid if both counters are non-zero.
      // If the bbox fell into a single tile the hit+miss combo won't occur;
      // skip rather than fail with a misleading assertion.
      if (tiles.length < 2) {
        // Document: bbox didn't span 2 tiles — mixed-counter assertion skipped.
        return;
      }

      expect(source.cacheHits, greaterThan(0), reason: 'first tile was pre-seeded');
      expect(source.cacheMisses, greaterThan(0), reason: 'remaining tiles needed fetch');
      final rate = source.cacheHitRate;
      expect(rate, isNotNull);
      expect(rate, greaterThan(0.0));
      expect(rate, lessThan(1.0));
    });
  });
}
