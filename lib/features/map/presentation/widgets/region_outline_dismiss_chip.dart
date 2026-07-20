// Trailblazer region-outline overlay:
// RegionOutlineDismissChip — the on-map X chip shown while a region boundary is
// displayed. Tapping it clears regionOutlineProvider, which drives
// RegionOutlineBridge to remove the outline layers.
//
// Hidden (renders nothing) when no outline is shown. Styled with GlassPill
// (overMap: true) for visual consistency with the other map chrome.

import 'package:auto_explore/features/map/presentation/providers/region_outline_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A small glass chip ("✕ Umriss ausblenden") shown while a region outline is
/// on the map. Renders `const SizedBox.shrink()` when no outline is active.
class RegionOutlineDismissChip extends ConsumerWidget {
  const RegionOutlineDismissChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final region = ref.watch(regionOutlineProvider);
    if (region == null) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Semantics(
      label: 'Regionsumriss ausblenden',
      button: true,
      child: GestureDetector(
        onTap: () => ref.read(regionOutlineProvider.notifier).clear(),
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
                'Umriss ausblenden',
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
