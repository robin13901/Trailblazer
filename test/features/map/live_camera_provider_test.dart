import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
  group('liveCameraProvider', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('initial state is null — no reading before first onCameraMove', () {
      expect(container.read(liveCameraProvider), isNull);
    });

    test('update() with a CameraPosition sets lat/lon/zoom', () {
      container.read(liveCameraProvider.notifier).update(
            const CameraPosition(target: LatLng(50.5, 9.4), zoom: 13),
          );

      final live = container.read(liveCameraProvider);
      expect(live, isNotNull);
      expect(live!.latitude, closeTo(50.5, 1e-9));
      expect(live.longitude, closeTo(9.4, 1e-4));
      expect(live.zoom, 13);
    });

    test('two updates with the same position produce equal LiveCamera values', () {
      const pos = CameraPosition(target: LatLng(50.5, 9.4), zoom: 13);

      container.read(liveCameraProvider.notifier).update(pos);
      final first = container.read(liveCameraProvider);

      container.read(liveCameraProvider.notifier).update(pos);
      final second = container.read(liveCameraProvider);

      expect(first, equals(second));
      expect(first.hashCode, equals(second.hashCode));
    });

    test('a second update with a different zoom replaces the state', () {
      container.read(liveCameraProvider.notifier).update(
            const CameraPosition(target: LatLng(50.5, 9.4), zoom: 13),
          );

      container.read(liveCameraProvider.notifier).update(
            const CameraPosition(target: LatLng(50.5, 9.4), zoom: 15),
          );

      final live = container.read(liveCameraProvider);
      expect(live, isNotNull);
      expect(live!.zoom, 15);
    });

    test('LiveCamera value equality holds (same values, separate instances)', () {
      const a = LiveCamera(latitude: 50.5, longitude: 9.4, zoom: 13);
      const b = LiveCamera(latitude: 50.5, longitude: 9.4, zoom: 13);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('LiveCamera instances with different latitude are not equal', () {
      const a = LiveCamera(latitude: 50.5, longitude: 9.4, zoom: 13);
      const b = LiveCamera(latitude: 51, longitude: 9.4, zoom: 13);
      expect(a, isNot(equals(b)));
    });

    test('LiveCamera instances with different zoom are not equal', () {
      const a = LiveCamera(latitude: 50.5, longitude: 9.4, zoom: 13);
      const b = LiveCamera(latitude: 50.5, longitude: 9.4, zoom: 14);
      expect(a, isNot(equals(b)));
    });
  });
}
