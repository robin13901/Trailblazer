import 'package:auto_explore/features/matching/data/live_tile_prefetch_service.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/trips/data/background_geolocation_facade_provider.dart';
import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:auto_explore/features/trips/domain/tracking_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides the [TripsRepositoryPointsSink] adapter that bridges the domain
/// TripPointsSink contract to the Drift-backed TripsRepository.
///
/// Plain Provider — no @Riverpod codegen (STATE.md 01-01 decision).
final tripsRepositoryPointsSinkProvider =
    Provider<TripsRepositoryPointsSink>((ref) {
  return TripsRepositoryPointsSink(ref.watch(tripsRepositoryProvider));
});

/// Provides the singleton [LiveTilePrefetchService] (Idea #6 Half A).
///
/// Warms the Overpass tile cache for the driven-so-far corridor during an
/// active recording so the trip-end match starts cache-hot. Plain Provider —
/// no @Riverpod codegen (STATE.md 01-01 decision).
final liveTilePrefetchServiceProvider =
    Provider<LiveTilePrefetchService>((ref) {
  return LiveTilePrefetchService(
    source: ref.watch(wayCandidateSourceProvider),
    tripsDao: ref.watch(tripsDaoProvider),
    connectivity: ref.watch(connectivitySeamProvider),
    tileMath: ref.watch(tileBboxMathProvider),
  );
});

/// Provides the singleton [TrackingService].
///
/// The service is long-lived (not recreated on hot reload). The Riverpod
/// TrackingNotifier reads this provider and listens to
/// [TrackingService.stateStream].
///
/// Plain Provider — no @Riverpod codegen (STATE.md 01-01 decision).
final trackingServiceProvider = Provider<TrackingService>((ref) {
  final service = TrackingService(
    facade: ref.watch(backgroundGeolocationFacadeProvider),
    repository: ref.watch(tripsRepositoryProvider),
    pointsSink: ref.watch(tripsRepositoryPointsSinkProvider),
    roadFetchCoordinator: ref.watch(tripRoadFetchCoordinatorProvider),
    tilePrefetch: ref.watch(liveTilePrefetchServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
