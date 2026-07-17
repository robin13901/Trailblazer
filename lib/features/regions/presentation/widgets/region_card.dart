// Trailblazer Phase 8, Plan 08-05 (Wave 2) / updated Phase 10, Plan 10-04:
// RegionCard — one card in the flat coverage-gated region browser list.
// Shows: level tag + region name + coverage % + km stats. NO progress bar
// (CONTEXT.md line 37).
//
// Plan 10-04: removed spinner + "N/M Kacheln" progress UI. Totals now come
// from the bundled table; no pending state, no spinner.

import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:flutter/material.dart';

/// Maps OSM admin_level to a human-readable German label.
/// Shared by RegionCard and RegionDetailSheet.
///
/// Correct German OSM hierarchy (Bavaria / most Länder):
///   4 = Bundesland, 6 = Landkreis, 8 = Gemeinde / Stadt,
///   9 = Ortsteil, 10 = Ortsteil / Stadtteil.
/// L5 (Regierungsbezirk) is real in Bavaria but not in scope for v1 — no
/// admin-level 5 regions are bundled. L3 (unused in DE) also absent.
String levelLabel(int level) {
  return switch (level) {
    4 => 'Bundesland',
    6 => 'Landkreis',
    8 => 'Gemeinde / Stadt',
    9 => 'Ortsteil',
    10 => 'Ortsteil / Stadtteil',
    _ => 'Region',
  };
}

/// One card in the flat region browser list.
///
/// Content (CONTEXT.md lines 36-37, Plan 08-05 SC):
///   Level-tag + RegionName   26.4%
///              3.2 / 12.1 km
///
/// No progress bar, no spinner. Tap invokes [onTap].
class RegionCard extends StatelessWidget {
  const RegionCard({
    required this.region,
    required this.onTap,
    super.key,
  });

  final RegionCoverage region;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tag = levelLabel(region.adminLevel);
    final kmStats = formatKmStats(region.drivenKm, region.totalKm);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      RegionLevelBadge(
                        label: tag,
                        colorScheme: colorScheme,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          region.name,
                          style: theme.textTheme.bodyLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    kmStats,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Coverage percentage — always shown; no spinner state (Plan 10-04).
            Text(
              region.percentLabel,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small level-tag badge displayed left of the region name.
/// Public so the detail sheet can reuse the same visual without widget
/// duplication.
class RegionLevelBadge extends StatelessWidget {
  const RegionLevelBadge({
    required this.label,
    required this.colorScheme,
    this.fontSize = 10,
    this.horizontalPadding = 6,
    this.verticalPadding = 2,
    this.borderRadius = 4,
    super.key,
  });

  final String label;
  final ColorScheme colorScheme;
  final double fontSize;
  final double horizontalPadding;
  final double verticalPadding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
