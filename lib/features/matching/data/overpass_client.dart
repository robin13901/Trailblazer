// Phase 4 rescope Wave 2 (Plan 04-13):
// Networked, mockable, resilient Overpass HTTP client.
//
// Behavior contract:
//   - POST QL bodies to the primary endpoint; fall back to a secondary
//     endpoint on the third attempt.
//   - Retry with exponential backoff on 429 / 5xx / TimeoutException.
//   - Wrap non-DomainError throwables at the client boundary via
//     `DomainError.wrap(e, st)` (STATE Plan 01-04).
//   - Always send `User-Agent: Trailblazer/0.1 (...)` per Overpass usage
//     policy (unauthenticated clients without a UA are throttled harder).
//
// Live-probe result from Task 2 start (2026-07-08):
//   - `overpass.kumi.systems/api/interpreter` timed out at 30s (root 200; API
//     path unresponsive).
//   - `overpass.private.coffee/api/interpreter` timed out at 30s (root 200;
//     API path unresponsive).
//   - `maps.mail.ru/osm/tools/overpass/api/interpreter` (VK Maps mirror,
//     documented as tertiary fallback in plan §Deviations) responded HTTP 200
//     with a valid Overpass JSON envelope. Selected as the fallback endpoint.

import 'dart:async';

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/overpass_query_builder.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:http/http.dart' as http;

/// Default primary endpoint — the canonical Overpass server.
final Uri kOverpassPrimaryEndpoint = Uri.parse(
  'https://overpass-api.de/api/interpreter',
);

/// Default fallback endpoint — selected via live probe on 2026-07-08 after
/// both community-cited alternatives (Kumi, private.coffee) failed the
/// interpreter-path liveness check. Documented in plan §Deviations as the
/// tertiary fallback.
final Uri kOverpassFallbackEndpoint = Uri.parse(
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
);

/// Overpass HTTP client with retry + endpoint-fallback logic.
class OverpassClient {
  OverpassClient({
    http.Client? client,
    Uri? primaryEndpoint,
    Uri? fallbackEndpoint,
    String userAgent = 'Trailblazer/0.1 (github.com/I551358/Trailblazer)',
    Duration Function(int attempt)? backoffBuilder,
    Duration requestTimeout = const Duration(seconds: 60),
    OverpassResponseParser parser = const OverpassResponseParser(),
    OverpassQueryBuilder queryBuilder = const OverpassQueryBuilder(),
  })  : _client = client ?? http.Client(),
        _primary = primaryEndpoint ?? kOverpassPrimaryEndpoint,
        _fallback = fallbackEndpoint ?? kOverpassFallbackEndpoint,
        _userAgent = userAgent,
        _backoff = backoffBuilder ?? _defaultBackoff,
        _timeout = requestTimeout,
        _parser = parser,
        _queryBuilder = queryBuilder;

  final http.Client _client;
  final Uri _primary;
  final Uri _fallback;
  final String _userAgent;
  final Duration Function(int) _backoff;
  final Duration _timeout;
  final OverpassResponseParser _parser;
  final OverpassQueryBuilder _queryBuilder;

  /// Fetches every Kfz-allowlisted way whose geometry intersects the given
  /// bbox. Coordinate order is `(minLat, minLon, maxLat, maxLon)` matching
  /// Overpass's `(south, west, north, east)` convention.
  ///
  /// Attempt schedule:
  ///   1. Primary endpoint.
  ///   2. Primary endpoint (retry after backoff on 429/5xx/timeout).
  ///   3. Fallback endpoint.
  ///
  /// Throws [DomainError] (specifically [NetworkError]) if all three
  /// attempts fail; other throwables are wrapped via [DomainError.wrap].
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    int timeoutSeconds = 25,
  }) async {
    final query = _queryBuilder.buildBboxHighwayQuery(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
      timeoutSeconds: timeoutSeconds,
    );
    final body = 'data=${Uri.encodeQueryComponent(query)}';

    for (var attempt = 0; attempt < 3; attempt++) {
      final endpoint = attempt < 2 ? _primary : _fallback;
      try {
        final response = await _client
            .post(
              endpoint,
              headers: {
                'User-Agent': _userAgent,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: body,
            )
            .timeout(_timeout);

        if (response.statusCode == 200) {
          return _parser.parseWays(response.body);
        }
        if (_isRetryableStatus(response.statusCode)) {
          if (attempt < 2) {
            await Future<void>.delayed(_backoff(attempt));
            continue;
          }
          throw NetworkError(
            'Overpass exhausted all attempts (last status: '
            '${response.statusCode})',
            statusCode: response.statusCode,
          );
        }
        // Non-retryable status (4xx other than 429) — fail loud immediately.
        throw NetworkError(
          'Overpass returned non-retryable status ${response.statusCode}',
          statusCode: response.statusCode,
        );
      } on TimeoutException catch (e, st) {
        if (attempt == 2) {
          throw NetworkError(
            'Overpass request timed out after '
            '${_timeout.inSeconds}s on final attempt',
            cause: e,
            stackTrace: st,
          );
        }
        await Future<void>.delayed(_backoff(attempt));
      } on DomainError {
        rethrow;
      } on Object catch (e, st) {
        if (attempt == 2) {
          throw DomainError.wrap(e, st);
        }
        await Future<void>.delayed(_backoff(attempt));
      }
    }
    // Unreachable — the loop always either returns or throws — but the
    // analyzer wants an explicit trailing throw.
    throw const NetworkError('Overpass fetch reached unreachable path');
  }

  /// Releases the underlying HTTP client. Callers who injected their own
  /// client should manage its lifecycle externally and NOT call this.
  void close() => _client.close();

  static bool _isRetryableStatus(int code) =>
      code == 429 || (code >= 500 && code < 600);

  static Duration _defaultBackoff(int attempt) {
    switch (attempt) {
      case 0:
        return const Duration(seconds: 2);
      case 1:
        return const Duration(seconds: 5);
      default:
        return const Duration(seconds: 10);
    }
  }
}
