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

/// Provides the singleton [TrackingService].
///
/// The service is long-lived (not recreated on hot reload). The Riverpod
/// TrackingNotifier reads this provider and listens to [TrackingService.stateStream].
///
/// Plain Provider — no @Riverpod codegen (STATE.md 01-01 decision).
final trackingServiceProvider = Provider<TrackingService>((ref) {
  final service = TrackingService(
    facade: ref.watch(backgroundGeolocationFacadeProvider),
    repository: ref.watch(tripsRepositoryProvider),
    pointsSink: ref.watch(tripsRepositoryPointsSinkProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
