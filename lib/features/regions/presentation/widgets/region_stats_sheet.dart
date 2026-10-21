// Trailblazer — RegionStatsSheet: a draggable bottom sheet with aggregate
// statistics across ALL regions in the browser list (user request 2026-10-21).
//
// Mirrors RegionDetailSheet's glass styling exactly (same tinted rounded
// container, drag handle, padding, typography and `_StatRow` layout) so the
// two sheets read as siblings.
//
// Shows:
//   - Regionen: how many regions are currently in the list.
//   - Gesamtscore: sum of every region's score (coverage fraction × driven km).
//   - Deutschland: aggregate coverage over all Bundesland-level regions
//     (adminLevel == 4) — summed driven + total km and the resulting %.
//
// Sets [regionSheetOpenProvider] true for its lifetime so the map shell hides
// its bottom nav pill while the sheet is open (same as RegionDetailSheet).

import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_browser_provider.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_sheet_open_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens a draggable bottom sheet with aggregate statistics across the whole
/// region browser list. Styled identically to `showRegionDetailSheet`.
Future<void> showRegionStatsSheet(BuildContext context, WidgetRef ref) async {
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
            _RegionStatsContent(scrollController: scrollController),
      ),
    );
  } finally {
    ref.read(regionSheetOpenProvider.notifier).isOpen = false;
  }
}

class _RegionStatsContent extends StatelessWidget {
  const _RegionStatsContent({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    // 0-dim guard mirrors RegionDetailSheet (RESEARCH Pitfall 5 +
    // glass_pill.dart:41-48) — liquid_glass paints via Picture.toImageSync and
    // crashes on a 0-sized constraint.
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

/// Immutable aggregate derived from the region list. Pure — no Riverpod.
@immutable
class _StatsSummary {
  const _StatsSummary({
    required this.regionCount,
    required this.totalScore,
    required this.germanyDrivenM,
    required this.germanyTotalM,
  });

  /// Builds the summary from every region in the browser list. Germany is the
  /// sum of all Bundesland-level regions (adminLevel == 4) — the app has no
  /// single "Deutschland" card (level 2 is excluded from the list), so the
  /// country total is reconstructed by aggregating its states.
  factory _StatsSummary.from(List<RegionCoverage> regions) {
    var totalScore = 0.0;
    var germanyDrivenM = 0.0;
    var germanyTotalM = 0.0;
    for (final region in regions) {
      totalScore += region.score;
      if (region.adminLevel == 4) {
        germanyDrivenM += region.drivenLengthM;
        germanyTotalM += region.totalLengthM;
      }
    }
    return _StatsSummary(
      regionCount: regions.length,
      totalScore: totalScore,
      germanyDrivenM: germanyDrivenM,
      germanyTotalM: germanyTotalM,
    );
  }

  final int regionCount;
  final double totalScore;
  final double germanyDrivenM;
  final double germanyTotalM;

  /// True once at least one Bundesland is present so a country % is meaningful.
  bool get hasGermany => germanyTotalM > 0;

  double get germanyPercent =>
      coveragePercent(germanyDrivenM, germanyTotalM);
}

/// The glass-styled panel — a copy of RegionDetailSheet's `_GlassDetailPanel`
/// decoration and layout so the two sheets are visually identical.
class _GlassStatsPanel extends ConsumerWidget {
  const _GlassStatsPanel({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Reactive: the list re-emits after every recompute write, so the stats
    // update live while the sheet is open.
    final regions =
        ref.watch(regionBrowserProvider).value ?? const <RegionCoverage>[];
    final summary = _StatsSummary.from(regions);

    // Same tint/border tokens as _GlassDetailPanel (GlassPillFallback-consistent).
    final tint = isDark ? const Color(0x2A0A1728) : const Color(0x38FFFFFF);
    final borderColor = isDark
        ? const Color(0x40FFFFFF)
        : const Color(0x59FFFFFF);

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
                // Header: title + leaderboard icon.
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
                    Icon(Icons.leaderboard, color: colorScheme.primary),
                  ],
                ),
                const SizedBox(height: 20),
                // General totals across the whole list.
                _StatRow(
                  label: 'Regionen',
                  value: summary.regionCount.toString(),
                  valueStyle: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Gesamtscore',
                  value: oneDecimalDe(summary.totalScore),
                  valueStyle: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                // Country section — aggregate over all Bundesländer.
                Text(
                  'Deutschland',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Befahren',
                  value: summary.hasGermany
                      ? formatPercent(summary.germanyPercent)
                      : '—',
                  valueStyle: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Strecke',
                  value: summary.hasGermany
                      ? formatKmStats(
                          summary.germanyDrivenM / 1000.0,
                          summary.germanyTotalM / 1000.0,
                        )
                      : '—',
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

/// Label + value stats row — a copy of RegionDetailSheet's `_StatRow` so the
/// two sheets lay out identically.
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
