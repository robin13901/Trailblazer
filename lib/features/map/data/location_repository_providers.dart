import 'package:auto_explore/features/map/data/location_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider for the singleton [LocationRepository].
///
/// Plain `Provider` — no `@Riverpod` codegen (see STATE.md Plan 01-01 decision).
final locationRepositoryProvider =
    Provider<LocationRepository>((ref) => const LocationRepository());
