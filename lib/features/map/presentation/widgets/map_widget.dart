import 'dart:async';
import 'dart:math';

import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/location_permission_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_loaded_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_style_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/map_style_fade.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;
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
    // Plan 04-18 (2026-07-08 drive feedback): 16 = one level in from
    // 04-16-1's 15 per user request. Mirrors CameraState.initial.zoom.
    this.initialZoom = 16,
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

  /// The controller this widget instance registered, so dispose only clears
  /// the provider if a faster-mounting successor hasn't already replaced it.
  MapLibreMapController? _ownController;

  /// Controls the opacity crossfade: `true` = fully visible, `false` = faded
  /// out while setStyle() is in progress.
  bool _styleVisible = true;

  /// Whether we've already recentered the camera onto the first GPS fix after a
  /// genuine cold start. On cold start the persisted [CameraState] is still at
  /// the (0,0) sentinel, so `MapWidget` opens at `widget.initialTarget` (the
  /// Berlin fallback). MapLibre's tracking mode does not reliably snap the
  /// camera to the first fix on iOS, so we do it explicitly here: the first
  /// `onUserLocationUpdated` fix animates the camera to the user's real
  /// location. Set once so later fixes don't fight the user's panning.
  bool _didColdStartRecenter = false;

  /// Whether this map instance mounted on a genuine cold start — i.e. the
  /// persisted [CameraState] was still the (0,0) sentinel at mount time.
  ///
  /// Snapshotted HERE in initState, NOT re-read inside `onUserLocationUpdated`.
  /// Reason (the "opens in Berlin, no recenter button" bug, 2026-07-23): the
  /// map opens at the Berlin fallback, settles, and fires `onCameraIdle`, which
  /// persists the Berlin coordinates into `cameraStateProvider` — BEFORE the
  /// first GPS fix arrives. A guard that re-read the persisted position at
  /// fix-time would therefore see Berlin (non-sentinel) and skip the recenter,
  /// leaving the camera stuck at Berlin and the recenter button hidden (still
  /// in `location` follow mode). Capturing the decision at mount time, before
  /// any idle can clobber the sentinel, closes that race.
  bool _mountedOnColdStart = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ignore: avoid_assigning_notifiers_to_variables — standard safe-dispose pattern
    _mapControllerNotifier = ref.read(mapControllerProvider.notifier);
    // Snapshot the cold-start decision before any onCameraIdle can persist the
    // Berlin fallback over the (0,0) sentinel (see field doc above).
    final persisted = ref.read(cameraStateProvider);
    _mountedOnColdStart = persisted.latitude == 0 && persisted.longitude == 0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clear the shared controller only if this instance still owns it, so a
    // fast remount (leaving + returning to the Map tab) that already
    // registered a new controller is not clobbered.
    //
    // Deferred to a microtask: dispose now runs while the parent (MapScreen)
    // is rebuilding to swap the map out on a tab change, and mutating a
    // provider mid-build throws. The captured notifier stays valid for the
    // ProviderScope's lifetime, so the identity-guarded clear is safe.
    final notifier = _mapControllerNotifier;
    final own = _ownController;
    scheduleMicrotask(() {
      // Best-effort: if the whole ProviderScope was torn down before the
      // microtask ran (e.g. widget-test teardown), the notifier read throws
      // UnmountedRefException — nothing to clear in that case.
      try {
        if (notifier.controller == own) notifier.controller = null;
      } on Object {
        // Scope gone — no-op.
      }
    });
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
    // onStyleLoadedCallback will call _onStyleLoaded which fades back in and
    // bumps mapStyleLoadedTickProvider, causing CoverageOverlayBridge to
    // re-add the coverage source + layer (wiped by setStyle — Pitfall 1).
  }

  /// Called by `onStyleLoadedCallback` on every style load (initial + after
  /// `setStyle`). Fades the map back in, bumps the style-load tick so
  /// `CoverageOverlayBridge` re-adds coverage sources (which were wiped by
  /// `setStyle()` — RESEARCH Pitfall 1), and notifies the parent widget.
  void _onStyleLoaded() {
    if (!mounted) return;
    setState(() {
      _styleVisible = true;
    });
    // Bump the style-load tick so CoverageOverlayBridge re-adds the coverage
    // source + layer. setStyle() wipes all programmatic sources on the native
    // side, so the bridge must re-add them on every style (re)load.
    ref.read(mapStyleLoadedTickProvider.notifier).bump();
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
    // The native MapLibre location puck stays ON while recording and owns the
    // camera via MyLocationTrackingMode.trackingGps (centering + heading-up
    // rotation). It follows the live position closely; the live coverage line
    // is drawn one fix BEHIND (LiveTrailBridge) so its tip visually coincides
    // with the puck. This is a single-camera-owner design (2026-07-19): the
    // earlier manual per-frame moveCamera fought native tracking — every manual
    // camera nudge tripped onCameraTrackingDismissed, which silently killed the
    // rotation — and required a second (manual) puck. Both are gone now.
    final locationEnabled = isGranted;
    // Exhaustive FollowMode -> MyLocationTrackingMode mapping.
    //
    // Plan 04-19 (2026-07-09 drive fix): locationAndHeading maps to
    // MyLocationTrackingMode.trackingGps. Rationale: the metal shell of a
    // car + magnets in typical phone mounts routinely deflect the device
    // compass reading by 20-90°. The GPS-motion-vector bearing is the
    // correct in-vehicle choice — accurate whenever the vehicle is
    // moving, which is the only regime that matters here.
    //
    // TODO(phase-5.1): road-snap heading hybrid — when the live matcher is
    // confident about the current way, override GPS heading with the way's
    // local bearing. Requires live-matching, currently out of scope
    // (Phase 5 matcher runs on-trip-stop only).
    final trackingMode = switch (cameraState.followMode) {
      FollowMode.none => MyLocationTrackingMode.none,
      FollowMode.location => MyLocationTrackingMode.tracking,
      FollowMode.locationAndHeading => MyLocationTrackingMode.trackingGps,
    };

    return MapStyleFade(
      visible: _styleVisible,
      child: MapLibreMap(
        styleString: styleUrl,
        // Seed from the persisted CameraState when it holds a real position
        // (lat/lng != 0,0 sentinel) so that disposing + recreating the map on
        // a tab switch (memory fix — the map's ~500 MB GL surface is freed
        // while off the Map tab) returns to where the user left it. Falls back
        // to the widget's initial target on a genuine cold start.
        initialCameraPosition: (cameraState.latitude != 0 ||
                cameraState.longitude != 0)
            ? CameraPosition(
                target: LatLng(cameraState.latitude, cameraState.longitude),
                zoom: cameraState.zoom,
                bearing: cameraState.bearing,
              )
            : CameraPosition(
                target: widget.initialTarget,
                zoom: widget.initialZoom,
              ),
        // 02-CONTEXT.md: flat 2D only — tilt is the only non-default gesture flag.
        tiltGesturesEnabled: false,
        // Plan 04-19 (2026-07-09): hide MapLibre's built-in top-right
        // compass. The custom glass AlignNorthButton (rendered by
        // MapScreen at top-right, mirroring SettingsGlassButton) owns
        // that corner now. `compassEnabled: false` is exposed by
        // maplibre_gl 0.26.2 (grep pub-cache: maplibre_map.dart:22 +
        // :136 + :492 + :571).
        compassEnabled: false,
        trackCameraPosition: true,
        myLocationEnabled: locationEnabled,
        // Puck render mode. In heading-up recording the map itself rotates to
        // the travel direction, so a compass cone driven by the device
        // magnetometer would point where the *phone* faces — fighting the map
        // rotation and reading wrong in a car (metal + mount magnets deflect
        // the compass 20-90°). Use the plain dot + accuracy ring while
        // heading-locked; keep the compass cone only in north-up modes where
        // it still conveys useful orientation.
        myLocationRenderMode: (locationEnabled &&
                cameraState.followMode != FollowMode.locationAndHeading)
            ? MyLocationRenderMode.compass
            : MyLocationRenderMode.normal,
        // Follow mode: driven by FollowMode → MyLocationTrackingMode
        // switch above. locationAndHeading reaches .trackingGps so the
        // map heading-locks to the GPS-derived motion bearing during a
        // recording session (Plan 04-19).
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
          _ownController = c;
          ref.read(mapControllerProvider.notifier).controller = c;
          widget.onMapCreated?.call(c);
        },
        onStyleLoadedCallback: _onStyleLoaded,
        // Cold-start recenter: on a genuine cold start the camera opens at the
        // Berlin fallback (persisted position is still the 0,0 sentinel). The
        // first real GPS fix animates the camera to the user's location — once
        // — so the app always opens "where I am" without waiting on MapLibre's
        // tracking-mode snap (unreliable on the first iOS fix).
        onUserLocationUpdated: (location) {
          if (!mounted || _didColdStartRecenter) return;
          _didColdStartRecenter = true;
          // Only take over the camera on a genuine cold start (sentinel
          // position captured at mount, BEFORE onCameraIdle could persist the
          // Berlin fallback over it — see _mountedOnColdStart). If a real
          // position was restored (tab switch, jump-to), respect it and don't
          // yank the camera to the user.
          if (!_mountedOnColdStart) return;
          final controller = ref.read(mapControllerProvider);
          if (controller == null) return;
          // Fire-and-forget; the map must never crash on a camera error.
          unawaited(() async {
            try {
              await controller.animateCamera(
                CameraUpdate.newLatLngZoom(
                  location.position,
                  CameraState.initial.zoom,
                ),
                duration: const Duration(milliseconds: 400),
              );
            } on Object {
              // Swallow — cold-start recenter is best-effort.
            }
          }());
        },
        // Pan/rotate dismisses follow mode.
        onCameraTrackingDismissed: () {
          ref.read(cameraStateProvider.notifier).setFollowMode(FollowMode.none);
        },
        // Live camera stream for the focus pill (Plan 08-03). Fires on every
        // frame while the user pans/zooms. Push the raw position into
        // liveCameraProvider here — debounce + region resolution live in the
        // pill provider (08-05), NEVER in this hot callback (RESEARCH.md
        // line 571: debounce in a timer, not in the callback).
        onCameraMove: (pos) {
          if (!mounted) return;
          ref.read(liveCameraProvider.notifier).update(pos);
        },
        // Persist the live camera position on every idle so a dispose+recreate
        // across a tab switch (memory fix) can restore the exact view. Reads
        // the controller's tracked position (trackCameraPosition: true).
        //
        // Write synchronously only when the scheduler is idle. The platform can
        // deliver camera-idle during a build/layout phase (notably fakes in
        // widget tests), and modifying a provider mid-build throws — in that
        // case we simply skip this sample; the next idle (or the seed on
        // remount) covers it. No post-frame deferral, so no risk of touching a
        // torn-down ref after the test ends.
        onCameraIdle: () {
          if (!mounted) return;
          final phase = WidgetsBinding.instance.schedulerPhase;
          final safe = phase == SchedulerPhase.idle ||
              phase == SchedulerPhase.postFrameCallbacks;
          if (!safe) return;
          final pos = ref.read(mapControllerProvider)?.cameraPosition;
          if (pos != null) {
            ref.read(cameraStateProvider.notifier).updateFromMap(pos);
          }
        },
      ),
    );
  }
}
