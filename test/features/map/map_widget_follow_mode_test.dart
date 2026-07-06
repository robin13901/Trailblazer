import 'package:auto_explore/features/map/data/tile_server_providers.dart';
import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../helpers/fake_maplibre_platform.dart';
import '../../helpers/fake_tile_server.dart';

/// Fixed [CameraState] notifier used to force a specific [FollowMode]
/// for each mapping-branch assertion.
class _FixedCameraStateNotifier extends CameraStateNotifier {
  _FixedCameraStateNotifier(this._initial);

  final CameraState _initial;

  @override
  CameraState build() => _initial;
}

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

class _FixedMapStyleNotifier extends MapStyleAssetNotifier {
  _FixedMapStyleNotifier(this._asset);

  final String _asset;

  @override
  String build() => _asset;
}

Future<MapLibreMap> _pumpAndReadMap(
  WidgetTester tester,
  FollowMode followMode,
) async {
  final camera = const CameraState(
    latitude: 0,
    longitude: 0,
    zoom: 15,
  ).copyWith(followMode: followMode);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationPermissionProvider.overrideWith(
          () => _FakeLocationPermissionNotifier(PermissionStatus.granted),
        ),
        tileServerProvider.overrideWith((_) async {
          final server = FakeTileServer();
          await server.start();
          return server;
        }),
        mapStyleAssetProvider.overrideWith(
          () => _FixedMapStyleNotifier('assets/map_style_light.json'),
        ),
        cameraStateProvider.overrideWith(
          () => _FixedCameraStateNotifier(camera),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: MapWidget())),
    ),
  );
  // Resolve the tileServerProvider FutureProvider.
  await tester.pump();
  return tester.widget<MapLibreMap>(find.byType(MapLibreMap));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final prev = MapLibrePlatform.createInstance;
    addTearDown(() => MapLibrePlatform.createInstance = prev);
    MapLibrePlatform.createInstance = FakeMapLibrePlatform.new;
  });

  group('MapWidget FollowMode → MyLocationTrackingMode mapping', () {
    testWidgets(
      'FollowMode.none maps to MyLocationTrackingMode.none',
      (tester) async {
        final map = await _pumpAndReadMap(tester, FollowMode.none);
        expect(map.myLocationTrackingMode, MyLocationTrackingMode.none);
      },
    );

    testWidgets(
      'FollowMode.location maps to MyLocationTrackingMode.tracking',
      (tester) async {
        final map = await _pumpAndReadMap(tester, FollowMode.location);
        expect(map.myLocationTrackingMode, MyLocationTrackingMode.tracking);
      },
    );

    testWidgets(
      'FollowMode.locationAndHeading maps to MyLocationTrackingMode.trackingCompass',
      (tester) async {
        final map =
            await _pumpAndReadMap(tester, FollowMode.locationAndHeading);
        expect(
          map.myLocationTrackingMode,
          MyLocationTrackingMode.trackingCompass,
        );
      },
    );
  });
}
