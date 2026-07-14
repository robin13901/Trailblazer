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

  // Overpass frequently serves errors ("server too busy", query timeout,
  // out-of-memory) as HTTP 200 with an HTML/XML body or a JSON `remark`.
  // These must NOT be trusted as success. Reproduced live 2026-07-14.
  group('OverpassClient HTTP-200 error bodies', () {
    // A realistic Overpass "too busy" HTML error page, served under 200.
    const busyHtml = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<html><head><title>OSM3S Response</title></head><body>\n'
        '<p><strong style="color:#FF0000">Error</strong>: runtime error: '
        'open64: 0 Success Dispatcher_Client::request_read_and_idx::timeout. '
        'The server is probably too busy to handle your request.</p>\n'
        '</body></html>';

    test('transient HTML error under 200, then JSON success → retries once',
        () async {
      var call = 0;
      final client = buildClient((req) async {
        call++;
        expect(req.url, primary);
        if (call == 1) return okResponse(busyHtml);
        return okResponse(kreuzbergFixture());
      });
      final ways = await client.fetchWaysInBbox(
        minLat: 52.49,
        minLon: 13.37,
        maxLat: 52.51,
        maxLon: 13.41,
      );
      expect(call, 2, reason: 'HTML-200 error must trigger a retry');
      expect(ways.length, greaterThan(500));
    });

    test('transient HTML error under 200 on all attempts → NetworkError, '
        'fallback hit on attempt 3', () async {
      final calls = <Uri>[];
      final client = buildClient((req) async {
        calls.add(req.url);
        return okResponse(busyHtml);
      });
      await expectLater(
        client.fetchWaysInBbox(minLat: 0, minLon: 0, maxLat: 1, maxLon: 1),
        throwsA(isA<NetworkError>()),
      );
      expect(calls, hasLength(3));
      expect(calls[2], fallback, reason: 'attempt 3 must use the fallback');
    });

    test('out-of-memory remark under 200 → NetworkError with "memory", '
        'no retry', () async {
      var call = 0;
      final client = buildClient((req) async {
        call++;
        return okResponse(
          '{"version":0.6,"remark":"runtime error: Query run out of memory '
          'in recurse. It would need at least 2048 MB of RAM."}',
        );
      });
      await expectLater(
        client.fetchWaysInBbox(minLat: 0, minLon: 0, maxLat: 1, maxLon: 1),
        throwsA(
          isA<NetworkError>().having(
            (e) => e.toString().toLowerCase(),
            'message',
            contains('memory'),
          ),
        ),
      );
      expect(call, 1,
          reason: 'deterministic OOM must fail immediately without retry');
    });

    test('benign JSON remark (no error keyword) under 200 → returned as-is',
        () async {
      var call = 0;
      // A valid envelope that also carries an informational remark — must be
      // treated as success, not a false-positive error.
      const benign =
          '{"version":0.6,"remark":"Notice: some ways were simplified.", '
          '"elements":[]}';
      final client = buildClient((req) async {
        call++;
        return okResponse(benign);
      });
      final ways = await client.fetchWaysInBbox(
        minLat: 0,
        minLon: 0,
        maxLat: 1,
        maxLon: 1,
      );
      expect(call, 1, reason: 'benign remark must not trigger a retry');
      expect(ways, isEmpty);
    });

    test('fetchRegionLengthInBbox parses total_m from a clean 200 body',
        () async {
      final client = buildClient((req) async {
        return okResponse(
          '{"version":0.6,"elements":[{"type":"count","tags":'
          '{"total_m":"62638.061"}}]}',
        );
      });
      final meters = await client.fetchRegionLengthInBbox(
        regionAreaId: 3600393501,
        minLat: 49.7,
        minLon: 9.1,
        maxLat: 49.8,
        maxLon: 9.2,
      );
      expect(meters, closeTo(62638.061, 0.001));
    });

    test('fetchRegionLengthInBbox surfaces an OOM remark as NetworkError',
        () async {
      final client = buildClient((req) async {
        return okResponse(
          '{"version":0.6,"remark":"runtime error: out of memory"}',
        );
      });
      await expectLater(
        client.fetchRegionLengthInBbox(
          regionAreaId: 3600000001,
          minLat: 0,
          minLon: 0,
          maxLat: 1,
          maxLon: 1,
        ),
        throwsA(isA<NetworkError>()),
      );
    });

    test('fetchRegionLengthInBbox tries the FALLBACK first (degraded primary)',
        () async {
      final calls = <Uri>[];
      final client = buildClient((req) async {
        calls.add(req.url);
        return okResponse(
          '{"version":0.6,"elements":[{"type":"count",'
          '"tags":{"total_m":"62638.061"}}]}',
        );
      });
      final meters = await client.fetchRegionLengthInBbox(
        regionAreaId: 3600393501,
        minLat: 49.7,
        minLon: 9.1,
        maxLat: 49.8,
        maxLon: 9.2,
      );
      expect(meters, closeTo(62638.061, 0.001));
      expect(calls, hasLength(1));
      expect(calls.first, fallback,
          reason: 'region-length must hit the working mirror on attempt 0');
    });

    test('fetchWaysInBbox still tries the PRIMARY first (unaffected)', () async {
      final calls = <Uri>[];
      final client = buildClient((req) async {
        calls.add(req.url);
        return okResponse(kreuzbergFixture());
      });
      await client.fetchWaysInBbox(
        minLat: 52.49,
        minLon: 13.37,
        maxLat: 52.51,
        maxLon: 13.41,
      );
      expect(calls.first, primary,
          reason: 'trip-matching path keeps primary-first order');
    });
  });
}
