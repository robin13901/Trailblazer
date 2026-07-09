import 'dart:math' as math;

import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

final _log = Logger('AlignNorthButton');

/// Top-right glass button that resets the map bearing to 0 (north).
///
/// Mirrors `SettingsGlassButton` in size + style (44 dp [GlassCircle],
/// Semantics wrapper, GestureDetector). SafeArea + Positioned are handled
/// by the parent `MapScreen`.
///
/// Tap behaviour: reads the current MapLibre camera position and animates
/// the bearing to 0 while preserving target + zoom + tilt. Fail-soft: if
/// the controller isn't ready yet or the camera position is null (map not
/// yet loaded), the tap is a no-op.
///
/// The icon rotates to reflect the current bearing so the arrow visually
/// spins as the map rotates. When `CameraState.bearing` is 0 the arrow
/// points straight up; a rotated map produces a counter-rotated arrow
/// (per the same convention Google Maps uses).
///
/// Plan 04-19 (2026-07-09) — hides MapLibre's built-in top-right compass;
/// this custom glass button owns the top-right corner now.
class AlignNorthButton extends ConsumerWidget {
  const AlignNorthButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bearing = ref.watch(cameraStateProvider).bearing;
    return Semantics(
      label: 'Align map to north',
      button: true,
      child: GestureDetector(
        onTap: () async {
          final controller = ref.read(mapControllerProvider);
          if (controller == null) {
            _log.warning('AlignNorth tapped but controller not ready');
            return;
          }
          final current = controller.cameraPosition;
          if (current == null) {
            _log.warning('AlignNorth tapped but cameraPosition is null');
            return;
          }
          try {
            await controller.animateCamera(
              CameraUpdate.newCameraPosition(
                CameraPosition(
                  target: current.target,
                  zoom: current.zoom,
                  tilt: current.tilt,
                  // bearing = 0 → true north up.
                ),
              ),
            );
          } on Object catch (e, st) {
            _log.warning('AlignNorth animateCamera failed: $e', e, st);
          }
        },
        child: GlassCircle(
          size: 44,
          child: Transform.rotate(
            // Counter-rotate so the arrow tracks true north as the map
            // rotates. MapLibre bearing is in degrees; Transform expects
            // radians. Negative sign matches the Google Maps convention
            // (map bearing 90° east → arrow rotated 90° CCW).
            angle: -bearing * math.pi / 180,
            child: const Icon(Icons.navigation_outlined, size: 20),
          ),
        ),
      ),
    );
  }
}
