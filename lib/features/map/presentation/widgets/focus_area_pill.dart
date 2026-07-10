// Trailblazer Phase 8, Plan 08-04 (Wave 2):
// Live two-line FocusAreaPill — replaces the Phase-2 stub.
//
// Watches focusPillProvider; renders region name over coverage % via GlassPill.
// Hold-last-value: shows a neutral German placeholder until the first resolve
// completes, so the pill is never blank and GlassPill's 0-dim guard is never
// hit with zero content.
//
// No tap handler here — Plan 08-05 (region browser) wires the tap to the
// detail sheet. FocusAreaPill remains a drop-in replacement in map_screen.dart
// (no changes to the Stack or Flexible/Expanded wrapping — 0-width crash
// remains prevented by the existing Center in map_screen.dart:165).

import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/regions/presentation/providers/focus_pill_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live two-line pill: region name on top, coverage % underneath.
///
/// Renders inside [GlassPill] — inherits the G1 gate flag (liquid glass vs.
/// semi-transparent fallback) and the 0-dim guard.
///
/// Drop-in replacement for the Phase-2 stub — map_screen.dart is unchanged.
class FocusAreaPill extends ConsumerWidget {
  const FocusAreaPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(focusPillProvider);
    final theme = Theme.of(context);

    // Hold-last-value: before the first resolve, show neutral placeholder so
    // the pill is never blank (and GlassPill's 0-dim guard is never triggered
    // with zero-height content). After first resolve, name + % remain visible
    // during subsequent re-resolves (CONTEXT.md lines 29, 55).
    final name = state.name ?? 'Standort';
    final percent = state.percentLabel ?? '—%';

    return Semantics(
      label: 'Focus area: $name, coverage $percent',
      child: GlassPill(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              percent,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
