// Trailblazer Phase 6, Plan 06-05 Task 1:
// HistoryEmptyState — shown when the History tab has no confirmed / in-flight
// trips yet.

import 'package:flutter/material.dart';

/// Empty-state placeholder for an empty Trip History.
class HistoryEmptyState extends StatelessWidget {
  const HistoryEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 64, color: muted),
            const SizedBox(height: 16),
            Text(
              'No trip history yet',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Confirmed and matching trips will appear here.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
