// Trailblazer: Regions-tab sort menu — a liquid-glass popover anchored to the
// bottom-right of the sort icon (user request 2026-10-18).
//
// Matches the bottom-nav pill's visual language: the shared `GlassPill`
// primitive for the glass/fallback surface, the selected criterion rendered in
// the primary (blue) colour with a check, the rest in the muted grey used for
// unselected nav tabs. Anchored via `OverlayPortal` + `CompositedTransform*`
// so it hangs off the icon like the Files-app example.

import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Icon button that opens the glass sort-criterion popover.
class SortMenuButton extends ConsumerStatefulWidget {
  const SortMenuButton({super.key});

  @override
  ConsumerState<SortMenuButton> createState() => _SortMenuButtonState();
}

class _SortMenuButtonState extends ConsumerState<SortMenuButton> {
  final OverlayPortalController _controller = OverlayPortalController();
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) => _SortMenuOverlay(
          link: _link,
          onDismiss: _controller.hide,
        ),
        child: IconButton(
          icon: const Icon(Icons.sort),
          tooltip: 'Sortieren nach',
          onPressed: _controller.toggle,
        ),
      ),
    );
  }
}

/// Full-screen overlay: a transparent dismiss scrim + the glass panel anchored
/// under the icon's bottom-right corner.
class _SortMenuOverlay extends ConsumerWidget {
  const _SortMenuOverlay({required this.link, required this.onDismiss});

  final LayerLink link;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      regionSortProvider.select((sort) => sort.criterion),
    );
    final colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        // Tap anywhere outside the panel to dismiss.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: link,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 8),
          // Hide the panel until the link's layer is attached. Without this the
          // first frame paints it at the unlinked origin (top-left) before the
          // follower snaps to the icon — the brief open flicker (2026-10-18).
          showWhenUnlinked: false,
          child: SizedBox(
            width: 260,
            child: GlassPill(
              borderRadius: 24,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final criterion in RegionSortCriterion.values)
                      _SortOption(
                        label: criterion.label,
                        selected: criterion == current,
                        colorScheme: colorScheme,
                        onTap: () {
                          ref.read(regionSortProvider.notifier).criterion =
                              criterion;
                          onDismiss();
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One selectable row. Selected = primary (blue) + check, matching the active
/// bottom-nav tab; unselected = the muted grey used for inactive tabs.
class _SortOption extends StatelessWidget {
  const _SortOption({
    required this.label,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? colorScheme.primary
        : colorScheme.onSurface.withValues(alpha: 0.5);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: selected
                  ? Icon(Icons.check, size: 18, color: color)
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
