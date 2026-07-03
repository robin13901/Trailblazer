import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../helpers/fake_maplibre_platform.dart';

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
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapWidget())),
      );
      expect(find.byType(MapLibreMap), findsOneWidget);
    });

    testWidgets('tilt is disabled, pan/zoom/rotate are enabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapWidget())),
      );

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));

      expect(map.tiltGesturesEnabled, isFalse,
          reason: '02-CONTEXT.md mandates flat 2D — no tilt gesture');
      expect(map.rotateGesturesEnabled, isTrue);
      expect(map.zoomGesturesEnabled, isTrue);
      expect(map.scrollGesturesEnabled, isTrue);
    });

    testWidgets('default styleAsset is the light style', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapWidget())),
      );

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.styleString, 'assets/map_style_light.json');
    });

    testWidgets('custom styleAsset is passed through to MapLibreMap', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MapWidget(styleAsset: 'assets/map_style_dark.json'),
          ),
        ),
      );

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.styleString, 'assets/map_style_dark.json');
    });

    testWidgets('compass is enabled and positioned at topRight', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapWidget())),
      );

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.compassEnabled, isTrue);
      expect(map.compassViewPosition, CompassViewPosition.topRight);
    });

    testWidgets('myLocationEnabled is false (location deferred to 02-03)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapWidget())),
      );

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.myLocationEnabled, isFalse);
    });

    testWidgets('initial camera targets Berlin at zoom 15', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapWidget())),
      );

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
