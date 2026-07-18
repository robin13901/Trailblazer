import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
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
///   1. Read the last-known device location.
///   2. Animate the camera to (user, `CameraState.initial.zoom`) over ~500 ms.
///      Uses the shared default so recenter always returns to the same zoom
///      as cold-start regardless of where the user zoomed to.
///   3. Enable MapLibre's `tracking` mode so subsequent GPS ticks
///      continue to follow the user without further user input.
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
            // Update follow-mode state FIRST so MapWidget's next build
            // passes `myLocationTrackingMode: tracking` to MapLibreMap.
            ref
                .read(cameraStateProvider.notifier)
                .setFollowMode(FollowMode.location);

            // Read the current user location from the native side.
            // Returns null if no fix is available yet.
            final userLocation = await controller.requestMyLocationLatLng();

            if (userLocation != null) {
              // Plan 04-18 (2026-07-08 drive feedback) + 2026-07-18: recenter
              // tap ALWAYS animates to CameraState.recenterZoom — a fixed
              // street-level zoom one level deeper than the cold-start default,
              // regardless of the current zoom. So the tap is a "reset view":
              // recenter + zoom-to-fixed-level in one animation.
              await controller.animateCamera(
                CameraUpdate.newLatLngZoom(
                  userLocation,
                  CameraState.recenterZoom,
                ),
                duration: const Duration(milliseconds: 500),
              );
            }

            // Enable native tracking so the camera continues to follow
            // subsequent GPS ticks. Safe to call even without a fix —
            // MapLibre just no-ops until one arrives.
            await controller.updateMyLocationTrackingMode(
              MyLocationTrackingMode.tracking,
            );
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
