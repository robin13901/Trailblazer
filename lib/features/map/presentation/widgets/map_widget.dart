import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/recenter_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:permission_handler/permission_handler.dart';

/// Phase-2 map widget. Wraps [MapLibreMap] with the gesture set
/// mandated by 02-CONTEXT.md:
///   - pan / zoom / rotate: enabled
///   - tilt: DISABLED (flat 2D only)
///
/// Location, follow-mode, and dark-mode switching:
///   - Location enabled/disabled: driven by [locationPermissionProvider].
///   - Follow-mode: driven by [cameraStateProvider].
///   - Dark-mode switching: added in Plan 02-04.
///
/// The [RecenterButton] is overlaid when follow mode is [FollowMode.none]
/// AND location permission is granted.
class MapWidget extends ConsumerStatefulWidget {
  const MapWidget({
    super.key,
    this.initialTarget = const LatLng(52.52, 13.40), // Berlin fallback
    this.initialZoom = 15,
    this.styleAsset = 'assets/map_style_light.json',
    this.onMapCreated,
    this.onStyleLoaded,
  });

  final LatLng initialTarget;
  final double initialZoom;
  final String styleAsset;
  final void Function(MapLibreMapController)? onMapCreated;
  final VoidCallback? onStyleLoaded;

  @override
  ConsumerState<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends ConsumerState<MapWidget> {
  // Cached notifier reference for safe use in dispose()
  // (ref is unsafe to read after unmount — cache the notifier in initState).
  late MapControllerNotifier _mapControllerNotifier;

  @override
  void initState() {
    super.initState();
    // ignore: avoid_assigning_notifiers_to_variables — standard safe-dispose pattern
    _mapControllerNotifier = ref.read(mapControllerProvider.notifier);
  }

  @override
  void dispose() {
    _mapControllerNotifier.controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final permissionAsync = ref.watch(locationPermissionProvider);
    final cameraState = ref.watch(cameraStateProvider);

    final isGranted = permissionAsync.maybeWhen(
      data: (s) => s.isGranted || s.isLimited,
      orElse: () => false,
    );

    final isFollowing =
        cameraState.followMode == FollowMode.location ||
        cameraState.followMode == FollowMode.locationAndHeading;

    return Stack(
      children: [
        MapLibreMap(
          styleString: widget.styleAsset,
          initialCameraPosition: CameraPosition(
            target: widget.initialTarget,
            zoom: widget.initialZoom,
          ),
          // 02-CONTEXT.md: flat 2D only — tilt is the only non-default gesture flag.
          tiltGesturesEnabled: false,
          compassViewPosition: CompassViewPosition.topRight,
          trackCameraPosition: true,
          // Location dot + heading cone + accuracy ring.
          // myLocationRenderMode must be normal when myLocationEnabled is false
          // (MapLibreMap asserts: compass requires myLocationEnabled=true).
          myLocationEnabled: isGranted,
          myLocationRenderMode: isGranted
              ? MyLocationRenderMode.compass
              : MyLocationRenderMode.normal,
          // Follow mode: tracking when location/locationAndHeading, else none.
          myLocationTrackingMode: isFollowing
              ? MyLocationTrackingMode.tracking
              : MyLocationTrackingMode.none,
          // NOTE: useHybridComposition NOT set — do not override on Android
          // Impeller. See Pitfall 2.
          onMapCreated: (c) {
            ref.read(mapControllerProvider.notifier).controller = c;
            widget.onMapCreated?.call(c);
          },
          onStyleLoadedCallback: () {
            widget.onStyleLoaded?.call();
          },
          // Pan/rotate dismisses follow mode.
          onCameraTrackingDismissed: () {
            ref
                .read(cameraStateProvider.notifier)
                .setFollowMode(FollowMode.none);
          },
          // Sync camera position into state on idle.
          onCameraIdle: () {
            // trackCameraPosition=true keeps MapLibreMap.cameraPosition fresh.
            // We don't have direct access here; position is updated on user
            // camera moves. Follow-mode changes (tracking → none) are the
            // primary state we care about, handled by onCameraTrackingDismissed.
          },
        ),
        // Recenter button: visible when user has panned away AND has location.
        if (isGranted && !isFollowing)
          const Positioned(
            right: 16,
            bottom: 96,
            child: RecenterButton(),
          ),
      ],
    );
  }
}
