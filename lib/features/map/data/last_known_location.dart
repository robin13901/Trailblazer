import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's last-known map location across process restarts so the
/// map can open where they last were instead of flashing the Berlin fallback
/// on a cold start (issue #5b).
///
/// A thin, constructor-injectable wrapper around [SharedPreferencesAsync] that
/// carries no in-memory cache — mirrors the shape of `AppPrefs`
/// (`core/prefs/app_prefs.dart`). Deliberately NOT added to `AppPrefs`: that
/// file is the single owner of the matcher / coverage migration version
/// stamps, and this map-only seed has no business living next to them.
///
/// Storing lat/lon as two doubles keeps the read synchronous-friendly for the
/// cold-start seed: `main()` awaits [read] once before `runApp`, then hands the
/// value to the map via a provider override, so `MapWidget` has it available at
/// first build without racing the platform channel.
class LastKnownLocationStore {
  const LastKnownLocationStore(this._prefs);

  static const String kLat = 'last_known_lat';
  static const String kLon = 'last_known_lon';

  final SharedPreferencesAsync _prefs;

  /// Returns the last persisted location, or `null` when none has ever been
  /// written (fresh install / first launch). Both keys must be present for a
  /// valid result.
  Future<LatLng?> read() async {
    final lat = await _prefs.getDouble(kLat);
    final lon = await _prefs.getDouble(kLon);
    if (lat == null || lon == null) return null;
    return LatLng(lat, lon);
  }

  /// Persists [location] as the last-known map location.
  Future<void> write(LatLng location) async {
    await _prefs.setDouble(kLat, location.latitude);
    await _prefs.setDouble(kLon, location.longitude);
  }
}

/// Provider for the singleton [LastKnownLocationStore].
///
/// Plain `Provider<T>` per STATE Plan 01-01 (no `@Riverpod` codegen).
final lastKnownLocationStoreProvider = Provider<LastKnownLocationStore>(
  (ref) => LastKnownLocationStore(SharedPreferencesAsync()),
);

/// The map's cold-start camera seed, preloaded in `main()` before `runApp` and
/// injected via `overrideWithValue`. `null` when nothing was persisted yet (or
/// in tests that don't override it) — callers fall back to the Berlin default.
///
/// Read synchronously by `MapWidget` at first build, which is why it is a plain
/// value provider seeded ahead of time rather than a `FutureProvider` that
/// would race the map's construction.
final initialMapSeedProvider = Provider<LatLng?>((ref) => null);
