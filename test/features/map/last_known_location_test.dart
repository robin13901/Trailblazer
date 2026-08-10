import 'package:auto_explore/features/map/data/last_known_location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  late LastKnownLocationStore store;

  setUp(() {
    // In-memory prefs — no platform channel required.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = LastKnownLocationStore(SharedPreferencesAsync());
  });

  group('LastKnownLocationStore', () {
    test('read returns null when nothing has been written', () async {
      expect(await store.read(), isNull);
    });

    test('write then read round-trips the location', () async {
      await store.write(const LatLng(49.7, 9.2));
      final read = await store.read();
      expect(read, isNotNull);
      expect(read!.latitude, closeTo(49.7, 1e-9));
      expect(read.longitude, closeTo(9.2, 1e-9));
    });

    test('write overwrites a previous value', () async {
      await store.write(const LatLng(49.7, 9.2));
      await store.write(const LatLng(52.52, 13.40));
      final read = await store.read();
      expect(read!.latitude, closeTo(52.52, 1e-9));
      expect(read.longitude, closeTo(13.40, 1e-9));
    });

    test('read returns null when only one coordinate key is present', () async {
      // Persist just the latitude key; a partial write must not yield a
      // half-valid location.
      final prefs = SharedPreferencesAsync();
      await prefs.setDouble(LastKnownLocationStore.kLat, 49.7);
      expect(await store.read(), isNull);
    });
  });
}
