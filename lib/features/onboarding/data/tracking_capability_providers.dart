import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';
import 'package:auto_explore/features/onboarding/data/tracking_capability_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Provider for the [TrackingCapabilityRepository] singleton.
///
/// Plain `Provider<T>` — no `@Riverpod` codegen (see STATE.md Plan 01-01).
final trackingCapabilityRepositoryProvider =
    Provider<TrackingCapabilityRepository>(
  (ref) => TrackingCapabilityRepository(SharedPreferencesAsync()),
);

/// FutureProvider exposing the persisted [TrackingCapability].
///
/// Watchers get the capability loaded from shared preferences.
final trackingCapabilityProvider = FutureProvider<TrackingCapability>(
  (ref) => ref.watch(trackingCapabilityRepositoryProvider).load(),
);
