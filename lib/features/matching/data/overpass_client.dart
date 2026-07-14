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
import 'dart:convert';

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
    final rawJson = await fetchRawJson(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
      timeoutSeconds: timeoutSeconds,
    );
    return _parser.parseWays(rawJson);
  }

  /// Fetches the raw Overpass JSON body for the given bbox (no parsing).
  ///
  /// Exposed so callers that need the untransformed payload (e.g. the 04-15
  /// tile-cache write path) can persist the exact bytes without a
  /// re-encoding round-trip through the parser. Same retry/fallback
  /// contract as [fetchWaysInBbox].
  Future<String> fetchRawJson({
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
    return _postQuery(query);
  }

  /// Returns the total length in meters of all `highway=` ways inside the
  /// region [regionAreaId] (Overpass area id = `3600000000 + osmRelationId`),
  /// clipped to the given bbox cell. Used by `RegionTotalLengthService` to
  /// sum a region's real road length tile-by-tile without transferring
  /// geometry.
  ///
  /// Same retry/fallback contract as [fetchWaysInBbox]. Throws [DomainError]
  /// on exhausted attempts.
  Future<double> fetchRegionLengthInBbox({
    required int regionAreaId,
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    int timeoutSeconds = 180,
  }) async {
    final query = _queryBuilder.buildRegionLengthInBboxQuery(
      regionAreaId: regionAreaId,
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
      timeoutSeconds: timeoutSeconds,
    );
    final raw = await _postQuery(query);
    return _parseTotalMeters(raw);
  }

  /// Parses the `total_m` tag out of a `make stat total_m=sum(length())`
  /// Overpass response. Returns 0 when the element/tag is absent (e.g. the
  /// cell contained no roads).
  ///
  /// Error detection (HTML/XML bodies and error `remark`s served under HTTP
  /// 200) now lives in [_postQuery]'s shared classify gate, so by the time a
  /// body reaches here it is guaranteed to be a clean JSON envelope — no
  /// per-caller `remark` inspection needed.
  double _parseTotalMeters(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return 0;
    final elements = decoded['elements'];
    if (elements is! List || elements.isEmpty) return 0;
    for (final el in elements) {
      if (el is Map<String, dynamic>) {
        final tags = el['tags'];
        if (tags is Map<String, dynamic>) {
          final v = tags['total_m'];
          if (v is String) return double.tryParse(v) ?? 0;
          if (v is num) return v.toDouble();
        }
      }
    }
    return 0;
  }

  /// Shared POST loop with retry + endpoint fallback for an arbitrary QL body.
  Future<String> _postQuery(String query) async {
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
          // Overpass frequently serves errors ("server too busy", query
          // timeout, out-of-memory) as HTTP 200 with an HTML/XML body or a
          // JSON `remark` — the status line alone is NOT a success signal.
          // Classify the body before trusting it.
          switch (_classify200Body(response.body)) {
            case _OverpassBodyKind.ok:
              return response.body;
            case _OverpassBodyKind.memoryError:
              // Deterministic server-side OOM: retrying the same cell / body
              // is pointless. Fail loud with a 'memory'-bearing message so the
              // region-length caller (_sumCell) subdivides the cell instead.
              throw const NetworkError(
                'Overpass query exceeded the server memory ceiling '
                '(out of memory)',
              );
            case _OverpassBodyKind.transientError:
              // Server busy / query timeout under 200 — treat exactly like a
              // retryable status: backoff+retry on primary, then fallback.
              if (attempt < 2) {
                await Future<void>.delayed(_backoff(attempt));
                continue;
              }
              throw const NetworkError(
                'Overpass returned a transient error under HTTP 200 '
                '(server busy / timeout) after all attempts',
              );
          }
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

  /// Transient (server-busy / query-timeout) keywords that Overpass emits in
  /// an HTTP-200 error body. Retrying (and falling back) can succeed.
  static const List<String> _transientKeywords = [
    'runtime error',
    'timed out',
    'timeout',
    'too busy',
    'busy',
    'please reduce',
    'gateway',
  ];

  /// Classifies an HTTP-200 [body] into ok / transient-error / memory-error.
  ///
  /// Overpass serves errors under 200 either as an HTML/XML page or as a JSON
  /// envelope carrying a top-level `remark`. A normal successful response is
  /// JSON with neither shape, so the fast path returns `ok` without a keyword
  /// scan. Only markup or a `remark`-bearing body is inspected further —
  /// keying on error keywords keeps benign informational remarks (which
  /// Overpass also emits) from being misread as failures.
  static _OverpassBodyKind _classify200Body(String body) {
    final lower = body.trimLeft().toLowerCase();
    final looksMarkup = lower.startsWith('<');
    final hasRemark = lower.contains('"remark"');
    if (!looksMarkup && !hasRemark) return _OverpassBodyKind.ok;
    if (lower.contains('out of memory') || lower.contains('memory')) {
      return _OverpassBodyKind.memoryError;
    }
    if (looksMarkup) return _OverpassBodyKind.transientError;
    for (final kw in _transientKeywords) {
      if (lower.contains(kw)) return _OverpassBodyKind.transientError;
    }
    // A JSON `remark` with no error/timeout/busy/memory keyword — benign.
    return _OverpassBodyKind.ok;
  }

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

/// How an HTTP-200 Overpass body classifies: a real success, a transient
/// server-side error (retry/fallback may help), or a deterministic
/// out-of-memory error (the caller must shrink the query).
enum _OverpassBodyKind { ok, transientError, memoryError }
