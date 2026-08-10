// Trailblazer Phase 6, Plan 06-05 Task 1:
// HistoryRow — compact row for a confirmed / in-flight trip in the History
// tab.
//
// Shows place names, date · duration · distance, and a status pill:
//   * matched && intervalCount == 0  → "No roads matched" (warning color)
//   * pending | pendingRoadData      → "Matching…" + spinner
//   * confirmed                      → no pill
// Never shows rejected trips (they are hard-deleted at Discard — CONTEXT
// deviation from ROADMAP SC4). Tapping the row opens the trip detail sheet;
// long-pressing it prompts to delete the trip (INB-04 discard flow, wired back
// onto the flat history list after the Inbox card was retired 2026-07-13).

import 'package:auto_explore/features/map/presentation/providers/selected_trip_provider.dart';
import 'package:auto_explore/features/matching/data/match_progress_provider.dart';
import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/widgets/discard_confirmation_dialog.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart'
    show formatDistance, formatDuration, formatTripDateTime, placeNamesLabel;
import 'package:auto_explore/features/trips/presentation/widgets/trip_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One History-list row.
class HistoryRow extends ConsumerStatefulWidget {
  const HistoryRow({required this.item, super.key});

  final TripListItem item;

  @override
  ConsumerState<HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends ConsumerState<HistoryRow> {
  /// Long-press → confirm → hard-delete the trip via the shared discard flow.
  ///
  /// Reuses [DiscardConfirmationDialog] + [TripsInboxRepository.discardTrip]
  /// (the same ordered delete the retired Inbox card used): invalidate coverage
  /// cache → delete THIS trip's intervals only → delete the trip row → recompute
  /// from the intervals that remain. Roads also driven by other trips survive;
  /// the row disappears on its own because the list is a DB stream. Silent on
  /// success (user request: no toast, no undo).
  Future<void> _confirmAndDelete() async {
    final item = widget.item;
    final confirmed = await DiscardConfirmationDialog.show(context);
    if (!confirmed || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    // If this trip is currently drawn on the map, drop the selection first so
    // the map doesn't keep a turquoise line pointing at a deleted trip.
    if (ref.read(selectedTripProvider) == item.id) {
      ref.read(selectedTripProvider.notifier).clear();
    }
    final repo = ref.read(tripsInboxRepositoryProvider);
    final cache = ref.read(thumbnailCacheProvider.notifier);
    final result = await repo.discardTrip(item.id);
    if (!mounted) return;
    await result.when(
      // Clear the cached thumbnail only after the delete is confirmed.
      ok: (_) async => cache.delete(item.id),
      err: (e) async =>
          messenger.showSnackBar(SnackBar(content: Text(e.message))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    return ListTile(
      onTap: () => showTripDetailSheet(context, ref, item),
      onLongPress: _confirmAndDelete,
      title: _PlaceNames(item: item),
      subtitle: Text(
        '${formatTripDateTime(item.startedAt)} · '
        '${formatDuration(item.duration)} · '
        '${formatDistance(item.distanceMeters)}',
        // Muted gray (matches the trip sheet's Start/Ziel two-liner) so the
        // second line reads with a touch more contrast against the title
        // (on-device feedback 2026-07-23).
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: _StatusPill(item: item),
    );
  }
}

/// Status pill for a History row. Returns [SizedBox.shrink] for confirmed
/// trips (no pill).
///
/// While a trip is in-flight it watches [matchProgressProvider] for a real
/// completion fraction streamed from the matcher isolate:
///   * fraction present → determinate spinner + `Matching… NN%`
///   * fraction absent  → indeterminate spinner + `Matching…` (queued /
///     still fetching roads)
class _StatusPill extends ConsumerWidget {
  const _StatusPill({required this.item});

  final TripListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          'Keine Straßen abgeglichen',
          style: theme.textTheme.labelSmall?.copyWith(color: warning),
        ),
      );
    }

    if (item.isInFlight) {
      final fraction = ref.watch(
        matchProgressProvider.select((m) => m[item.id]),
      );
      final color = theme.colorScheme.primary.withValues(alpha: 0.9);

      if (fraction != null) {
        // Real percentage streamed from the matcher isolate.
        final percent = (fraction * 100).round();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                value: fraction,
                strokeWidth: 2,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Wird abgeglichen … $percent %',
              style: theme.textTheme.labelSmall,
            ),
          ],
        );
      }

      // In-flight but no progress yet (queued / fetching roads) →
      // indeterminate spinner.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Text('Wird abgeglichen …', style: theme.textTheme.labelSmall),
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
      return Text('Standort', style: style);
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
      orElse: () => 'Standort…',
    );
    return Text(label, style: style);
  }
}
