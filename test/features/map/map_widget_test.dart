import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../helpers/fake_maplibre_platform.dart';

/// Helper: pumps [MapWidget] wrapped in [MaterialApp] + [ProviderScope].
///
/// Overrides [locationPermissionProvider] with a stub that returns
/// [PermissionStatus.denied] synchronously (no platform channel call).
/// Tests that need a specific status should pass [permissionStatus].
Future<void> pumpMapWidget(
  WidgetTester tester, {
  PermissionStatus permissionStatus = PermissionStatus.denied,
  MapWidget widget = const MapWidget(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationPermissionProvider.overrideWith(
          () => _FakeLocationPermissionNotifier(permissionStatus),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: widget)),
    ),
  );
}

/// Stub notifier that returns a fixed [PermissionStatus] without calling
/// the permission_handler platform channel.
class _FakeLocationPermissionNotifier
    extends AsyncNotifier<PermissionStatus>
    implements LocationPermissionNotifier {
  _FakeLocationPermissionNotifier(this._status);

  final PermissionStatus _status;

  @override
  Future<PermissionStatus> build() async => _status;

  @override
  Future<PermissionStatus> requestOnce() async => _status;

  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Replace the MapLibre platform factory for the whole file so that
  // buildView returns a SizedBox.shrink() instead of a real PlatformView.
  // This lets widget tests inspect the Dart-layer config (gesture flags,
  // styleString, etc.) without needing the native plugin.
  setUp(() {
    final prev = MapLibrePlatform.createInstance;
    addTearDown(() => MapLibrePlatform.createInstance = prev);
    MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;
  });

  group('MapWidget — Phase-2 gesture config', () {
    testWidgets('builds without throwing and contains MapLibreMap', (
      tester,
    ) async {
      await pumpMapWidget(tester);
      expect(find.byType(MapLibreMap), findsOneWidget);
    });

    testWidgets('tilt is disabled, pan/zoom/rotate are enabled', (
      tester,
    ) async {
      await pumpMapWidget(tester);

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));

      expect(map.tiltGesturesEnabled, isFalse,
          reason: '02-CONTEXT.md mandates flat 2D — no tilt gesture');
      expect(map.rotateGesturesEnabled, isTrue);
      expect(map.zoomGesturesEnabled, isTrue);
      expect(map.scrollGesturesEnabled, isTrue);
    });

    testWidgets('default styleAsset is the light style', (tester) async {
      await pumpMapWidget(tester);

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.styleString, 'assets/map_style_light.json');
    });

    testWidgets('custom styleAsset is passed through to MapLibreMap', (
      tester,
    ) async {
      await pumpMapWidget(
        tester,
        widget: const MapWidget(styleAsset: 'assets/map_style_dark.json'),
      );

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.styleString, 'assets/map_style_dark.json');
    });

    testWidgets('compass is enabled and positioned at topRight', (
      tester,
    ) async {
      await pumpMapWidget(tester);

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.compassEnabled, isTrue);
      expect(map.compassViewPosition, CompassViewPosition.topRight);
    });

    testWidgets(
        'myLocationEnabled is false when permission denied (no blue dot)',
        (tester) async {
      await pumpMapWidget(tester);

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.myLocationEnabled, isFalse);
    });

    testWidgets(
        'myLocationEnabled is true when permission granted (blue dot shown)',
        (tester) async {
      await pumpMapWidget(
        tester,
        permissionStatus: PermissionStatus.granted,
      );
      // Async notifier resolves on the next frame.
      await tester.pump();

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.myLocationEnabled, isTrue);
    });

    testWidgets('initial camera targets Berlin at zoom 15', (tester) async {
      await pumpMapWidget(tester);

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.initialCameraPosition, isNotNull);
      expect(
        map.initialCameraPosition!.target.latitude,
        closeTo(52.52, 0.01),
      );
      expect(
        map.initialCameraPosition!.target.longitude,
        closeTo(13.40, 0.01),
      );
      expect(map.initialCameraPosition!.zoom, 15);
    });
  });
}
