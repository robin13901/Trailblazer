import 'dart:async';

import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final _log = Logger('WakelockSync');

/// Headless widget: no visible UI. Listens to [trackingStateProvider] and
/// holds a screen wakelock for the duration of an active recording so the
/// display never sleeps mid-drive (issue #4).
///
/// Mirrors `TrackingCameraSync` EXACTLY in structure: it flips a piece of
/// device state on the [TrackingIdle] ↔ [TrackingRecording] transitions only,
/// via `ref.listen` inside `build()`.
///
/// * [TrackingIdle] → [TrackingRecording]: `WakelockPlus.enable()` — keep the
///   screen on.
/// * [TrackingRecording] → [TrackingIdle]: `WakelockPlus.disable()` — release,
///   letting the OS idle-timer sleep the display again.
///
/// The plugin calls are fire-and-forget (`unawaited`) and wrapped in a
/// try/catch so a wakelock failure can NEVER crash the app or interrupt
/// recording. `WakelockPlus.enable/disable` return Futures.
///
/// Mounted as a zero-size `Positioned` in `MapScreen`, OUTSIDE the map-tab
/// block, so the wakelock persists across tab switches: the screen stays on
/// even if the user leaves the Map tab mid-recording.
class WakelockSync extends ConsumerWidget {
  const WakelockSync({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<TrackingState>(trackingStateProvider, (previous, next) {
      // TrackingIdle → TrackingRecording: keep the screen awake.
      if (previous is TrackingIdle && next is TrackingRecording) {
        _set(enable: true);
        return;
      }
      // TrackingRecording → TrackingIdle: release the wakelock.
      if (previous is TrackingRecording && next is TrackingIdle) {
        _set(enable: false);
      }
    });
    return const SizedBox.shrink();
  }

  /// Toggles the wakelock, fire-and-forget. Swallows every throwable so a
  /// plugin failure never propagates into the widget tree.
  void _set({required bool enable}) {
    unawaited(() async {
      try {
        if (enable) {
          await WakelockPlus.enable();
        } else {
          await WakelockPlus.disable();
        }
      } on Object catch (e, st) {
        _log.warning(
          'Wakelock ${enable ? 'enable' : 'disable'} failed: $e',
          e,
          st,
        );
      }
    }());
  }
}
