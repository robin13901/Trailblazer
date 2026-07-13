// Trailblazer Phase 6, Plan 06-05 Task 1:
// InboxEmptyState — shown when the Inbox tab has no pending trips.
//
// SVG-free (no new asset deps): a muted Icon + centered copy.

import 'package:flutter/material.dart';

/// Empty-state placeholder for an Inbox with no trips awaiting review.
class InboxEmptyState extends StatelessWidget {
  const InboxEmptyState({super.key});

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
            Icon(Icons.inbox_outlined, size: 64, color: muted),
            const SizedBox(height: 16),
            Text(
              'Keine Fahrten ausstehend',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Aufgezeichnete Fahrten erscheinen hier zur Überprüfung.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
