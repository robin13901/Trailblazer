// Trailblazer — TripStatsSheet: a draggable bottom sheet with aggregate
// statistics across all trips in the history list (user request 2026-10-21).
//
// Sibling of RegionStatsSheet — same glass styling (tinted rounded container,
// drag handle, padding, typography, `_StatRow` layout) and the same FAB-slot
// entry point, but on the Trips tab.
//
// Shows:
//   - Fahrten: how many trips are in the history list.
//   - Gesamtstrecke: summed distance across all trips (hero stat).
//   - Gesamtzeit: summed duration across all trips.
//   - Durchschnitt: distance / duration per trip (over trips that have a value).
//
// Reuses the trip-card formatters (formatDistance / formatDuration) so the
// aggregate values read identically to the per-trip numbers.

import 'package:auto_explore/features/regions/presentation/providers/region_sheet_open_provider.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens a draggable bottom sheet with aggregate statistics across the whole
/// trip history list. Styled identically to the region + trip detail sheets.
Future<void> showTripStatsSheet(BuildContext context, WidgetRef ref) async {
  ref.read(regionSheetOpenProvider.notifier).isOpen = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.45,
        maxChildSize: 0.85,
        builder: (ctx, scrollController) =>
            _TripStatsContent(scrollController: scrollController),
      ),
    );
  } finally {
    ref.read(regionSheetOpenProvider.notifier).isOpen = false;
  }
}

class _TripStatsContent extends StatelessWidget {
  const _TripStatsContent({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    // 0-dim guard mirrors the detail sheets (liquid_glass paints via
    // Picture.toImageSync and crashes on a 0-sized constraint).
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        return _GlassStatsPanel(scrollController: scrollController);
      },
    );
  }
}

/// Immutable aggregate derived from the trip list. Pure — no Riverpod.
@immutable
class _TripStatsSummary {
  const _TripStatsSummary({
    required this.tripCount,
    required this.totalMeters,
    required this.totalSeconds,
    required this.tripsWithDistance,
    required this.tripsWithDuration,
  });

  factory _TripStatsSummary.from(List<TripListItem> trips) {
    var totalMeters = 0.0;
    var totalSeconds = 0;
    var tripsWithDistance = 0;
    var tripsWithDuration = 0;
    for (final trip in trips) {
      final meters = trip.distanceMeters;
      if (meters != null) {
        totalMeters += meters;
        tripsWithDistance++;
      }
      final seconds = trip.durationSeconds;
      if (seconds != null) {
        totalSeconds += seconds;
        tripsWithDuration++;
      }
    }
    return _TripStatsSummary(
      tripCount: trips.length,
      totalMeters: totalMeters,
      totalSeconds: totalSeconds,
      tripsWithDistance: tripsWithDistance,
      tripsWithDuration: tripsWithDuration,
    );
  }

  final int tripCount;
  final double totalMeters;
  final int totalSeconds;
  final int tripsWithDistance;
  final int tripsWithDuration;

  Duration get totalDuration => Duration(seconds: totalSeconds);

  /// Average distance in meters over trips that have a distance, or null when
  /// none do (so [formatDistance] renders "—").
  double? get avgMeters =>
      tripsWithDistance == 0 ? null : totalMeters / tripsWithDistance;

  /// Average duration over trips that have a duration, or null when none do.
  Duration? get avgDuration => tripsWithDuration == 0
      ? null
      : Duration(seconds: (totalSeconds / tripsWithDuration).round());
}

/// The glass-styled panel — same decoration and layout as the region + trip
/// detail sheets so every sheet in the app reads as a sibling.
class _GlassStatsPanel extends ConsumerWidget {
  const _GlassStatsPanel({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Reactive: the history stream re-emits as trips are added / matched, so
    // the stats update live while the sheet is open.
    final trips =
        ref.watch(historyTripsProvider).value ?? const <TripListItem>[];
    final summary = _TripStatsSummary.from(trips);

    final tint = isDark ? const Color(0x2A0A1728) : const Color(0x38FFFFFF);
    final borderColor = isDark
        ? const Color(0x40FFFFFF)
        : const Color(0x59FFFFFF);

    final strongValue = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.97),
        border: Border.all(color: borderColor),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(color: tint, blurRadius: 24, offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        children: [
          // Drag handle.
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Scrollable stats body.
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              children: [
                // Header: title + stats icon.
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Statistik',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.bar_chart, color: colorScheme.primary),
                  ],
                ),
                const SizedBox(height: 20),
                _StatRow(
                  label: 'Fahrten',
                  value: summary.tripCount.toString(),
                  valueStyle: strongValue,
                ),
                const SizedBox(height: 12),
                // Hero stat — total distance (parallels "Befahren" in the
                // region stats sheet).
                _StatRow(
                  label: 'Gesamtstrecke',
                  value: formatDistance(summary.totalMeters),
                  valueStyle: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Gesamtzeit',
                  value: formatDuration(summary.totalDuration),
                  valueStyle: strongValue,
                ),
                const SizedBox(height: 24),
                // Averages section.
                Text(
                  'Durchschnitt',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Strecke pro Fahrt',
                  value: formatDistance(summary.avgMeters),
                  valueStyle: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Dauer pro Fahrt',
                  value: formatDuration(summary.avgDuration),
                  valueStyle: theme.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Label + value stats row — a copy of the detail sheets' `_StatRow` so every
/// sheet lays out identically.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, this.valueStyle});

  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        Text(value, style: valueStyle ?? theme.textTheme.bodyLarge),
      ],
    );
  }
}
