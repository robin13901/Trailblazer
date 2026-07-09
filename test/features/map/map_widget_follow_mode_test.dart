import 'package:auto_explore/features/map/data/tile_provider_config.dart';
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

class _FixedMapStyleUrlNotifier extends MapStyleUrlNotifier {
  _FixedMapStyleUrlNotifier(this._url);

  final String _url;

  @override
  String build() => _url;
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

  const styleUrl =
      'https://api.maptiler.com/maps/dataviz/style.json?key=test-key';

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationPermissionProvider.overrideWith(
          () => _FakeLocationPermissionNotifier(PermissionStatus.granted),
        ),
        tileProviderConfigProvider.overrideWithValue(
          const TileProviderConfig(
            lightStyle: MapTilerStyle.dataviz,
            darkStyle: MapTilerStyle.datavizDark,
            apiKey: 'test-key',
          ),
        ),
        mapStyleUrlProvider.overrideWith(
          () => _FixedMapStyleUrlNotifier(styleUrl),
        ),
        cameraStateProvider.overrideWith(
          () => _FixedCameraStateNotifier(camera),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: MapWidget())),
    ),
  );
  // Let overrides settle.
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
      'FollowMode.locationAndHeading maps to MyLocationTrackingMode.trackingGps',
      (tester) async {
        final map =
            await _pumpAndReadMap(tester, FollowMode.locationAndHeading);
        expect(
          map.myLocationTrackingMode,
          MyLocationTrackingMode.trackingGps,
        );
      },
    );
  });
}
