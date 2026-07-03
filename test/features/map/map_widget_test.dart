import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
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
///
/// Pass [styleOverride] to fix the active map style asset regardless of the
/// test-runner's platform brightness (e.g. to assert the dark style is used).
Future<void> pumpMapWidget(
  WidgetTester tester, {
  PermissionStatus permissionStatus = PermissionStatus.denied,
  MapWidget widget = const MapWidget(),
  String? styleOverride,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationPermissionProvider.overrideWith(
          () => _FakeLocationPermissionNotifier(permissionStatus),
        ),
        if (styleOverride != null)
          mapStyleAssetProvider.overrideWith(
            () => _FixedMapStyleNotifier(styleOverride),
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

/// Stub notifier that returns a fixed style asset path.
///
/// Used to test a specific style is forwarded to [MapLibreMap.styleString]
/// independent of the test-runner's platform brightness.
class _FixedMapStyleNotifier extends MapStyleAssetNotifier {
  _FixedMapStyleNotifier(this._asset);

  final String _asset;

  @override
  String build() => _asset;
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

    testWidgets('default style is the light style (provider-driven)', (
      tester,
    ) async {
      // mapStyleAssetProvider initialises from PlatformDispatcher brightness;
      // test-runner default is Brightness.light → light asset expected.
      await pumpMapWidget(
        tester,
        styleOverride: 'assets/map_style_light.json',
      );

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.styleString, 'assets/map_style_light.json');
    });

    testWidgets('overriding style provider passes dark asset to MapLibreMap', (
      tester,
    ) async {
      // Verify the map uses the style from mapStyleAssetProvider, not a
      // constructor param. Override the provider to serve the dark asset.
      await pumpMapWidget(
        tester,
        styleOverride: 'assets/map_style_dark.json',
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
