import 'package:auto_explore/features/onboarding/data/tracking_capability.dart';
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
}
