import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:auto_explore/features/trips/presentation/widgets/tracking_duration_ticker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Glass pill overlay that appears above the FAB row while a trip is recording.
///
/// Renders `Recording · MM:SS · X.X km · N km/h` updated every second via
/// [TrackingDurationTicker]. Collapses to [SizedBox.shrink] when not recording.
///
/// The timer lives inside [TrackingDurationTicker] (a StatefulWidget), NOT in
/// this ConsumerWidget — otherwise it would leak on every rebuild (Pitfall 4).
class LiveTrackingPanel extends ConsumerWidget {
  const LiveTrackingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(trackingStateProvider);
    if (state is! TrackingRecording) return const SizedBox.shrink();

    return TrackingDurationTicker(
      builder: (context, now) {
        final d = state.duration(now);
        final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
        final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
        final km = (state.distanceMeters / 1000).toStringAsFixed(1);
        final spd = state.currentSpeedKmh?.round().toString() ?? '—';
        final text = 'Recording · $mm:$ss · $km km · $spd km/h';

        return GlassPill(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            text,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        );
      },
    );
  }
}
