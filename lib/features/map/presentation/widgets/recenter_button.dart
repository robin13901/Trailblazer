import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

final _log = Logger('RecenterButton');

/// Circular glass button — same size as `TripFab`.
///
/// Visible only when the user has panned away from their location
/// (i.e. follow mode is [FollowMode.none]) AND location permission is
/// granted. Positioned directly above the FAB with matching right margin
/// so it forms a vertical stack of two identical circles.
///
/// Behavior on tap:
///   1. Read the last-known device location (while native tracking is OFF).
///   2. Animate the camera to (user, `CameraState.recenterZoom`) over ~500 ms.
///      Tracking is still off here so this animation is the sole camera owner
///      and the zoom always lands on `recenterZoom` regardless of the prior
///      zoom — in BOTH directions (zoom-in from far out, zoom-out from close).
///   3. Only THEN update follow mode + enable MapLibre's `tracking` mode so
///      subsequent GPS ticks continue to follow the user. Tracking preserves
///      the zoom just set; it only maintains centering.
///
/// Fail-soft: if step 1 or 2 fails (permission just granted but no fix
/// yet, GPS cold-start, indoors), the tap reverts follow mode and logs
/// the error. No user-visible SnackBar — that would re-layout the
/// bottom Row and crash `liquid_glass_renderer` on 0-width pill during
/// the animation.
class RecenterButton extends ConsumerWidget {
  const RecenterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      label: 'Auf meinen Standort zentrieren',
      button: true,
      child: GestureDetector(
        onTap: () async {
          final controller = ref.read(mapControllerProvider);
          if (controller == null) {
            _log.warning('Recenter tapped but MapLibre controller not ready');
            return;
          }
          try {
            // Recording-aware follow mode (issue #12b): during an active
            // recording, restore heading-up follow (FollowMode.locationAndHeading
            // → MyLocationTrackingMode.trackingGps) so the re-lock returns to
            // the same heading-locked camera the trip started with. Outside
            // recording, keep the passive north-up follow (FollowMode.location
            // → MyLocationTrackingMode.tracking).
            final isRecording =
                ref.read(trackingStateProvider) is TrackingRecording;
            final followMode =
                isRecording ? FollowMode.locationAndHeading : FollowMode.location;
            final trackingMode = isRecording
                ? MyLocationTrackingMode.trackingGps
                : MyLocationTrackingMode.tracking;

            // Read the current user location from the native side.
            // Returns null if no fix is available yet.
            final userLocation = await controller.requestMyLocationLatLng();

            if (userLocation != null) {
              // Plan 04-18 (2026-07-08 drive feedback) + 2026-07-18 + 2026-07-29:
              // recenter tap ALWAYS animates to CameraState.recenterZoom — a
              // fixed street-level zoom — regardless of the current zoom. So the
              // tap is a "reset view": recenter + zoom-to-fixed-level in one
              // animation.
              //
              // ORDER MATTERS (2026-07-29 fix): the zoom animation runs BEFORE
              // follow mode is enabled. Engaging MyLocationTrackingMode.tracking
              // first makes the native side the camera owner AT THE CURRENT ZOOM,
              // which then fights/overrides this animateCamera — so a deep zoom
              // would only recenter and never zoom back out to recenterZoom.
              // With tracking still off, this animation is the sole camera owner
              // and the zoom lands deterministically in both directions.
              await controller.animateCamera(
                CameraUpdate.newLatLngZoom(
                  userLocation,
                  CameraState.recenterZoom,
                ),
                duration: const Duration(milliseconds: 500),
              );
            }

            // Now update follow-mode state so MapWidget's next build passes the
            // matching myLocationTrackingMode to MapLibreMap, and enable native
            // tracking so the camera continues to follow subsequent GPS ticks.
            // Doing this AFTER the animation means tracking picks up the camera
            // at recenterZoom and merely maintains centering — it no longer
            // clobbers the zoom. Safe to call even without a fix — MapLibre just
            // no-ops until one arrives.
            ref.read(cameraStateProvider.notifier).setFollowMode(followMode);
            await controller.updateMyLocationTrackingMode(trackingMode);
          } on Object catch (e, st) {
            _log.warning('Recenter failed: $e', e, st);
            // Revert optimistic state so the button reappears.
            ref
                .read(cameraStateProvider.notifier)
                .setFollowMode(FollowMode.none);
          }
        },
        child: const GlassCircle(
          size: 64,
          overMap: true,
          child: Icon(Icons.my_location, size: 26),
        ),
      ),
    );
  }
}
