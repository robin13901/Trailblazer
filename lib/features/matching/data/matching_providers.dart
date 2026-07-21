// Phase 4 rescope Wave 2 (Plan 04-13 + 04-15):
// Riverpod providers for the Overpass client stack + WayCandidateSource.
// Phase 5 (Plan 05-06): matcherIsolateProvider added.
// Phase 5 (Plan 05-07): tripMatchCoordinatorProvider added;
//   tripRoadFetchCoordinatorProvider updated to pass matchCoordinator.
//
// Uses plain `Provider<T>` — no `@Riverpod` codegen (STATE Plan 01-01).
// Tests override any of these providers via `ProviderScope.overrides` /
// `ProviderContainer(overrides:)`.

import 'dart:async';

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/db/daos/overpass_way_cache_dao.dart';
import 'package:auto_explore/features/matching/data/connectivity_seam.dart';
import 'package:auto_explore/features/matching/data/match_progress_provider.dart';
import 'package:auto_explore/features/matching/data/matcher_isolate.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:auto_explore/features/matching/data/overpass_way_candidate_source.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/trip_match_coordinator.dart';
import 'package:auto_explore/features/matching/data/trip_road_fetch_coordinator.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_providers.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Primary Overpass endpoint. Tests override with a `MockClient`-hosted URL
/// or an in-memory fixture endpoint.
final overpassEndpointProvider = Provider<Uri>(
  (_) => kOverpassPrimaryEndpoint,
);

/// Fallback Overpass endpoint. Selected via live probe on 2026-07-08 (Kumi +
/// private.coffee unresponsive; VK Maps mirror healthy — see
/// `overpass_client.dart` docstring).
final overpassFallbackEndpointProvider = Provider<Uri>(
  (_) => kOverpassFallbackEndpoint,
);

/// Shared `http.Client` for outbound HTTP. Closed automatically when the
/// container disposes.
final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Overpass client wired to the shared HTTP client and endpoint providers.
final overpassClientProvider = Provider<OverpassClient>((ref) {
  final client = OverpassClient(
    client: ref.watch(httpClientProvider),
    primaryEndpoint: ref.watch(overpassEndpointProvider),
    fallbackEndpoint: ref.watch(overpassFallbackEndpointProvider),
  );
  // OverpassClient.close() would double-close the shared http.Client; we
  // deliberately do NOT register a dispose hook here — the httpClient's
  // own onDispose is the single lifecycle owner.
  return client;
});

/// Slippy tile-bbox math — pure functions, no I/O. Held as `const` at call
/// sites; the provider is a thin indirection for tests that want to
/// substitute a mock projection.
final tileBboxMathProvider = Provider<TileBboxMath>(
  (_) => const TileBboxMath(),
);

/// Runtime [WayCandidateSource] — cache-first via [OverpassWayCacheDao],
/// network-fill via [OverpassClient]. Tests override with an in-memory
/// implementation (see `test/helpers/fixture_way_candidate_source.dart`).
final wayCandidateSourceProvider = Provider<WayCandidateSource>((ref) {
  return OverpassWayCandidateSource(
    client: ref.watch(overpassClientProvider),
    cacheDao: ref.watch(appDatabaseProvider).overpassWayCacheDao,
    tileMath: ref.watch(tileBboxMathProvider),
  );
});

/// Real connectivity check via `connectivity_plus`. Tests override this with
/// a `FakeConnectivitySeam` under `test/helpers/`.
final connectivitySeamProvider = Provider<ConnectivitySeam>(
  (_) => ConnectivityPlusSeam(),
);

/// Runtime coordinator wiring trip-close and lifecycle-resume events into
/// the road-fetch flow. Consumed by `TrackingService` (trip-close) and
/// `lib/app.dart` (resume drain).
///
/// Passes [tripMatchCoordinatorProvider] so the fetch coordinator can invoke
/// the Phase 5 match pipeline immediately after each trip transitions to
/// `pending` (fire-and-forget, unawaited).
final tripRoadFetchCoordinatorProvider =
    Provider<TripRoadFetchCoordinator>((ref) {
  return TripRoadFetchCoordinator(
    source: ref.watch(wayCandidateSourceProvider),
    pendingDao: ref.watch(appDatabaseProvider).pendingRoadFetchesDao,
    repository: ref.watch(tripsRepositoryProvider),
    connectivity: ref.watch(connectivitySeamProvider),
    tripsDao: TripsDao(ref.watch(appDatabaseProvider)),
    tileMath: ref.watch(tileBboxMathProvider),
    matchCoordinator: ref.watch(tripMatchCoordinatorProvider),
    // Surface road-fetch tile progress to the same pill the matcher uses
    // (writes the tripId → 0.0..1.0 slot). Cleared at the fetch→match handoff.
    progressSink: (tripId, frac) =>
        ref.read(matchProgressProvider.notifier).update(tripId, frac),
    progressClearSink: (tripId) =>
        ref.read(matchProgressProvider.notifier).clear(tripId),
  );
});

/// Phase 5 (Plan 05-07): coordinator wiring pending trips into the
/// matcher isolate and DAO writes.
///
/// Phase 10 (Plan 10-05): onIntervalsLanded wired to a recompute-only trigger
/// (Decision 6 auto seam). Fires CoverageComputeService.recompute() after
/// intervals land — recompute-only (rebuilds region rows from existing
/// intervals), NOT a full re-match. Fire-and-forget; failures are logged and
/// never break matching.
final tripMatchCoordinatorProvider = Provider<TripMatchCoordinator>((ref) {
  final computeService = ref.watch(coverageComputeServiceProvider);
  final log = Logger('matching_providers');

  return TripMatchCoordinator(
    source: ref.watch(wayCandidateSourceProvider),
    matcherIsolate: ref.watch(matcherIsolateProvider),
    tripsDao: TripsDao(ref.watch(appDatabaseProvider)),
    tripsRepository: ref.watch(tripsRepositoryProvider),
    intervalsDao: DrivenWayIntervalsDao(ref.watch(appDatabaseProvider)),
    progressSink: (tripId, frac) =>
        ref.read(matchProgressProvider.notifier).update(tripId, frac),
    progressClearSink: (tripId) =>
        ref.read(matchProgressProvider.notifier).clear(tripId),
    onIntervalsLanded: (tripId) {
      // Auto recompute (Decision 6 auto seam). Uses the FULL recompute()
      // (all-trips union bbox), NOT the incremental recomputeForTrip().
      //
      // Why not incremental: recomputeForTrip() upserts absolute driven_length_m
      // for only the regions inside the NEW trip's bbox, and can only attribute
      // ways whose centroid falls in that bbox. A later short drive with a
      // narrower bbox therefore OVERWRITES a region's total with a partial sum
      // that omits earlier trips' ways outside the new bbox — coverage % goes
      // DOWN (non-monotonic; observed Kleinheubach 34.1% → 23.2%). The full
      // recompute() rebuilds every region from the all-trips union and is
      // known-correct/monotonic. Heavier, but fire-and-forget, once per match.
      unawaited(
        computeService.recompute().then((result) {
          result.when(
            ok: (rows) => log.fine(
              'auto-recompute after trip $tripId: $rows regions written',
            ),
            err: (e) => log.warning(
              'auto-recompute after trip $tripId failed: $e',
            ),
          );
        }),
      );
    },
  );
});

/// Long-lived matcher isolate provider (Plan 05-06). One instance per
/// ProviderContainer lifetime; disposed when the container is torn down.
///
/// The isolate is started immediately (fire-and-forget); consumers that
/// need to enqueue the FIRST job should `await isolate.start()` before
/// calling `isolate.match()`. Subsequent calls do not need to await start
/// since the isolate stays warm.
///
/// Consumed by the trip-match coordinator (Plan 05-07).
final matcherIsolateProvider = Provider<MatcherIsolate>((ref) {
  final isolate = MatcherIsolate();
  // Fire-and-forget start; the coordinator (05-07) will await start()
  // before enqueueing its first job to ensure the worker is warm.
  unawaited(isolate.start());
  ref.onDispose(isolate.dispose);
  return isolate;
});
