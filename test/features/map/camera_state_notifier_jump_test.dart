// Trailblazer 2026-07-11 jump-to-map fix:
// Verifies CameraStateNotifier.jumpTo replaces the whole camera state.
// jumpTo is the mechanism behind the region detail sheet's "Jump to on map":
// it seeds cameraStateProvider so the (disposed-while-off-tab) MapWidget
// re-seeds its initialCameraPosition to the region on remount, with
// follow-mode OFF so GPS tracking doesn't snap the camera away.

import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CameraStateNotifier.jumpTo', () {
    test('replaces the entire camera state with the target', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      const target = CameraState(
        latitude: 49.7,
        longitude: 9.2,
        zoom: 11,
        // followMode omitted → defaults to FollowMode.none (the jump target).
      );

      c.read(cameraStateProvider.notifier).jumpTo(target);

      final s = c.read(cameraStateProvider);
      expect(s.latitude, 49.7);
      expect(s.longitude, 9.2);
      expect(s.zoom, 11);
      expect(
        s.followMode,
        FollowMode.none,
        reason: 'follow-mode OFF so GPS tracking does not override the jump',
      );
    });

    test('overrides a prior tracking state (no lingering follow mode)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // Simulate the user having been in location-follow before jumping.
      c
          .read(cameraStateProvider.notifier)
          .setFollowMode(FollowMode.location);
      expect(c.read(cameraStateProvider).followMode, FollowMode.location);

      const target = CameraState(
        latitude: 50.5,
        longitude: 9.4,
        zoom: 9,
        // followMode omitted → defaults to FollowMode.none; proves the jump
        // clears the prior FollowMode.location.
      );
      c.read(cameraStateProvider.notifier).jumpTo(target);

      expect(c.read(cameraStateProvider).followMode, FollowMode.none);
      expect(c.read(cameraStateProvider).zoom, 9);
    });
  });
}
