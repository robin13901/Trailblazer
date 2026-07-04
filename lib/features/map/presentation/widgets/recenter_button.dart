import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Circular glass button — same size as `TripFab` (56 dp).
///
/// Visible only when the user has panned away from their location
/// (i.e. follow mode is [FollowMode.none]) AND location permission is
/// granted. Positioned directly above the FAB with matching right margin
/// so it forms a vertical stack of two identical circles.
///
/// Taps call [MapLibreMapController.updateMyLocationTrackingMode] with
/// [MyLocationTrackingMode.tracking] and set [FollowMode.location].
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
          if (controller == null) return;
          await controller.updateMyLocationTrackingMode(
            MyLocationTrackingMode.tracking,
          );
          ref
              .read(cameraStateProvider.notifier)
              .setFollowMode(FollowMode.location);
        },
        child: const GlassCircle(
          size: 56,
          child: Icon(Icons.my_location, size: 24),
        ),
      ),
    );
  }
}
