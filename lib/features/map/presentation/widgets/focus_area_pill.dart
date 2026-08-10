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
//
// 2026-07-25 (#8): while a match / coverage recompute is IN FLIGHT, the pill
// shows a PULSING border in the coverage-line colour and swaps the % line for a
// progress/status string. When idle it reverts to the normal border + % label.

import 'dart:async';

import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/coverage/data/coverage_providers.dart';
import 'package:auto_explore/features/coverage/domain/coverage_color_preset.dart';
import 'package:auto_explore/features/coverage/presentation/coverage_preset_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/map/presentation/widgets/glass_pill.dart';
import 'package:auto_explore/features/matching/data/match_progress_provider.dart';
import 'package:auto_explore/features/regions/data/region_totals_lookup.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/domain/zoom_level_mapper.dart';
import 'package:auto_explore/features/regions/presentation/providers/focus_pill_provider.dart';
import 'package:auto_explore/features/regions/presentation/widgets/region_detail_sheet.dart';
import 'package:auto_explore/features/trips/presentation/providers/inbox_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live two-line pill: region name on top, coverage % (or progress) underneath.
///
/// Renders inside [GlassPill] — inherits the G1 gate flag (liquid glass vs.
/// semi-transparent fallback) and the 0-dim guard. While a match/recompute is
/// in flight, an [AnimationController]-driven overlay border pulses in the
/// coverage-line colour.
///
/// Tapping the pill resolves the region currently under the map view (same
/// fallback chain as [FocusPillNotifier]) and opens [showRegionDetailSheet].
class FocusAreaPill extends ConsumerStatefulWidget {
  const FocusAreaPill({super.key});

  @override
  ConsumerState<FocusAreaPill> createState() => _FocusAreaPillState();
}

class _FocusAreaPillState extends ConsumerState<FocusAreaPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(focusPillProvider);
    final theme = Theme.of(context);

    // A match / recompute is in flight globally (pending + pendingRoadData).
    final inFlight = ref.watch(inFlightCountProvider).value ?? 0;
    final computing = inFlight > 0;

    // Best available progress fraction across in-flight trips (0..1), if any.
    final progressMap = ref.watch(matchProgressProvider);
    final fraction = progressMap.isEmpty
        ? null
        : progressMap.values.reduce((a, b) => a > b ? a : b);

    // Drive the pulse only while computing; stop + reset otherwise.
    if (computing) {
      if (!_pulse.isAnimating) unawaited(_pulse.repeat(reverse: true));
    } else {
      if (_pulse.isAnimating) {
        _pulse
          ..stop()
          ..value = 0;
      }
    }

    // Coverage-line colour (matches the orange/turquoise overlay line).
    final preset = ref.watch(coveragePresetValueProvider);
    final lineColor = _hexToColor(
      preset.forBrightness(theme.brightness).fullHex,
    );

    // Hold-last-value: before the first resolve, show neutral placeholder so
    // the pill is never blank. After first resolve, name + % remain visible
    // during subsequent re-resolves (CONTEXT.md lines 29, 55).
    final name = state.name ?? 'Standort';
    final percent = state.percentLabel ?? '— %';

    // While computing, show a status/progress string instead of the % label.
    final String subtitle;
    if (computing) {
      subtitle = fraction != null
          ? 'Wird abgeglichen … ${(fraction * 100).round()} %'
          : 'Wird abgeglichen …';
    } else {
      subtitle = percent;
    }

    return Semantics(
      label:
          'Fokusgebiet: $name, ${computing ? subtitle : 'Abdeckung $percent'}',
      button: true,
      child: GestureDetector(
        onTap: () => unawaited(_openSheet(context, ref)),
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            // Pulsing border overlay drawn on top of the GlassPill only while
            // computing. Opacity eases 0.25→0.9 and back.
            final borderAlpha = computing ? 0.25 + 0.65 * _pulse.value : 0.0;
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: computing
                    ? Border.all(
                        color: lineColor.withValues(alpha: borderAlpha),
                        width: 2,
                      )
                    : null,
              ),
              child: child,
            );
          },
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
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: computing
                        ? lineColor
                        : theme.colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
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

    // Denominator MUST match the regions tab (region_browser_provider):
    //   real per-region Kfz total (bundled)  →  haversine bbox total.
    final totalsLookup = ref.read(regionTotalsLookupProvider);
    await totalsLookup.ensureLoaded();
    if (!context.mounted) return;
    final bundledTotal = totalsLookup.totalFor(region.osmId.toString());
    final totalLengthM =
        row?.realTotalLengthM ?? bundledTotal ?? row?.totalLengthM ?? 0;

    final rc = RegionCoverage(
      osmId: region.osmId,
      adminLevel: region.adminLevel,
      name: region.nameDe ?? region.name,
      drivenLengthM: row?.drivenLengthM ?? 0,
      totalLengthM: totalLengthM,
    );

    await showRegionDetailSheet(context, ref, rc);
  }
}

/// '#RRGGBB' → opaque [Color] (mirrors coverage_color_section._hexToColor).
Color _hexToColor(String hex) {
  final clean = hex.replaceFirst('#', '');
  return Color(int.parse('FF$clean', radix: 16));
}
