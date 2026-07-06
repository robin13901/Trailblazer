import 'dart:io' show Platform;

import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and loads the [TrackingCapability] flag via
/// [SharedPreferencesAsync].
///
/// Constructor injection keeps this testable with
/// `InMemorySharedPreferencesAsync` (no platform channel needed).
class TrackingCapabilityRepository {
  TrackingCapabilityRepository(this._prefs);

  static const String prefsKey = 'tracking_capability';

  final SharedPreferencesAsync _prefs;

  /// Loads the stored capability.
  ///
  /// Returns [TrackingCapability.fullAuto] if no value has been persisted yet
  /// (consistent with a granted-permissions install).
  Future<TrackingCapability> load() async {
    final v = await _prefs.getString(prefsKey);
    return v == 'manual_only'
        ? TrackingCapability.manualOnly
        : TrackingCapability.fullAuto;
  }

  /// Persists [capability].
  Future<void> save(TrackingCapability capability) => _prefs.setString(
        prefsKey,
        capability == TrackingCapability.manualOnly ? 'manual_only' : 'full_auto',
      );

  /// Resolves the effective [TrackingCapability] from the three permission
  /// grants that gate background auto-recording.
  ///
  /// Rule (Plan 03-1-02 H5 fix — closes the Samsung Adaptive-Battery gap):
  ///   `fullAuto` iff ALL of:
  ///     - [always] is granted (background location), AND
  ///     - [notification] is granted (FGS notification), AND
  ///     - on Android: [ignoreBatteryOptimizations] is granted
  ///       (Samsung / OEM battery killers otherwise nuke the FGS mid-trip).
  ///   Otherwise → `manualOnly`.
  ///
  /// `!isGranted` is the universal predicate (STATE Plan 03-05) — covers
  /// denied / restricted / limited / permanentlyDenied uniformly.
  ///
  /// On iOS the [ignoreBatteryOptimizations] argument is ignored — iOS has
  /// no equivalent concept and callers pass `PermissionStatus.granted`.
  ///
  /// Pure helper — no I/O, no side effects. Callers wire this into the
  /// onboarding ladder + the settings-app-resume banner refresh.
  static TrackingCapability resolveCapability({
    required PermissionStatus always,
    required PermissionStatus notification,
    required PermissionStatus ignoreBatteryOptimizations,
    bool? isAndroidOverride,
  }) {
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
    if (!always.isGranted) return TrackingCapability.manualOnly;
    if (isAndroid && !notification.isGranted) {
      return TrackingCapability.manualOnly;
    }
    if (isAndroid && !ignoreBatteryOptimizations.isGranted) {
      return TrackingCapability.manualOnly;
    }
    return TrackingCapability.fullAuto;
  }
}
