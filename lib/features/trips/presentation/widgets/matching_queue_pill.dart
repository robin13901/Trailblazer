// Trailblazer Phase 6, Plan 06-04 Task 2:
// MatchingQueuePill — the global "N trips matching…" indicator shown after
// Keep while the matcher queue drains (CONTEXT post-Keep UX).
//
// Reassuring, not alarming: a Liquid Glass pill with a small spinner + count.
// Renders via the shared `GlassPill` shell (which branches on the G1 flag —
// real LiquidGlass when supported, tinted fallback otherwise), so it inherits
// the app-wide glass aesthetic. Collapses to `SizedBox.shrink` when the queue
// is empty (count == 0) — the card has already moved to History.

import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Persistent background-matching indicator: "N trips matching…".
///
/// Watches [inFlightCountProvider]; shows nothing when the count is zero or
/// still loading, otherwise a glass pill with a spinner and count-driven copy.
class MatchingQueuePill extends ConsumerWidget {
  const MatchingQueuePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(inFlightCountProvider).value ?? 0;
    if (count == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final label = count == 1 ? '1 Fahrt wird abgeglichen …' : '$count Fahrten werden abgeglichen …';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: GlassPill(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        borderRadius: 999,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                // Softened accent — never withOpacity (Flutter 3.44+ API).
                color: theme.colorScheme.primary.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 10),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
