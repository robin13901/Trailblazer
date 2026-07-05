import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides the [TripsDao] backed by the singleton app database.
///
/// Plain Provider — no @Riverpod codegen (STATE.md 01-01 decision).
final tripsDaoProvider = Provider<TripsDao>((ref) {
  return TripsDao(ref.watch(appDatabaseProvider));
});

/// Provides the [TripsRepository] backed by [tripsDaoProvider].
///
/// Wave 2 (TrackingNotifier) consumes this provider.
final tripsRepositoryProvider = Provider<TripsRepository>((ref) {
  return TripsRepository(ref.watch(tripsDaoProvider));
});
