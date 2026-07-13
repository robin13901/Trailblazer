// Trailblazer — TripsScreen: the Trips tab.
//
// 2026-07-13 (on-device feedback): the Inbox/History sub-tabs were removed.
// Auto-recording no longer exists — every trip is started manually, so there
// is nothing to triage in an inbox. The screen now shows the trip history
// list directly (all recorded trips), with the MatchingQueuePill above it
// while any trip is still being road-matched.
//
// Thumbnails are rendered purely on the Canvas via `ThumbnailRenderer.
// renderFallback` (see TripThumbnail) — no live MapLibre surface is hosted
// here.

import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_empty_state.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_row.dart';
import 'package:auto_explore/features/trips/presentation/widgets/matching_queue_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Trips tab: a single flat list of all recorded trips (newest first),
/// with the matcher-queue pill shown above it while matching is in flight.
class TripsScreen extends ConsumerWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            MatchingQueuePill(),
            Expanded(child: _HistoryList()),
          ],
        ),
      ),
    );
  }
}

/// The trip history list — confirmed + matched + in-flight trips.
class _HistoryList extends ConsumerWidget {
  const _HistoryList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyTripsProvider);
    return history.when(
      data: (items) {
        if (items.isEmpty) return const HistoryEmptyState();
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) => HistoryRow(item: items[i]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorBody(message: '$e'),
    );
  }
}

/// DomainError-aware error body for the history list.
class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Fahrten konnten nicht geladen werden.\n$message',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
