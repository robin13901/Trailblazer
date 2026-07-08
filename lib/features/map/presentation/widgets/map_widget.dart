import 'dart:async';
import 'dart:math';

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
///   - Active map style: driven by [mapStyleUrlProvider] (a MapTiler-hosted
///     style URL — see Plan 04-11 / 04-12). Updated on system brightness
///     change via [WidgetsBindingObserver].
///
/// Style transitions use a 180 ms opacity crossfade ([MapStyleFade]):
/// fade out → `setStyle()` → fade in on `onStyleLoadedCallback`.
///
/// Recenter button + FAB overlays are owned by `MapScreen` — not this
/// widget — so their positioning stays coordinated with the bottom
/// chrome row.
///
/// **04-12: HTTP tile-cache tuning**
/// `maplibre_gl 0.26.2` does NOT expose `setHttpCacheSize` on the Dart-side
/// [MapLibreMapController] surface (grepped the installed package). Offline
/// grace therefore relies on the platform default cache size for now. When
/// upstream surfaces the API, this comment is the deletion marker.
// TODO(04-12): expose HTTP cache size tuning when maplibre_gl surfaces it.
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
      // Map not yet created — update the provider state; the new URL will
      // be used when MapLibreMap is first built.
      ref.read(mapStyleUrlProvider.notifier).updateFromBrightness(b);
      return;
    }
    if (!mounted) return;
    setState(() {
      _styleVisible = false; // start fade-out
    });
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    ref.read(mapStyleUrlProvider.notifier).updateFromBrightness(b);
    final newStyleUrl = ref.read(mapStyleUrlProvider);
    await controller.setStyle(newStyleUrl);
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
    final permissionAsync = ref.watch(locationPermissionProvider);
    final cameraState = ref.watch(cameraStateProvider);
    final styleUrl = ref.watch(mapStyleUrlProvider);

    final isGranted = permissionAsync.maybeWhen(
      data: (s) => s.isGranted || s.isLimited,
      orElse: () => false,
    );
    // Exhaustive FollowMode -> MyLocationTrackingMode mapping.
    // Reserving locationAndHeading -> trackingCompass closes the second
    // bug from 03-1-RESEARCH §3.3 (previously both location and
    // locationAndHeading collapsed to .tracking).
    final trackingMode = switch (cameraState.followMode) {
      FollowMode.none => MyLocationTrackingMode.none,
      FollowMode.location => MyLocationTrackingMode.tracking,
      FollowMode.locationAndHeading => MyLocationTrackingMode.trackingCompass,
    };

    return MapStyleFade(
      visible: _styleVisible,
      child: MapLibreMap(
        styleString: styleUrl,
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
        // Follow mode: driven by FollowMode → MyLocationTrackingMode
        // switch above. locationAndHeading reaches .trackingCompass so
        // the map heading-locks during a recording session.
        myLocationTrackingMode: trackingMode,
        // Attribution: MapLibre's built-in (i) button pushed off-screen
        // (Point(-9999, -9999)) so it does not clutter the map. Legally
        // required MapTiler + OSM credits are surfaced clickably in
        // Settings > About (Plan 04-11 — AboutSection).
        //
        // Reverts Plan 04-12 Task 1 ("attribution restored on-map,
        // bottom-left") per user UX feedback 2026-07-08 — the on-map (i)
        // icon is not wanted. Matches the Phase-2 Wave-7 pattern (STATE
        // 2026-07-04) where the button was pushed off-screen via
        // (attributionButtonPosition + attributionButtonMargins). The
        // maplibre_gl 0.26.2 API surface (installed pub-cache grep):
        // MapLibreMap({attributionButtonPosition = bottomRight,
        //              attributionButtonMargins}) — margins is Point?.
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
