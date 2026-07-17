import 'package:auto_explore/features/map/data/tile_provider_config.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
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
///
/// Overrides [tileProviderConfigProvider] with a fixture config so the
/// map-style URL derived by [mapStyleUrlProvider] is deterministic across
/// test runs.
///
/// Pass [styleOverride] to fix the active MapTiler style URL regardless of
/// the test-runner's platform brightness (e.g. to assert the dark URL is used).
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
        // Fixture MapTiler config with a non-empty key so the resolved URL
        // is well-formed (no debug assertion trip).
        tileProviderConfigProvider.overrideWithValue(
          const TileProviderConfig(
            lightStyle: MapTilerStyle.dataviz,
            darkStyle: MapTilerStyle.datavizDark,
            apiKey: 'test-key',
          ),
        ),
        // Suppress the real TrackingService (which spawns background timers)
        // by returning TrackingIdle synchronously. MapWidget reads this to
        // gate native-dot suppression (Plan 10-02).
        trackingStateProvider.overrideWith(_IdleTrackingNotifier.new),
        if (styleOverride != null)
          mapStyleUrlProvider.overrideWith(
            () => _FixedMapStyleUrlNotifier(styleOverride),
          ),
      ],
      child: MaterialApp(home: Scaffold(body: widget)),
    ),
  );
  // Allow provider initialisation to settle.
  await tester.pump();
}

/// Stub notifier that returns a fixed [PermissionStatus] without calling
/// the permission_handler platform channel.
class _FakeLocationPermissionNotifier extends AsyncNotifier<PermissionStatus>
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

/// Stub [TrackingNotifier] that returns [TrackingIdle] synchronously.
///
/// Overriding [trackingStateProvider] prevents [MapWidget] from firing the
/// real [TrackingService.init()] (which spawns background timers) and keeps
/// the test environment clean.
class _IdleTrackingNotifier extends Notifier<TrackingState>
    implements TrackingNotifier {
  @override
  TrackingState build() => const TrackingIdle();

  @override
  Future<void> startManual() async {}

  @override
  Future<void> stopActive() async {}
}

/// Stub notifier that returns a fixed MapTiler style URL.
///
/// Used to test a specific URL is forwarded to [MapLibreMap.styleString]
/// independent of the test-runner's platform brightness.
class _FixedMapStyleUrlNotifier extends MapStyleUrlNotifier {
  _FixedMapStyleUrlNotifier(this._url);

  final String _url;

  @override
  String build() => _url;
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

      expect(
        map.tiltGesturesEnabled,
        isFalse,
        reason: '02-CONTEXT.md mandates flat 2D — no tilt gesture',
      );
      expect(map.rotateGesturesEnabled, isTrue);
      expect(map.zoomGesturesEnabled, isTrue);
      expect(map.scrollGesturesEnabled, isTrue);
    });

    testWidgets('default style is a MapTiler URL (provider-driven)', (
      tester,
    ) async {
      // With the fixture TileProviderConfig (light=dataviz, dark=datavizDark)
      // and the test-runner's default light brightness, the URL should point
      // at the light dataviz style.
      await pumpMapWidget(tester);

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.styleString, contains('/maps/dataviz/'));
      expect(map.styleString, contains('key=test-key'));
    });

    testWidgets('overriding style provider passes dark URL to MapLibreMap', (
      tester,
    ) async {
      // Verify the map uses the URL from mapStyleUrlProvider, not a
      // constructor param. Override the provider to serve a dark URL.
      const darkUrl =
          'https://api.maptiler.com/maps/dataviz-dark/style.json?key=test-key';
      await pumpMapWidget(tester, styleOverride: darkUrl);

      final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
      expect(map.styleString, darkUrl);
    });

    testWidgets(
      'built-in compass is hidden (04-19: custom AlignNorthButton owns top-right)',
      (tester) async {
        await pumpMapWidget(tester);

        final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
        // Plan 04-19 (2026-07-09): MapLibre's built-in top-right compass
        // is disabled so the custom glass AlignNorthButton (rendered by
        // MapScreen mirroring SettingsGlassButton) is the sole compass UI.
        expect(map.compassEnabled, isFalse);
      },
    );

    testWidgets(
      'myLocationEnabled is false when permission denied (no blue dot)',
      (tester) async {
        await pumpMapWidget(tester);

        final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
        expect(map.myLocationEnabled, isFalse);
      },
    );

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
      },
    );

    testWidgets('initial camera targets Berlin at zoom 16', (tester) async {
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
      // Plan 04-18 (2026-07-08 drive feedback): zoom 16 = one level in from
      // 04-16-1's 15 per user request. Mirrors CameraState.initial.zoom.
      expect(map.initialCameraPosition!.zoom, 16);
    });

    testWidgets(
      'attribution button is pushed off-screen (04-16-1 reverts 04-12)',
      (tester) async {
        await pumpMapWidget(tester);

        final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
        // Plan 04-16-1 Task 2 (2026-07-08 UX polish) reverts Plan 04-12 Task 1.
        // The on-map (i) icon is pushed off-screen via Point(-9999, -9999);
        // legally required MapTiler + OSM credits are surfaced clickably in
        // Settings > About (04-11 AboutSection). Matches the Phase-2 Wave-7
        // pattern (STATE 2026-07-04).
        expect(
          map.attributionButtonPosition,
          AttributionButtonPosition.bottomLeft,
        );
        expect(
          map.attributionButtonMargins,
          isNotNull,
          reason: '04-16-1: attribution button must be pushed off-screen',
        );
        expect(map.attributionButtonMargins!.x, -9999);
        expect(map.attributionButtonMargins!.y, -9999);
      },
    );
  });
}
