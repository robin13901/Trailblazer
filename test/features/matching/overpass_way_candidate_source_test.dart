// Phase 4 rescope Wave 2 (Plan 04-15):
// Unit tests for [OverpassWayCandidateSource].
//
// Wires:
//   * a real in-memory `AppDatabase` + real `OverpassWayCacheDao`
//   * a real `OverpassClient` whose `http.Client` is `MockClient`, returning
//     a controlled Overpass JSON payload
//
// End-to-end validates cache-first read, TTL-based refetch, per-tile
// coverage across a 2-tile bbox, dedup across overlapping tiles, and the
// `throwOnError: false` partial-result path.

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

/// Overpass JSON envelope with a single way at ([lat], [lon]).
String syntheticOverpassJson({
  required int wayId,
  required double lat,
  required double lon,
  String highway = 'primary',
  String? name,
}) {
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
        'tags': {
          'highway': highway,
          'name': ?name,
        },
      },
    ],
  });
}

http.Response okJson(String body) => http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Uint8List gzipUtf8(String s) =>
    Uint8List.fromList(gzip.encode(utf8.encode(s)));

void main() {
  const tileMath = TileBboxMath();

  // Berlin-Kreuzberg centre.
  const centreLat = 52.4995;
  const centreLon = 13.4035;
  const smallHalfLat = 0.001;
  const smallHalfLon = 0.001;

  late AppDatabase db;
  late OverpassWayCacheDao cacheDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    cacheDao = OverpassWayCacheDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  OverpassClient buildClient(MockClientHandler handler) {
    return OverpassClient(
      client: MockClient(handler),
      primaryEndpoint: Uri.parse('https://primary.test/api/interpreter'),
      fallbackEndpoint: Uri.parse('https://fallback.test/api/interpreter'),
      backoffBuilder: (_) => Duration.zero,
      requestTimeout: const Duration(seconds: 30),
    );
  }

  group('OverpassWayCandidateSource', () {
    test('first fetch hits network and writes cache', () async {
      var calls = 0;
      final client = buildClient((req) async {
        calls++;
        return okJson(syntheticOverpassJson(
          wayId: 1,
          lat: centreLat,
          lon: centreLon,
        ));
      });
      final source = OverpassWayCandidateSource(
        client: client,
        cacheDao: cacheDao,
      );

      final ways = await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - smallHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + smallHalfLon,
      );

      expect(ways, hasLength(1));
      expect(ways.first.wayId, 1);
      expect(calls, 1);
      expect(await cacheDao.totalBytes(), greaterThan(0));
    });

    test('second fetch for same bbox hits cache only', () async {
      var calls = 0;
      final client = buildClient((req) async {
        calls++;
        return okJson(syntheticOverpassJson(
          wayId: 1,
          lat: centreLat,
          lon: centreLon,
        ));
      });
      final source = OverpassWayCandidateSource(
        client: client,
        cacheDao: cacheDao,
      );

      await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - smallHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + smallHalfLon,
      );
      final again = await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - smallHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + smallHalfLon,
      );
      expect(again, hasLength(1));
      expect(calls, 1, reason: 'second call must be cache-only');
    });

    test('TTL-expired cache row triggers refetch', () async {
      var calls = 0;
      final client = buildClient((req) async {
        calls++;
        return okJson(syntheticOverpassJson(
          wayId: 1,
          lat: centreLat,
          lon: centreLon,
        ));
      });
      var fakeNow = DateTime(2026);
      final source = OverpassWayCandidateSource(
        client: client,
        cacheDao: cacheDao,
        now: () => fakeNow,
      );

      await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - smallHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + smallHalfLon,
      );
      expect(calls, 1);

      fakeNow = fakeNow.add(const Duration(days: 31));
      await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - smallHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + smallHalfLon,
      );
      expect(calls, 2, reason: 'TTL-expired row forces a refetch');
    });

    test('bbox spanning multiple tiles caches all tiles', () async {
      // Pick a longitude span that crosses a z12 tile boundary at Berlin.
      const bigHalfLon = 0.1;
      final tiles = tileMath.bboxToZ12Tiles(
        centreLat - smallHalfLat,
        centreLon - bigHalfLon,
        centreLat + smallHalfLat,
        centreLon + bigHalfLon,
      );
      expect(
        tiles.length,
        greaterThanOrEqualTo(2),
        reason: 'test precondition — bbox must span >= 2 tiles',
      );

      var wayIdCounter = 100;
      final client = buildClient((req) async {
        final id = wayIdCounter++;
        return okJson(syntheticOverpassJson(
          wayId: id,
          lat: centreLat,
          lon: centreLon,
        ));
      });
      final source = OverpassWayCandidateSource(
        client: client,
        cacheDao: cacheDao,
      );

      await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - bigHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + bigHalfLon,
      );

      var cachedTiles = 0;
      for (final t in tiles) {
        final row = await cacheDao.getByTile(t.z, t.x, t.y);
        if (row != null) cachedTiles++;
      }
      expect(cachedTiles, tiles.length);
    });

    test('restrictTiles fetches ONLY the corridor tiles, not the whole bbox',
        () async {
      // Multi-tile bbox, but restrict to a single tile → only that tile should
      // hit the network and be cached (the corridor-fetch win).
      const bigHalfLon = 0.1;
      final bboxTiles = tileMath.bboxToZ12Tiles(
        centreLat - smallHalfLat,
        centreLon - bigHalfLon,
        centreLat + smallHalfLat,
        centreLon + bigHalfLon,
      );
      expect(bboxTiles.length, greaterThanOrEqualTo(2));
      // The centre tile — one of the bbox tiles — is our corridor.
      final centreTile = TileId(
        12,
        tileMath.lonToTileX(centreLon, 12),
        tileMath.latToTileY(centreLat, 12),
      );
      expect(bboxTiles, contains(centreTile));

      var calls = 0;
      var wayIdCounter = 200;
      final client = buildClient((req) async {
        calls++;
        return okJson(syntheticOverpassJson(
          wayId: wayIdCounter++,
          lat: centreLat,
          lon: centreLon,
        ));
      });
      final source = OverpassWayCandidateSource(
        client: client,
        cacheDao: cacheDao,
      );

      final progress = <(int, int)>[];
      await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - bigHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + bigHalfLon,
        restrictTiles: {centreTile},
        onTileProgress: (done, total) => progress.add((done, total)),
      );

      expect(calls, 1, reason: 'only the single corridor tile is fetched');
      // Only the centre tile cached; the others were never requested.
      for (final t in bboxTiles) {
        final row = await cacheDao.getByTile(t.z, t.x, t.y);
        if (t == centreTile) {
          expect(row, isNotNull);
        } else {
          expect(row, isNull, reason: 'non-corridor tile must not be fetched');
        }
      }
      // Progress reported over the restricted total (1), ending at 1/1.
      expect(progress.last, (1, 1));
    });

    test('overlapping tiles do not double-count the same wayId', () async {
      // Seed two neighbouring cache rows that both contain wayId=42.
      final tiles = tileMath
          .bboxToZ12Tiles(
            centreLat - smallHalfLat,
            centreLon - 0.1,
            centreLat + smallHalfLat,
            centreLon + 0.1,
          )
          .toList();
      expect(tiles.length, greaterThanOrEqualTo(2));

      for (final t in tiles) {
        // Way geometry point sits inside the caller bbox so bbox-clip keeps
        // it after dedup runs.
        final payload = syntheticOverpassJson(
          wayId: 42,
          lat: centreLat,
          lon: centreLon,
          name: 'Cross-tile',
        );
        await cacheDao.put(
          z: t.z,
          x: t.x,
          y: t.y,
          payloadGzip: gzipUtf8(payload),
          wayCount: 1,
        );
      }

      final client = buildClient((req) async {
        fail('network should NOT be hit — everything is pre-cached');
      });
      final source = OverpassWayCandidateSource(
        client: client,
        cacheDao: cacheDao,
      );

      final ways = await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - 0.1,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + 0.1,
      );
      expect(ways.where((w) => w.wayId == 42), hasLength(1));
    });

    test('throwOnError: false returns partial result on network error',
        () async {
      final client = buildClient((req) async {
        return http.Response('kaboom', 500);
      });
      final source = OverpassWayCandidateSource(
        client: client,
        cacheDao: cacheDao,
      );

      final ways = await source.fetchWaysInBbox(
        minLat: centreLat - smallHalfLat,
        minLon: centreLon - smallHalfLon,
        maxLat: centreLat + smallHalfLat,
        maxLon: centreLon + smallHalfLon,
        throwOnError: false,
      );
      expect(ways, isEmpty);
    });

    test(
      'cacheOnly: never hits network for uncached tiles (returns empty, '
      '0 calls) — the coverage-recompute/overlay hang fix (2026-07-21)',
      () async {
        var calls = 0;
        final client = buildClient((req) async {
          calls++;
          return okJson(syntheticOverpassJson(
            wayId: 1,
            lat: centreLat,
            lon: centreLon,
          ));
        });
        final source = OverpassWayCandidateSource(
          client: client,
          cacheDao: cacheDao,
        );

        // Cache is empty and cacheOnly suppresses the fetch-missing step, so
        // the wide (many-tile) bbox resolves to nothing WITHOUT any network
        // call — this is what keeps recompute()/overlay from hanging on the
        // off-corridor tiles of a long trip's union bbox.
        final ways = await source.fetchWaysInBbox(
          minLat: centreLat - 0.1,
          minLon: centreLon - 0.1,
          maxLat: centreLat + 0.1,
          maxLon: centreLon + 0.1,
          cacheOnly: true,
        );

        expect(ways, isEmpty);
        expect(calls, 0, reason: 'cacheOnly must not fire any network fetch');
      },
    );

    test(
      'cacheOnly: still returns geometry already present in the cache',
      () async {
        // Pre-seed the cache for the centre tile (no network needed).
        final tile = TileId(
          12,
          tileMath.lonToTileX(centreLon, 12),
          tileMath.latToTileY(centreLat, 12),
        );
        await cacheDao.put(
          z: tile.z,
          x: tile.x,
          y: tile.y,
          payloadGzip: gzipUtf8(
            syntheticOverpassJson(wayId: 7, lat: centreLat, lon: centreLon),
          ),
          wayCount: 1,
        );

        var calls = 0;
        final client = buildClient((req) async {
          calls++;
          return http.Response('should-not-be-called', 500);
        });
        final source = OverpassWayCandidateSource(
          client: client,
          cacheDao: cacheDao,
        );

        final ways = await source.fetchWaysInBbox(
          minLat: centreLat - smallHalfLat,
          minLon: centreLon - smallHalfLon,
          maxLat: centreLat + smallHalfLat,
          maxLon: centreLon + smallHalfLon,
          cacheOnly: true,
        );

        expect(ways.where((w) => w.wayId == 7), hasLength(1));
        expect(calls, 0, reason: 'cached tile served without a network call');
      },
    );
  });
}
