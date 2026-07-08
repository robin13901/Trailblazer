// Trailblazer Phase 4 rescope, Plan 04-16 (Wave 3):
// Shared Overpass fetcher for Germany administrative-boundary relations.
//
// This code is imported by BOTH the runtime `AdminBundleRefresher` (Flutter
// app, via the leaf `admin_geometry` package) AND the dev CLI at
// `tool/osm_pipeline/bin/fetch_admin_polygons.dart`. Single source of truth.
//
// Behavior:
//   - POSTs the fixed DE admin-boundary QL to Overpass, primary → fallback.
//   - Server-side timeout 600s (this is a heavy query — full-Germany admin
//     relations at levels 2/4/6/8/9/10).
//   - Retries 3x on 429 / 5xx with 30s / 60s / 120s backoff.
//   - Fallback endpoint uses the same VK-Maps mirror as
//     `lib/features/matching/data/overpass_client.dart` (live-probed
//     2026-07-08 — see STATE Plan 04-13 decision).
//   - Sends `User-Agent: Trailblazer-AdminPolyFetch/0.1` per Overpass usage
//     policy.
//   - Returns raw JSON body (assembly + simplification happens in
//     `AdminPolygonSimplifier`).
//
// Pure Dart — depends only on `package:http`.

import 'dart:async';

import 'package:http/http.dart' as http;

/// Default primary Overpass endpoint.
final Uri kAdminOverpassPrimaryEndpoint = Uri.parse(
  'https://overpass-api.de/api/interpreter',
);

/// Default fallback Overpass endpoint (VK Maps mirror; live-probed
/// 2026-07-08 per STATE Plan 04-13).
final Uri kAdminOverpassFallbackEndpoint = Uri.parse(
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
);

/// Overpass QL query for DE admin-boundary relations at levels 2/4/6/8/9/10.
///
/// Uses `out geom` so member ways carry their full node coordinate list —
/// the client does not need a separate `node(w)` round-trip.
const kAdminOverpassQuery = r'''
[out:json][timeout:600];
area["ISO3166-1"="DE"][admin_level=2]->.de;
(relation["boundary"="administrative"]["admin_level"~"^(2|4|6|8|9|10)$"](area.de););
out geom;
''';

/// Signaled when every attempt (primary + retries + fallback) fails.
///
/// Kept as a plain [Exception] subclass — the caller (dev CLI or the
/// app-side `AdminBundleRefresher`) is responsible for wrapping this into a
/// `DomainError` if it needs to cross the app-side domain boundary.
class AdminOverpassFetchException implements Exception {
  /// Creates an exception carrying [message] and optional [statusCode].
  const AdminOverpassFetchException(this.message, {this.statusCode});

  /// Human-readable summary of the failure — safe to log.
  final String message;

  /// The last HTTP status observed across all attempts (null if every
  /// attempt failed at the transport layer).
  final int? statusCode;

  @override
  String toString() {
    final code = statusCode == null ? '' : ' (status=$statusCode)';
    return 'AdminOverpassFetchException: $message$code';
  }
}

/// Shared Overpass fetcher.
///
/// Stateless — hold a single instance or reconstruct freely.
class AdminPolygonDownloader {
  /// Constructs a downloader with the given transport / retry contract.
  AdminPolygonDownloader({
    http.Client? client,
    Uri? primaryEndpoint,
    Uri? fallbackEndpoint,
    String userAgent = 'Trailblazer-AdminPolyFetch/0.1',
    Duration Function(int attempt)? backoffBuilder,
    Duration requestTimeout = const Duration(seconds: 620),
  })  : _client = client ?? http.Client(),
        _primary = primaryEndpoint ?? kAdminOverpassPrimaryEndpoint,
        _fallback = fallbackEndpoint ?? kAdminOverpassFallbackEndpoint,
        _userAgent = userAgent,
        _backoff = backoffBuilder ?? _defaultBackoff,
        _timeout = requestTimeout;

  final http.Client _client;
  final Uri _primary;
  final Uri _fallback;
  final String _userAgent;
  final Duration Function(int) _backoff;
  final Duration _timeout;

  /// Default backoff schedule: 30s / 60s / 120s.
  static Duration _defaultBackoff(int attempt) {
    switch (attempt) {
      case 0:
        return const Duration(seconds: 30);
      case 1:
        return const Duration(seconds: 60);
      default:
        return const Duration(seconds: 120);
    }
  }

  /// Fetches the raw Overpass JSON body for the Germany admin-boundary query.
  ///
  /// Attempt schedule:
  ///   1. Primary endpoint.
  ///   2. Primary endpoint (retry after backoff on 429 / 5xx / timeout).
  ///   3. Fallback endpoint (after another backoff).
  ///
  /// Throws [AdminOverpassFetchException] once all three attempts fail.
  Future<String> fetchDeAdminRelations() async {
    final endpoints = [_primary, _primary, _fallback];
    Object? lastError;
    int? lastStatus;

    for (var attempt = 0; attempt < endpoints.length; attempt++) {
      final endpoint = endpoints[attempt];
      try {
        final response = await _client
            .post(
              endpoint,
              headers: {
                'User-Agent': _userAgent,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: 'data=${Uri.encodeQueryComponent(kAdminOverpassQuery)}',
            )
            .timeout(_timeout);

        if (response.statusCode == 200) {
          return response.body;
        }
        // Non-200 — decide retryability.
        lastStatus = response.statusCode;
        if (response.statusCode == 429 || response.statusCode >= 500) {
          lastError = 'HTTP ${response.statusCode} from $endpoint';
          if (attempt < endpoints.length - 1) {
            await Future<void>.delayed(_backoff(attempt));
          }
          continue;
        }
        // 4xx (non-429) — non-retryable.
        throw AdminOverpassFetchException(
          'Non-retryable HTTP ${response.statusCode} from $endpoint',
          statusCode: response.statusCode,
        );
      } on TimeoutException catch (e) {
        lastError = 'Timeout on $endpoint: $e';
        if (attempt < endpoints.length - 1) {
          await Future<void>.delayed(_backoff(attempt));
        }
      } on AdminOverpassFetchException {
        rethrow;
      } on Object catch (e) {
        lastError = 'Transport error on $endpoint: $e';
        if (attempt < endpoints.length - 1) {
          await Future<void>.delayed(_backoff(attempt));
        }
      }
    }

    throw AdminOverpassFetchException(
      'All Overpass attempts failed (last: $lastError)',
      statusCode: lastStatus,
    );
  }

  /// Releases the underlying HTTP client (only meaningful if the caller
  /// did NOT inject their own).
  void close() => _client.close();
}
