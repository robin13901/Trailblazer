// Phase 4 rescope Wave 2 (Plan 04-13 + 04-15):
// Riverpod providers for the Overpass client stack + WayCandidateSource.
//
// Uses plain `Provider<T>` — no `@Riverpod` codegen (STATE Plan 01-01).
// Tests override any of these providers via `ProviderScope.overrides` /
// `ProviderContainer(overrides:)`.

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/overpass_way_cache_dao.dart';
import 'package:auto_explore/features/matching/data/connectivity_seam.dart';
import 'package:auto_explore/features/matching/data/overpass_client.dart';
import 'package:auto_explore/features/matching/data/overpass_way_candidate_source.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/trip_road_fetch_coordinator.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

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
final tripRoadFetchCoordinatorProvider =
    Provider<TripRoadFetchCoordinator>((ref) {
  return TripRoadFetchCoordinator(
    source: ref.watch(wayCandidateSourceProvider),
    pendingDao: ref.watch(appDatabaseProvider).pendingRoadFetchesDao,
    repository: ref.watch(tripsRepositoryProvider),
    connectivity: ref.watch(connectivitySeamProvider),
    tileMath: ref.watch(tileBboxMathProvider),
  );
});
