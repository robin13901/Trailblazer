// Trailblazer Phase 6, Plan 06-05 Task 1:
// HistoryRow — compact row for a confirmed / in-flight trip in the History
// tab.
//
// Shows place names, date · duration · distance, and a status pill:
//   * matched && intervalCount == 0  → "No roads matched" (warning color)
//   * pending | pendingRoadData      → "Matching…" + spinner
//   * confirmed                      → no pill
// Never shows rejected trips (they are hard-deleted at Discard — CONTEXT
// deviation from ROADMAP SC4). Tapping the row navigates to /trips/:id.

import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart'
    show formatDistance, formatDuration, formatTripDateTime, placeNamesLabel;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// One History-list row.
class HistoryRow extends ConsumerWidget {
  const HistoryRow({required this.item, super.key});

  final TripListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: () => context.push('/trips/${item.id}'),
      title: _PlaceNames(item: item),
      subtitle: Text(
        '${formatTripDateTime(item.startedAt)} · '
        '${formatDuration(item.duration)} · '
        '${formatDistance(item.distanceMeters)}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: _StatusPill(item: item),
    );
  }
}

/// Status pill for a History row. Returns [SizedBox.shrink] for confirmed
/// trips (no pill).
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.item});

  final TripListItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (item.isFailMatched) {
      // Warning color — the matcher ran but found no road coverage (Q10).
      final warning = theme.colorScheme.error;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'No roads matched',
          style: theme.textTheme.labelSmall?.copyWith(color: warning),
        ),
      );
    }

    if (item.isInFlight) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 8),
          Text('Matching…', style: theme.textTheme.labelSmall),
        ],
      );
    }

    // Confirmed (or any other non-flagged status) → no pill.
    return const SizedBox.shrink();
  }
}

/// Watches [tripPlacesProvider] for the row's endpoint place names.
class _PlaceNames extends ConsumerWidget {
  const _PlaceNames({required this.item});

  final TripListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = Theme.of(context).textTheme.bodyLarge;

    if (item.startLat == null ||
        item.startLon == null ||
        item.endLat == null ||
        item.endLon == null) {
      return Text('Location', style: style);
    }

    final places = ref.watch(
      tripPlacesProvider((
        startLat: item.startLat!,
        startLon: item.startLon!,
        endLat: item.endLat!,
        endLon: item.endLon!,
      )),
    );

    final label = places.maybeWhen(
      data: (p) => placeNamesLabel(p.startName, p.endName),
      orElse: () => 'Location…',
    );
    return Text(label, style: style);
  }
}
