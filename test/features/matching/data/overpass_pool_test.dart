// Tests for [OverpassPool] — multi-instance Overpass scheduler.
//
// Uses [MockClient] from `package:http/testing.dart` to control HTTP
// responses per-endpoint.  Timing-sensitive scenarios use
// `throttleDuration: Duration.zero` so throttle recovery fires in the
// next microtask tick; `pumpEventQueue()` drains the queue.

import 'dart:async';

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/overpass_pool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const double _minLat = 49.7;
const double _minLon = 9.1;
const double _maxLat = 49.8;
const double _maxLon = 9.2;

/// Minimal valid Overpass JSON envelope (no ways — enough to parse cleanly).
const String _okBody =
    '{"version":0.6,"generator":"test","elements":[]}';

const String _busyHtmlBody =
    '<?xml version="1.0" encoding="UTF-8"?> '
    '<html><body><p>Error: runtime error: The server is too busy.</p></body></html>';

const String _oomBody =
    '{"version":0.6,"remark":"runtime error: Query run out of memory '
    'in recurse. It would need at least 2048 MB of RAM."}';

final Uri _endpointA = Uri.parse('https://a.test/api/interpreter');
final Uri _endpointB = Uri.parse('https://b.test/api/interpreter');
final Uri _endpointC = Uri.parse('https://c.test/api/interpreter');

http.Response _jsonOk(String body) => http.Response.bytes(
      body.codeUnits,
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _statusOnly(int code) => http.Response('error', code);

/// Builds a pool with three test endpoints (2 / 8 / 8 slots by default) wired
/// to [handler].  Pass [throttleDuration] and [deadCheckDuration] to control
/// recovery timing in tests.
OverpassPool _buildPool(
  Future<http.Response> Function(http.Request request) handler, {
  int slotsA = 2,
  int slotsB = 8,
  int slotsC = 8,
  Duration throttleDuration = const Duration(seconds: 30),
  Duration deadCheckDuration = const Duration(minutes: 10),
}) {
  return OverpassPool(
    endpoints: [
      OverpassEndpointConfig(endpoint: _endpointA, maxSlots: slotsA),
      OverpassEndpointConfig(endpoint: _endpointB, maxSlots: slotsB),
      OverpassEndpointConfig(endpoint: _endpointC, maxSlots: slotsC),
    ],
    httpClient: MockClient(handler),
    throttleDuration: throttleDuration,
    deadCheckDuration: deadCheckDuration,
  );
}

Future<String> _fetch(OverpassPool pool) => pool.fetchRawJson(
      minLat: _minLat,
      minLon: _minLon,
      maxLat: _maxLat,
      maxLon: _maxLon,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('OverpassPool', () {
    // -----------------------------------------------------------------------
    // 1. totalSlots
    // -----------------------------------------------------------------------
    test('totalSlots returns the sum of all endpoint maxSlots', () {
      final pool = _buildPool((_) async => _jsonOk(_okBody));
      expect(pool.totalSlots, equals(2 + 8 + 8));
    });

    test('totalSlots reflects custom slot counts', () {
      final pool = _buildPool(
        (_) async => _jsonOk(_okBody),
        slotsA: 1,
        slotsB: 3,
        slotsC: 5,
      );
      expect(pool.totalSlots, equals(9));
    });

    // -----------------------------------------------------------------------
    // 2. Least-busy routing
    // -----------------------------------------------------------------------
    test(
      'routes first request to the endpoint with the most free slots (B or C, not A)',
      () async {
        final hitsPerHost = <String, int>{};
        final pool = _buildPool((request) async {
          hitsPerHost[request.url.host] =
              (hitsPerHost[request.url.host] ?? 0) + 1;
          return _jsonOk(_okBody);
        });

        await _fetch(pool);

        // A has 2 slots, B and C have 8 each → first request must not go to A.
        expect(hitsPerHost.containsKey('a.test'), isFalse);
        expect(
          hitsPerHost['b.test'] ?? 0 + (hitsPerHost['c.test'] ?? 0),
          equals(1),
        );
      },
    );

    test(
      'distributes 18 concurrent requests across all three endpoints without '
      'exceeding per-endpoint slot caps',
      () async {
        final inFlightPerHost = <String, int>{};
        final maxInFlightPerHost = <String, int>{};
        final completers = <Completer<void>>[];

        final pool = _buildPool((request) async {
          final host = request.url.host;
          inFlightPerHost[host] = (inFlightPerHost[host] ?? 0) + 1;
          maxInFlightPerHost[host] = [
            maxInFlightPerHost[host] ?? 0,
            inFlightPerHost[host]!,
          ].reduce((a, b) => a > b ? a : b);

          final completer = Completer<void>();
          completers.add(completer);
          await completer.future;

          inFlightPerHost[host] = inFlightPerHost[host]! - 1;
          return _jsonOk(_okBody);
        });

        // Fire 18 requests without awaiting.
        final futures = List.generate(18, (_) => _fetch(pool));

        // Let the event loop spin so requests get dispatched.
        await pumpEventQueue();

        // Release all completers.
        for (final c in completers) {
          c.complete();
        }
        await Future.wait(futures);

        // A has maxSlots=2, B and C have maxSlots=8.
        expect(
          maxInFlightPerHost['a.test'] ?? 0,
          lessThanOrEqualTo(2),
          reason: 'a.test must never exceed 2 concurrent requests',
        );
        expect(
          maxInFlightPerHost['b.test'] ?? 0,
          lessThanOrEqualTo(8),
          reason: 'b.test must never exceed 8 concurrent requests',
        );
        expect(
          maxInFlightPerHost['c.test'] ?? 0,
          lessThanOrEqualTo(8),
          reason: 'c.test must never exceed 8 concurrent requests',
        );
      },
    );

    // -----------------------------------------------------------------------
    // 3. Throttle → redirect to another instance
    // -----------------------------------------------------------------------
    test(
      '429 on first endpoint causes redirect to a different endpoint',
      () async {
        final hitHosts = <String>[];
        final pool = _buildPool(
          (request) async {
            hitHosts.add(request.url.host);
            // First attempt on whichever host: 429; then succeed.
            if (hitHosts.length == 1) return _statusOnly(429);
            return _jsonOk(_okBody);
          },
          throttleDuration: Duration.zero,
        );

        final body = await _fetch(pool);

        expect(body, equals(_okBody));
        expect(hitHosts.length, equals(2));
        // The second hit must be a different endpoint.
        expect(hitHosts[0], isNot(equals(hitHosts[1])));
      },
    );

    test(
      'HTML "too busy" body under HTTP 200 triggers throttle and redirect',
      () async {
        final hitHosts = <String>[];
        final pool = _buildPool(
          (request) async {
            hitHosts.add(request.url.host);
            if (hitHosts.length == 1) return _jsonOk(_busyHtmlBody);
            return _jsonOk(_okBody);
          },
          throttleDuration: Duration.zero,
        );

        final body = await _fetch(pool);

        expect(body, equals(_okBody));
        expect(hitHosts.length, equals(2));
        expect(hitHosts[0], isNot(equals(hitHosts[1])));
      },
    );

    test(
      '5xx triggers throttle and the next request goes to a different endpoint',
      () async {
        final hitHosts = <String>[];
        final pool = _buildPool(
          (request) async {
            hitHosts.add(request.url.host);
            if (hitHosts.length == 1) return _statusOnly(503);
            return _jsonOk(_okBody);
          },
          throttleDuration: Duration.zero,
        );

        final body = await _fetch(pool);

        expect(body, equals(_okBody));
        expect(hitHosts.length, equals(2));
        expect(hitHosts[0], isNot(equals(hitHosts[1])));
      },
    );

    // -----------------------------------------------------------------------
    // 4. All instances throttled → waits for recovery
    // -----------------------------------------------------------------------
    test(
      'waits for throttle recovery when all instances are throttled',
      () async {
        var callCount = 0;
        final pool = _buildPool(
          (request) async {
            callCount++;
            // Fail the first three calls (one per endpoint), then succeed.
            if (callCount <= 3) return _statusOnly(429);
            return _jsonOk(_okBody);
          },
          slotsA: 1,
          slotsB: 1,
          slotsC: 1,
          throttleDuration: Duration.zero,
        );

        // With Duration.zero throttle, timers fire in the next event loop
        // iteration — pumpEventQueue drains them.
        final bodyFuture = _fetch(pool);
        await pumpEventQueue();
        final body = await bodyFuture;

        expect(body, equals(_okBody));
        expect(callCount, greaterThanOrEqualTo(4));
      },
    );

    // -----------------------------------------------------------------------
    // 5. OOM → immediate NetworkError, no retry
    // -----------------------------------------------------------------------
    test(
      'OOM remark under HTTP 200 throws NetworkError immediately without retry',
      () async {
        var callCount = 0;
        final pool = _buildPool((request) async {
          callCount++;
          return _jsonOk(_oomBody);
        });

        await expectLater(_fetch(pool), throwsA(isA<NetworkError>()));
        expect(callCount, equals(1), reason: 'OOM must not trigger any retry');
      },
    );

    // -----------------------------------------------------------------------
    // 6. Non-retryable 4xx → immediate NetworkError, no redirect
    // -----------------------------------------------------------------------
    test(
      '403 Forbidden throws NetworkError immediately without trying other endpoints',
      () async {
        var callCount = 0;
        final pool = _buildPool((request) async {
          callCount++;
          return _statusOnly(403);
        });

        await expectLater(_fetch(pool), throwsA(isA<NetworkError>()));
        expect(
          callCount,
          equals(1),
          reason: 'non-retryable 4xx must fail fast without redirect',
        );
      },
    );

    // -----------------------------------------------------------------------
    // 7. Pool exhausted → NetworkError
    // -----------------------------------------------------------------------
    test(
      'throws NetworkError after all attempts are exhausted',
      () async {
        var callCount = 0;
        final pool = _buildPool(
          (request) async {
            callCount++;
            return _statusOnly(429);
          },
          slotsA: 1,
          slotsB: 1,
          slotsC: 1,
          throttleDuration: Duration.zero,
          deadCheckDuration: Duration.zero,
        );

        // Await directly — intermediate pumpEventQueue would let the NetworkError
        // propagate as an unhandled exception before expectLater registers a
        // listener. The Duration.zero throttle timers fire naturally while the
        // outer await yields to the event loop.
        await expectLater(_fetch(pool), throwsA(isA<NetworkError>()));
        // Should have tried at most slots.length * 2 = 6 times.
        expect(callCount, lessThanOrEqualTo(6));
      },
    );

    // -----------------------------------------------------------------------
    // 8. User-Agent header
    // -----------------------------------------------------------------------
    test('sends User-Agent header on every request', () async {
      final headers = <Map<String, String>>[];
      final pool = _buildPool((request) async {
        headers.add(Map<String, String>.from(request.headers));
        return _jsonOk(_okBody);
      });

      await _fetch(pool);

      expect(headers, hasLength(1));
      expect(headers.first['User-Agent'], contains('Trailblazer'));
    });

    // -----------------------------------------------------------------------
    // 9. Throttle expiry wakes parked waiter
    // -----------------------------------------------------------------------
    test(
      'a parked request is dispatched after throttle expiry (Duration.zero)',
      () async {
        var callCount = 0;
        final pool = _buildPool(
          (request) async {
            callCount++;
            if (callCount == 1) return _statusOnly(429);
            return _jsonOk(_okBody);
          },
          slotsA: 1,
          slotsB: 0, // force only one available slot to make parking observable
          slotsC: 0,
          throttleDuration: Duration.zero,
        );

        final bodyFuture = _fetch(pool);
        await pumpEventQueue(times: 10);
        final body = await bodyFuture;

        expect(body, equals(_okBody));
        expect(callCount, equals(2));
      },
    );

    // -----------------------------------------------------------------------
    // 10. isConsideredDead after 3 consecutive throttles → uses deadCheckDuration
    // -----------------------------------------------------------------------
    test(
      'uses deadCheckDuration instead of throttleDuration after 3 consecutive '
      'throttle events on the same slot',
      () async {
        // Track which recovery duration actually fired by measuring wall time.
        // Use deadCheckDuration=1ms so the test stays fast.
        const shortDead = Duration(milliseconds: 1);
        // throttleDuration is Duration.zero so normal throttles fire instantly;
        // only after the 3rd consecutive error should the 1ms delay appear.

        var callCount = 0;
        final pool = _buildPool(
          (request) async {
            callCount++;
            // Throttle 3 times, then succeed.
            if (callCount <= 3) return _statusOnly(429);
            return _jsonOk(_okBody);
          },
          slotsA: 1,
          slotsB: 0,
          slotsC: 0,
          throttleDuration: Duration.zero,
          deadCheckDuration: shortDead,
        );

        final bodyFuture = _fetch(pool);
        await pumpEventQueue(times: 100);
        await Future<void>.delayed(shortDead * 2);
        final body = await bodyFuture;

        expect(body, equals(_okBody));
        expect(callCount, equals(4));
      },
    );

    // -----------------------------------------------------------------------
    // 11. markSuccess resets consecutiveErrors
    // -----------------------------------------------------------------------
    test(
      'successful request resets consecutive error count so slot is not '
      'considered dead',
      () async {
        var callCount = 0;
        final pool = _buildPool(
          (request) async {
            callCount++;
            // Two throttles then a success then all further calls throttle.
            if (callCount == 1 || callCount == 2) return _statusOnly(429);
            if (callCount == 3) return _jsonOk(_okBody); // resets errors
            return _statusOnly(429); // fresh first error after reset
          },
          slotsA: 1,
          slotsB: 0,
          slotsC: 0,
          throttleDuration: Duration.zero,
          // deadCheckDuration must be zero too — after 3 more consecutive
          // throttles the slot becomes "dead" and the default 10-min duration
          // would hang the test.
          deadCheckDuration: Duration.zero,
        );

        // First fetch: survives two throttles, succeeds on 3rd call.
        final body = await _fetch(pool).timeout(const Duration(seconds: 5));
        expect(body, equals(_okBody));

        // Second fetch: all remaining calls throttle. Pool exhausts maxAttempts.
        // Await directly so the error is never unlistened.
        await expectLater(
          _fetch(pool),
          throwsA(isA<NetworkError>()),
        );
        expect(callCount, greaterThanOrEqualTo(4));
      },
    );

    // -----------------------------------------------------------------------
    // 12. Slot cap: never exceeds maxSlots concurrently for a single endpoint
    // -----------------------------------------------------------------------
    test(
      'never dispatches more than maxSlots concurrent requests to one endpoint',
      () async {
        const maxSlotsForA = 2;
        var inFlightForA = 0;
        var maxObservedInFlightForA = 0;

        // The gate holds ALL requests until we release it. That lets us measure
        // the in-flight peak without racing against early completions.
        final releaseGate = Completer<void>();
        // Resolved once exactly maxSlotsForA requests are in-flight, so the
        // test can assert the cap before releasing the gate.
        final fullCapReached = Completer<void>();

        final pool = _buildPool(
          (request) async {
            inFlightForA++;
            if (inFlightForA > maxObservedInFlightForA) {
              maxObservedInFlightForA = inFlightForA;
            }
            if (inFlightForA == maxSlotsForA && !fullCapReached.isCompleted) {
              fullCapReached.complete();
            }
            await releaseGate.future;
            inFlightForA--;
            return _jsonOk(_okBody);
          },
          slotsB: 0, // isolate to just endpoint A (default slotsA=2)
          slotsC: 0,
        );

        // Launch maxSlotsForA + 1 requests — the third must wait for a slot.
        final futures = List.generate(maxSlotsForA + 1, (_) => _fetch(pool));

        // Wait until exactly maxSlotsForA are in-flight.
        await fullCapReached.future;

        expect(
          inFlightForA,
          equals(maxSlotsForA),
          reason: 'all available slots should be filled',
        );
        expect(
          maxObservedInFlightForA,
          lessThanOrEqualTo(maxSlotsForA),
          reason: 'slot cap must never be exceeded',
        );

        // Release the gate so all 3 requests (2 in-flight + 1 parked) complete.
        releaseGate.complete();
        await Future.wait(futures);

        expect(
          maxObservedInFlightForA,
          lessThanOrEqualTo(maxSlotsForA),
          reason: 'slot cap must not have been exceeded during full run',
        );
      },
    );

    // -----------------------------------------------------------------------
    // 13. close() is a no-op (does not throw)
    // -----------------------------------------------------------------------
    test('close() completes without error', () {
      final pool = _buildPool((_) async => _jsonOk(_okBody));
      expect(pool.close, returnsNormally);
    });
  });
}
