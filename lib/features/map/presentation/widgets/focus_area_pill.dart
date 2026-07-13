// Trailblazer Phase 8, Plan 08-04 (Wave 2) + 08-06 (Wave 3):
// Live two-line FocusAreaPill — replaces the Phase-2 stub.
//
// Watches focusPillProvider; renders region name over coverage % via GlassPill.
// Hold-last-value: shows a neutral German placeholder until the first resolve
// completes, so the pill is never blank and GlassPill's 0-dim guard is never
// hit with zero content.
//
// Plan 08-06: Tapping the pill resolves the current focus region (same
// fallback chain as the background notifier) and opens showRegionDetailSheet.

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/domain/zoom_level_mapper.dart';
import 'package:auto_explore/features/regions/presentation/providers/focus_pill_provider.dart';
import 'package:auto_explore/features/regions/presentation/widgets/region_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live two-line pill: region name on top, coverage % underneath.
///
/// Renders inside [GlassPill] — inherits the G1 gate flag (liquid glass vs.
/// semi-transparent fallback) and the 0-dim guard.
///
/// Tapping the pill resolves the region currently under the map view (same
/// fallback chain as [FocusPillNotifier]) and opens [showRegionDetailSheet].
///
/// Drop-in replacement for the Phase-2 stub — map_screen.dart is unchanged.
class FocusAreaPill extends ConsumerWidget {
  const FocusAreaPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(focusPillProvider);
    final theme = Theme.of(context);

    // Hold-last-value: before the first resolve, show neutral placeholder so
    // the pill is never blank (and GlassPill's 0-dim guard is never triggered
    // with zero-height content). After first resolve, name + % remain visible
    // during subsequent re-resolves (CONTEXT.md lines 29, 55).
    final name = state.name ?? 'Standort';
    final percent = state.percentLabel ?? '— %';

    return Semantics(
      label: 'Fokusgebiet: $name, Abdeckung $percent',
      button: true,
      child: GestureDetector(
        onTap: () => _openSheet(context, ref),
        child: GlassPill(
          overMap: true,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                percent,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Resolves the region currently under the map view (same fallback chain
  /// as [FocusPillNotifier]) and opens [showRegionDetailSheet].
  Future<void> _openSheet(BuildContext context, WidgetRef ref) async {
    final camera = ref.read(liveCameraProvider);
    final lookup = ref.read(adminRegionLookupProvider);
    await lookup.ensureLoaded();

    // Resolve the SAME region the pill is showing: walk fallbackLevelsFrom(zoom).
    final zoom = camera?.zoom ?? 16.0;
    final lat = camera?.latitude ?? 0.0;
    final lon = camera?.longitude ?? 0.0;

    final region = await () async {
      for (final level in fallbackLevelsFrom(zoom)) {
        final r = await lookup.regionAt(lat, lon, level);
        if (r != null) return r;
      }
      return null;
    }();

    // Nothing under view (e.g. genuinely outside Germany with no fallback).
    if (region == null) return;

    // Guard: context may have unmounted during the async region lookup.
    if (!context.mounted) return;

    final cacheDao = ref.read(coverageCacheDaoProvider);
    final row = await cacheDao.getByRegionId(region.osmId.toString());

    // Guard: context may have unmounted during the async cache read.
    if (!context.mounted) return;

    final rc = RegionCoverage(
      osmId: region.osmId,
      adminLevel: region.adminLevel,
      name: region.nameDe ?? region.name,
      drivenLengthM: row?.drivenLengthM ?? 0,
      totalLengthM: row?.totalLengthM ?? 0,
    );

    await showRegionDetailSheet(context, ref, rc);
  }
}
