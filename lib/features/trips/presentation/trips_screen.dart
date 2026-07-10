// Trailblazer Phase 6, Plan 06-05 Task 2:
// TripsScreen — the Trips tab, sub-tabbed into History (confirmed + in-flight)
// and Inbox (pending/matched). Replaces the Phase-3 placeholder.
//
// Above the tabs: MatchingQueuePill (visible only when in-flight count > 0).
// Tab order (2026-07-10): History is the default LEFT tab (index 0), Inbox is
// on the RIGHT (index 1). Landing tab: History by default, jumping to Inbox
// only when pending trips exist on the first snapshot (guarded by
// `_initialTabResolved` so later list updates never force-jump).
//
// Thumbnails are rendered purely on the Canvas via `ThumbnailRenderer.
// renderFallback` (see TripThumbnail) — no live MapLibre surface is hosted
// here. (Plan 06-07: an unused offstage snapshot map was removed; it was a
// second live GL surface that never fed a wired snapshot path and crashed
// mid-range Android on the Trips tab.)

import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_empty_state.dart';
import 'package:auto_explore/features/trips/presentation/widgets/history_row.dart';
import 'package:auto_explore/features/trips/presentation/widgets/inbox_empty_state.dart';
import 'package:auto_explore/features/trips/presentation/widgets/matching_queue_pill.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Trips tab: Inbox / History sub-tabs + matcher-queue pill.
class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key});

  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  bool _initialTabResolved = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  /// Resolve the landing tab from the first inbox snapshot. History is the
  /// default (index 0); jump to Inbox (index 1) only when pending trips exist
  /// so the user sees the trips awaiting a decision. Runs at most once.
  void _resolveInitialTab(List<TripListItem> inbox) {
    if (_initialTabResolved) return;
    _initialTabResolved = true;
    final targetIndex = inbox.isNotEmpty ? 1 : 0;
    if (_tab.index != targetIndex) {
      // Defer to after the current build to avoid mutating during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tab.index = targetIndex;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Resolve landing tab on first inbox data.
    ref.watch(inboxTripsProvider).whenData(_resolveInitialTab);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const MatchingQueuePill(),
            TabBar(
              controller: _tab,
              tabs: const [
                Tab(text: 'History'),
                Tab(text: 'Inbox'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: const [
                  _HistoryTab(),
                  _InboxTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inbox tab body — matched trips awaiting Keep/Discard.
class _InboxTab extends ConsumerWidget {
  const _InboxTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxTripsProvider);
    return inbox.when(
      data: (items) {
        if (items.isEmpty) return const InboxEmptyState();
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) => TripCard(item: items[i]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorBody(message: '$e'),
    );
  }
}

/// History tab body — confirmed + in-flight trips (never rejected — CONTEXT).
class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

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

/// DomainError-aware error body for the tab views.
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
          'Could not load trips.\n$message',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
