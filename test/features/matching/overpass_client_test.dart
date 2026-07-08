// Test file exercises many mock-client permutations; non-const call sites
// keep the individual scenarios readable.

import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final primary = Uri.parse('https://primary.test/api/interpreter');
  final fallback = Uri.parse('https://fallback.test/api/interpreter');

  String kreuzbergFixture() {
    final bytes = File(
      'test/fixtures/overpass/urban_kreuzberg_5x5km.json.gz',
    ).readAsBytesSync();
    return utf8.decode(gzip.decode(bytes));
  }

  http.Response okResponse(String body) => http.Response.bytes(
        utf8.encode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  OverpassClient buildClient(
    Future<http.Response> Function(http.Request req) handler, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return OverpassClient(
      client: MockClient(handler),
      primaryEndpoint: primary,
      fallbackEndpoint: fallback,
      backoffBuilder: (_) => Duration.zero,
      requestTimeout: timeout,
    );
  }

  group('OverpassClient', () {
    test('200 response returns parsed ways', () async {
      final client = buildClient((req) async {
        expect(req.url, primary);
        return okResponse(kreuzbergFixture());
      });
      final ways = await client.fetchWaysInBbox(
        minLat: 52.49,
        minLon: 13.37,
        maxLat: 52.51,
        maxLon: 13.41,
      );
      expect(ways.length, greaterThan(500));
    });

    test('429 retries with backoff then succeeds on primary', () async {
      var call = 0;
      final client = buildClient((req) async {
        call++;
        expect(req.url, primary);
        if (call == 1) return http.Response('too many', 429);
        return okResponse(kreuzbergFixture());
      });
      final ways = await client.fetchWaysInBbox(
        minLat: 52.49,
        minLon: 13.37,
        maxLat: 52.51,
        maxLon: 13.41,
      );
      expect(call, 2);
      expect(ways.length, greaterThan(500));
    });

    test('5xx on primary twice then fallback succeeds', () async {
      final calls = <Uri>[];
      final client = buildClient((req) async {
        calls.add(req.url);
        if (calls.length <= 2) return http.Response('gateway error', 502);
        return okResponse(kreuzbergFixture());
      });
      final ways = await client.fetchWaysInBbox(
        minLat: 52.49,
        minLon: 13.37,
        maxLat: 52.51,
        maxLon: 13.41,
      );
      expect(calls, hasLength(3));
      expect(calls[0], primary);
      expect(calls[1], primary);
      expect(calls[2], fallback);
      expect(calls[2].host, 'fallback.test');
      expect(ways.length, greaterThan(500));
    });

    test('all three attempts fail with 500 → NetworkError thrown', () async {
      final client = buildClient((req) async {
        return http.Response('boom', 500);
      });
      await expectLater(
        client.fetchWaysInBbox(
          minLat: 0,
          minLon: 0,
          maxLat: 1,
          maxLon: 1,
        ),
        throwsA(isA<NetworkError>()),
      );
    });

    test('timeout retries then throws NetworkError on final attempt',
        () async {
      var call = 0;
      final client = buildClient(
        (req) async {
          call++;
          // Always exceeds the tight 20 ms timeout below.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response('late', 200);
        },
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        client.fetchWaysInBbox(
          minLat: 0,
          minLon: 0,
          maxLat: 1,
          maxLon: 1,
        ),
        throwsA(isA<NetworkError>()),
      );
      expect(call, 3, reason: 'must attempt all 3 endpoints before throwing');
    });

    test('User-Agent header set on every request', () async {
      final headers = <Map<String, String>>[];
      final client = buildClient((req) async {
        headers.add(Map<String, String>.from(req.headers));
        if (headers.length < 3) return http.Response('overload', 429);
        return okResponse(kreuzbergFixture());
      });
      await client.fetchWaysInBbox(
        minLat: 0,
        minLon: 0,
        maxLat: 1,
        maxLon: 1,
      );
      expect(headers, hasLength(3));
      for (final h in headers) {
        expect(h['User-Agent'], contains('Trailblazer'));
      }
    });

    test('non-retryable 4xx (400 bad request) fails fast without retries',
        () async {
      var call = 0;
      final client = buildClient((req) async {
        call++;
        return http.Response('bad request', 400);
      });
      await expectLater(
        client.fetchWaysInBbox(
          minLat: 0,
          minLon: 0,
          maxLat: 1,
          maxLon: 1,
        ),
        throwsA(isA<NetworkError>()),
      );
      expect(call, 1,
          reason: '400 is non-retryable — should NOT hit fallback or retry');
    });
  });
}
