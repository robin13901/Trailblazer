// Trailblazer trip-path overlay:
// TripPathDismissChip — the on-map X chip shown while a trip's path is
// displayed. Tapping it clears selectedTripProvider, which drives
// TripPathBridge to remove the trip layers.
//
// Hidden (renders nothing) when no trip is shown. Styled with GlassPill
// (overMap: true), mirroring RegionOutlineDismissChip.

import 'package:auto_explore/features/map/presentation/providers/selected_trip_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A small glass chip ("✕ Fahrt ausblenden") shown while a trip path is on the
/// map. Renders `const SizedBox.shrink()` when no trip is active.
class TripPathDismissChip extends ConsumerWidget {
  const TripPathDismissChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripId = ref.watch(selectedTripProvider);
    if (tripId == null) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Semantics(
      label: 'Fahrt ausblenden',
      button: true,
      child: GestureDetector(
        onTap: () => ref.read(selectedTripProvider.notifier).clear(),
        child: GlassPill(
          overMap: true,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.close,
                size: 18,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 6),
              Text(
                'Fahrt ausblenden',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
