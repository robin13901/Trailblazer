// Trailblazer — RegionStatsFab: the bottom-right action button shown on the
// Regions tab (user request 2026-10-21). Occupies the same slot the TripFab
// uses on the Map tab, but with a leaderboard icon; tapping it opens the
// aggregate-statistics sheet.
//
// Deliberately reads NO provider at build time — it is inert at rest so it does
// not pull DB-backed providers into shared widget-test pump helpers (MEMORY:
// shared-pump-helper-provider-stubs). The sheet it opens reads the region list.

import 'dart:async';

import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
import 'package:auto_explore/features/regions/presentation/widgets/region_stats_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Glass-circle button that opens the [showRegionStatsSheet] stats sheet.
///
/// Mirrors the idle `TripFab` look (64 dp [GlassCircle]) so the Regions-tab
/// button is visually consistent with the Map-tab record button it replaces.
class RegionStatsFab extends ConsumerWidget {
  const RegionStatsFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same grey as the unselected nav-tab items (bottom_nav_shell.dart) so the
    // button icon reads as neutral chrome, not an active accent.
    final iconColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.5);
    return Semantics(
      button: true,
      label: 'Statistik anzeigen',
      child: GestureDetector(
        onTap: () => unawaited(showRegionStatsSheet(context, ref)),
        child: GlassCircle(
          size: 64,
          child: Icon(Icons.leaderboard, size: 28, color: iconColor),
        ),
      ),
    );
  }
}
