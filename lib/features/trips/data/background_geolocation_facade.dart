// IMPORTANT: This is the ONLY interface that Wave 2 code (tracking_service,
// tracking_state_provider) may depend on. No file outside
// fgb_background_geolocation_facade.dart should import
// package:flutter_background_geolocation/... directly.

import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';

/// Thin seam that isolates every FGB call site to a single file
/// (fgb_background_geolocation_facade.dart). Wave 2 injects this interface
/// so unit tests can substitute FakeBackgroundGeolocationFacade without
/// touching native code.
abstract interface class BackgroundGeolocationFacade {
  /// Initialise the plugin. Idempotent — calling twice is a no-op on the
  /// second call.
  Future<void> ready();

  Future<void> start();

  Future<void> stop();

  /// Force motion state — used by the manual FAB.
  /// [moving] = true starts recording; false stops.
  Future<void> changePace({required bool moving});

  /// Update the sticky FGS notification text (Android only). No-op on iOS.
  Future<void> setNotificationText(String text);

  /// Ask FGB to open Android's Ignore-Battery-Optimizations settings screen.
  /// No-op on iOS.
  Future<void> showIgnoreBatteryOptimizations();

  Stream<FixInput> get onLocation;

  Stream<MotionChange> get onMotionChange;

  Stream<ActivityChange> get onActivityChange;

  /// Current in-flight state, for cold-start hydration.
  Future<FgbState> currentState();
}

/// Motion state change emitted when FGB transitions between stationary and
/// moving.
class MotionChange {
  const MotionChange({required this.isMoving, required this.ts});

  final bool isMoving;
  final DateTime ts;
}

/// Activity classifier change emitted by FGB's motion-activity engine.
class ActivityChange {
  const ActivityChange({
    required this.activityType,
    required this.confidence,
    required this.ts,
  });

  /// FGB activity type string (e.g. 'still', 'in_vehicle', 'on_foot').
  final String activityType;

  /// Classifier confidence 0–100.
  final int confidence;

  final DateTime ts;
}

/// Snapshot of FGB plugin state, used for cold-start hydration.
class FgbState {
  const FgbState({required this.enabled, required this.isMoving});

  final bool enabled;
  final bool isMoving;
}
