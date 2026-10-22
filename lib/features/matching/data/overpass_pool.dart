import 'dart:async';

import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:auto_explore/features/matching/data/overpass_query_builder.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Configuration for one endpoint in an [OverpassPool].
class OverpassEndpointConfig {
  const OverpassEndpointConfig({
    required this.endpoint,
    required this.maxSlots,
  });

  final Uri endpoint;

  /// Maximum number of concurrent in-flight requests to this endpoint.
  final int maxSlots;
}

/// Default pool configuration.
///
/// Only instances that have been live-probed against the /api/interpreter
/// path are included here. overpass.private.coffee is deliberately excluded:
/// the interpreter path was unresponsive (30 s timeout) during the July 2026
/// live probe (see overpass_client.dart header comment) and is not reliable
/// enough for production tile fetching.
///
/// Slot budgets:
///  - overpass-api.de: 2 (FOSSGIS dispatcher hard-enforces this)
///  - maps.mail.ru:    8 (rate_limit=0, 2×56 cores, confirmed working 2026-07-08)
///
/// Total: 10 slots — 5× the previous single-instance capacity.
final List<OverpassEndpointConfig> kDefaultOverpassPoolEndpoints = [
  OverpassEndpointConfig(
    endpoint: Uri.parse('https://overpass-api.de/api/interpreter'),
    maxSlots: 2,
  ),
  OverpassEndpointConfig(
    endpoint: Uri.parse(
      'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
    ),
    maxSlots: 8,
  ),
];

/// Multi-instance Overpass pool implementing [OverpassRawFetcher].
///
/// Routes each tile fetch to the least-busy healthy instance.  When an
/// instance signals throttle (HTTP 429, 5xx, timeout, or an HTML/transient
/// body under HTTP 200), it is put into a temporary cooldown and subsequent
/// requests overflow immediately to another healthy instance.
///
/// ## Scheduling
///
/// * **Least-busy**: A new request is dispatched to the instance that
///   currently has the highest number of free slots.
/// * **Overflow-to-slack**: On throttle the slot is released, the instance is
///   marked THROTTLED, and `_dispatch` loops back to pick the next best
///   instance without waiting.
/// * **All-throttled wait**: When every instance is busy or throttled, the
///   request parks on a `Completer`.  `Future.delayed` timers scheduled at
///   throttle-time wake the parked request once any instance recovers.
///
/// ## Error handling
///
/// * OOM (`out of memory` body): throws [NetworkError] immediately, no retry.
/// * Non-retryable 4xx (all except 429): throws [NetworkError] immediately.
/// * Exhausted attempts (all instances tried `slots.length * 2` times):
///   throws [NetworkError].
class OverpassPool implements OverpassRawFetcher {
  OverpassPool({
    required List<OverpassEndpointConfig> endpoints,
    required http.Client httpClient,
    String userAgent = 'Trailblazer/0.1 (github.com/I551358/Trailblazer)',
    Duration requestTimeout = const Duration(seconds: 30),
    Duration throttleDuration = const Duration(seconds: 30),
    Duration deadCheckDuration = const Duration(minutes: 10),
    OverpassQueryBuilder queryBuilder = const OverpassQueryBuilder(),
  })  : _slots = endpoints
            .map(
              (config) => _InstanceSlot(
                endpoint: config.endpoint,
                maxSlots: config.maxSlots,
              ),
            )
            .toList(),
        _httpClient = httpClient,
        _userAgent = userAgent,
        _requestTimeout = requestTimeout,
        _throttleDuration = throttleDuration,
        _deadCheckDuration = deadCheckDuration,
        _queryBuilder = queryBuilder;

  final List<_InstanceSlot> _slots;
  final http.Client _httpClient;
  final String _userAgent;
  final Duration _requestTimeout;
  final Duration _throttleDuration;
  final Duration _deadCheckDuration;
  final OverpassQueryBuilder _queryBuilder;

  final List<Completer<void>> _waiters = [];

  final _log = Logger('overpass_pool');

  /// Total number of concurrent slots across all endpoints.
  int get totalSlots => _slots.fold(0, (sum, slot) => sum + slot.maxSlots);

  /// No-op: the pool does not own the injected [http.Client]; lifecycle is
  /// managed by the caller (e.g. the Riverpod provider's `onDispose`).
  @override
  void close() {}

  @override
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
    return _dispatch(query);
  }

  /// Dispatches [query] to the best available slot, retrying on throttle.
  ///
  /// Attempts at most `slots.length * 2` times across all instances before
  /// giving up with a [NetworkError].
  Future<String> _dispatch(String query) async {
    final maxAttempts = _slots.length * 2;
    DomainError? lastError;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final slot = await _acquireSlot();
      try {
        final body = await _postToSlot(slot, query);
        slot.markSuccess();
        return body;
      } on _ThrottleSignal {
        _applyThrottle(slot);
        // Continue loop: _acquireSlot will skip the throttled instance.
      } on DomainError {
        rethrow;
      } on Object catch (error, stackTrace) {
        lastError = DomainError.wrap(error, stackTrace);
      } finally {
        slot.releaseSlot();
        _notifyNextWaiter();
      }
    }

    throw lastError ??
        const NetworkError(
          'Overpass pool exhausted all attempts across all instances',
        );
  }

  /// Waits until a healthy slot is available, then claims it.
  ///
  /// If no instance has a free slot right now, parks the caller on a
  /// [Completer].  The completer is resolved either when an in-flight request
  /// finishes (`_notifyNextWaiter`) or when a throttle timer expires.
  Future<_InstanceSlot> _acquireSlot() async {
    while (true) {
      final slot = _pickBestSlot();
      if (slot != null) {
        slot.acquireSlot();
        return slot;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  /// Returns the healthy instance with the most free slots, or `null` when
  /// all instances are throttled or at capacity.
  _InstanceSlot? _pickBestSlot() {
    _InstanceSlot? best;
    for (final slot in _slots) {
      if (!slot.isAvailable) continue;
      if (best == null || slot.freeSlots > best.freeSlots) {
        best = slot;
      }
    }
    return best;
  }

  /// Marks [slot] as throttled and schedules automatic recovery.
  void _applyThrottle(_InstanceSlot slot) {
    slot.markThrottled();
    final recoveryDuration =
        slot.isConsideredDead ? _deadCheckDuration : _throttleDuration;
    _log.warning(
      'Throttling ${slot.endpoint.host} for ${recoveryDuration.inSeconds}s '
      '(consecutive errors: ${slot.consecutiveErrors})',
    );
    unawaited(
      Future<void>.delayed(recoveryDuration).then((_) {
        slot.clearThrottle();
        _notifyNextWaiter();
      }),
    );
  }

  /// Resolves the oldest parked waiter, if any.
  void _notifyNextWaiter() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  /// Performs a single HTTP POST to [slot]'s endpoint.
  ///
  /// Throws [_ThrottleSignal] for retryable conditions (429, 5xx, timeout,
  /// transient body).  Throws [NetworkError] for OOM and non-retryable 4xx.
  Future<String> _postToSlot(_InstanceSlot slot, String query) async {
    final body = 'data=${Uri.encodeQueryComponent(query)}';
    http.Response response;
    try {
      response = await _httpClient
          .post(
            slot.endpoint,
            headers: {
              'User-Agent': _userAgent,
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: body,
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw const _ThrottleSignal();
    } on Object {
      throw const _ThrottleSignal();
    }

    if (response.statusCode == 200) {
      switch (_classifyBody(response.body)) {
        case _BodyKind.ok:
          return response.body;
        case _BodyKind.memoryError:
          throw const NetworkError(
            'Overpass query exceeded server memory ceiling (out of memory)',
          );
        case _BodyKind.transientError:
          throw const _ThrottleSignal();
      }
    }

    if (response.statusCode == 429 ||
        (response.statusCode >= 500 && response.statusCode < 600)) {
      throw const _ThrottleSignal();
    }

    throw NetworkError(
      'Overpass returned non-retryable status ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  /// Transient keywords that Overpass emits in HTTP-200 error bodies.
  static const List<String> _transientKeywords = [
    'runtime error',
    'timed out',
    'timeout',
    'too busy',
    'busy',
    'please reduce',
    'gateway',
  ];

  /// Classifies an HTTP-200 response body into [_BodyKind].
  ///
  /// Mirrors the classification logic in [OverpassClient] so both paths treat
  /// server-side errors consistently.
  static _BodyKind _classifyBody(String body) {
    final lower = body.trimLeft().toLowerCase();
    final looksLikeMarkup = lower.startsWith('<');
    final hasRemark = lower.contains('"remark"');
    if (!looksLikeMarkup && !hasRemark) return _BodyKind.ok;
    if (lower.contains('out of memory') || lower.contains('memory')) {
      return _BodyKind.memoryError;
    }
    if (looksLikeMarkup) return _BodyKind.transientError;
    for (final keyword in _transientKeywords) {
      if (lower.contains(keyword)) return _BodyKind.transientError;
    }
    return _BodyKind.ok;
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Per-instance mutable state: slot counter, throttle flag, error streak.
class _InstanceSlot {
  _InstanceSlot({required this.endpoint, required this.maxSlots});

  final Uri endpoint;
  final int maxSlots;

  int _inFlight = 0;
  bool _throttled = false;
  int _consecutiveErrors = 0;

  int get freeSlots => maxSlots - _inFlight;
  bool get isAvailable => !_throttled && freeSlots > 0;

  /// An instance is considered dead after three consecutive throttle events.
  /// The pool uses [OverpassPool._deadCheckDuration] instead of the normal
  /// throttle duration before re-activating it.
  bool get isConsideredDead => _consecutiveErrors >= 3;

  int get consecutiveErrors => _consecutiveErrors;

  void acquireSlot() => _inFlight++;
  void releaseSlot() => _inFlight--;

  void markThrottled() {
    _throttled = true;
    _consecutiveErrors++;
  }

  void clearThrottle() => _throttled = false;

  void markSuccess() => _consecutiveErrors = 0;
}

/// Thrown internally by [OverpassPool._postToSlot] to signal that the current
/// instance is temporarily unavailable and the request should be retried on
/// another instance.
class _ThrottleSignal implements Exception {
  const _ThrottleSignal();
}

/// How an HTTP-200 Overpass body classifies.
enum _BodyKind { ok, transientError, memoryError }
