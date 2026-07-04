import 'dart:async';
import 'dart:math';

import 'package:auto_explore/features/map/data/tile_server_providers.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_style_fade.dart';
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
///   - Active map style: driven by [mapStyleAssetProvider]; updated on
///     system brightness change via [WidgetsBindingObserver].
///
/// A loopback tile server ([tileServerProvider]) must be running before
/// MapLibreMap is built — otherwise MapLibre fires tile requests to a socket
/// that isn't listening yet and caches the failure. A [ColoredBox] placeholder
/// is shown while the server starts (typically 300–800 ms cold-start).
///
/// Style transitions use a 180 ms opacity crossfade ([MapStyleFade]):
/// fade out → `setStyle()` → fade in on `onStyleLoadedCallback`.
///
/// Recenter button + FAB overlays are owned by `MapScreen` — not this
/// widget — so their positioning stays coordinated with the bottom
/// chrome row.
class MapWidget extends ConsumerStatefulWidget {
  const MapWidget({
    super.key,
    this.initialTarget = const LatLng(52.52, 13.40), // Berlin fallback
    this.initialZoom = 11,
    this.onMapCreated,
    this.onStyleLoaded,
  });

  final LatLng initialTarget;
  final double initialZoom;
  final void Function(MapLibreMapController)? onMapCreated;
  final VoidCallback? onStyleLoaded;

  @override
  ConsumerState<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends ConsumerState<MapWidget>
    with WidgetsBindingObserver {
  // Cached notifier reference for safe use in dispose()
  // (ref is unsafe to read after unmount — cache the notifier in initState).
  late MapControllerNotifier _mapControllerNotifier;

  /// Controls the opacity crossfade: `true` = fully visible, `false` = faded
  /// out while setStyle() is in progress.
  bool _styleVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ignore: avoid_assigning_notifiers_to_variables — standard safe-dispose pattern
    _mapControllerNotifier = ref.read(mapControllerProvider.notifier);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mapControllerNotifier.controller = null;
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    final newBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    unawaited(_swapStyleWithFade(newBrightness));
  }

  /// Fade out → update provider + call setStyle → fade back in via
  /// `_onStyleLoaded` (triggered by `onStyleLoadedCallback`).
  Future<void> _swapStyleWithFade(Brightness b) async {
    final controller = ref.read(mapControllerProvider);
    if (controller == null) {
      // Map not yet created — update the provider state; the new asset will
      // be used when MapLibreMap is first built.
      ref.read(mapStyleAssetProvider.notifier).updateFromBrightness(b);
      return;
    }
    if (!mounted) return;
    setState(() {
      _styleVisible = false; // start fade-out
    });
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    ref.read(mapStyleAssetProvider.notifier).updateFromBrightness(b);
    final newAsset = ref.read(mapStyleAssetProvider);
    await controller.setStyle(newAsset);
    // onStyleLoadedCallback will call _onStyleLoaded which fades back in.
    // NOTE: Phase 2 has no programmatic layers. If Phase 7+ adds
    // coverage sources via addSource(), they MUST be re-added inside
    // _onStyleLoaded() after setStyle() — the native map wipes all
    // programmatic sources on style reload.
  }

  /// Called by `onStyleLoadedCallback` on every style load (initial + after
  /// `setStyle`). Fades the map back in and notifies the parent widget.
  void _onStyleLoaded() {
    if (!mounted) return;
    setState(() {
      _styleVisible = true;
    });
    widget.onStyleLoaded?.call();
  }

  @override
  Widget build(BuildContext context) {
    // Wait for the loopback tile server to be ready before building MapLibreMap.
    // Without this guard, MapLibre fires tile requests to a socket that isn't
    // listening yet and caches the 'connection refused' failure.
    final tileServerAsync = ref.watch(tileServerProvider);

    return tileServerAsync.when(
      loading: () =>
          // Background colour matches the dark style to avoid a white flash.
          const ColoredBox(color: Color(0xFF0A1728)),
      error: (e, _) => Center(child: Text('Tile server failed: $e')),
      data: (_) => _buildMap(context),
    );
  }

  Widget _buildMap(BuildContext context) {
    final permissionAsync = ref.watch(locationPermissionProvider);
    final cameraState = ref.watch(cameraStateProvider);
    final styleAsset = ref.watch(mapStyleAssetProvider);

    final isGranted = permissionAsync.maybeWhen(
      data: (s) => s.isGranted || s.isLimited,
      orElse: () => false,
    );
    final isFollowing =
        cameraState.followMode == FollowMode.location ||
        cameraState.followMode == FollowMode.locationAndHeading;

    return MapStyleFade(
      visible: _styleVisible,
      child: MapLibreMap(
        styleString: styleAsset,
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
        // Attribution: push OFF-SCREEN. OSM/Protomaps licensing requires
        // attribution to be visible OR reachable "in a common area";
        // it's now surfaced in the About section of Settings.
        attributionButtonPosition: AttributionButtonPosition.bottomLeft,
        attributionButtonMargins: const Point(-9999, -9999),
        // NOTE: useHybridComposition NOT set — do not override on Android
        // Impeller. See Pitfall 2.
        onMapCreated: (c) {
          ref.read(mapControllerProvider.notifier).controller = c;
          widget.onMapCreated?.call(c);
        },
        onStyleLoadedCallback: _onStyleLoaded,
        // Pan/rotate dismisses follow mode.
        onCameraTrackingDismissed: () {
          ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
        },
      ),
    );
  }
}
