import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

final _log = Logger('RecenterButton');

/// Circular glass button — same size as `TripFab` (56 dp).
///
/// Visible only when the user has panned away from their location
/// (i.e. follow mode is [FollowMode.none]) AND location permission is
/// granted. Positioned directly above the FAB with matching right margin
/// so it forms a vertical stack of two identical circles.
///
/// Fail-soft on tap: if the MapLibre native side hasn't acquired a
/// location fix yet (GPS cold-start, indoors, permission just granted),
/// `updateMyLocationTrackingMode(tracking)` can throw an assertion or
/// crash the platform view. The tap wraps the call in try/catch, reverts
/// the follow-mode state on error, and surfaces a SnackBar instead of a
/// crashed app.
class RecenterButton extends ConsumerWidget {
  const RecenterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      label: 'Recenter map on my location',
      button: true,
      child: GestureDetector(
        onTap: () async {
          final controller = ref.read(mapControllerProvider);
          if (controller == null) {
            _log.warning('Recenter tapped but MapLibre controller not ready');
            return;
          }
          try {
            // Update the Riverpod state first so MapWidget's next build
            // passes `myLocationTrackingMode: tracking` to MapLibreMap.
            ref
                .read(cameraStateProvider.notifier)
                .setFollowMode(FollowMode.location);
            await controller.updateMyLocationTrackingMode(
              MyLocationTrackingMode.tracking,
            );
          } on Object catch (e, st) {
            _log.warning('Recenter failed: $e', e, st);
            // Revert optimistic state so the button reappears.
            ref
                .read(cameraStateProvider.notifier)
                .setFollowMode(FollowMode.none);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Waiting for a location fix. Try again in a moment.',
                ),
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
        child: const GlassCircle(
          size: 56,
          child: Icon(Icons.my_location, size: 24),
        ),
      ),
    );
  }
}
