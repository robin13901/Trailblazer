import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Small circular button — bottom-right, above the FAB row.
///
/// Visible only when the user has panned away from their location
/// (i.e. follow mode is [FollowMode.none]) AND location permission is
/// granted.
///
/// Taps call [MapLibreMapController.updateMyLocationTrackingMode] with
/// [MyLocationTrackingMode.tracking] and update [CameraStateNotifier] to
/// [FollowMode.location].
///
/// Glass styling is deferred to Plan 02-05, which either re-skins this
/// button or wraps it based on `LiquidGlassSettings`.
class RecenterButton extends ConsumerWidget {
  const RecenterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Colors.white.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
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
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.my_location, size: 22),
        ),
      ),
    );
  }
}
