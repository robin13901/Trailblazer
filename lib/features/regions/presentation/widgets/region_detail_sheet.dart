// Trailblazer Phase 8, Plan 08-05 (Wave 2):
// RegionDetailSheet — draggable bottom sheet for region stats + Jump-to-map.
//
// Stats-only (CONTEXT.md line 44-45, Plan 08-05 SC):
//   name + level tag + coverage % + km stats + Jump-to-on-map
//   NO breadcrumb, NO driven-ways list, NO top-trips list (permanently dropped).
//
// Jump-to-on-map (2026-07-11 rewrite — the animateCamera-after-goBranch
// approach never moved the camera):
//   The shell disposes MapWidget when off the Map tab (memory fix 2026-07-10)
//   and re-seeds its initialCameraPosition from cameraStateProvider on remount.
//   So we SEED the target into cameraStateProvider (center + fitted zoom,
//   follow-mode OFF) BEFORE goBranch(0). The remounting map then opens
//   directly at the region — no controller race, no fighting the GPS snap.
//   If the map happens to still be alive (controller non-null), we also
//   animateCamera for an immediate smooth move.
//
// 0-dim guard replicates glass_pill.dart:41-48 (RESEARCH Pitfall 5).
// withValues(alpha:) throughout; package imports only.

import 'dart:async';
import 'dart:math' as math;

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/regions/domain/region_coverage.dart';
import 'package:auto_explore/features/regions/presentation/widgets/region_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Opens a draggable bottom sheet with stats for [region].
Future<void> showRegionDetailSheet(
  BuildContext context,
  RegionCoverage region,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.4,
      maxChildSize: 0.85,
      builder: (ctx, scrollController) => _RegionDetailContent(
        region: region,
        scrollController: scrollController,
      ),
    ),
  );
}

class _RegionDetailContent extends ConsumerWidget {
  const _RegionDetailContent({
    required this.region,
    required this.scrollController,
  });

  final RegionCoverage region;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 0-dim guard (RESEARCH Pitfall 5 + glass_pill.dart:41-48).
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        return _GlassDetailPanel(
          region: region,
          scrollController: scrollController,
          onJumpToMap: () => _handleJumpToMap(context, ref),
        );
      },
    );
  }

  void _handleJumpToMap(BuildContext context, WidgetRef ref) {
    // Look up the region bbox first.
    final lookup = ref.read(adminRegionLookupProvider);
    final adm = lookup.regionByOsmId(region.osmId);

    if (adm != null) {
      // Compute the target camera (bbox center + a zoom that fits the bbox to
      // the viewport) and SEED it into cameraStateProvider with follow-mode
      // OFF. The Map tab's MapWidget is disposed while we're on the Regions
      // tab (memory fix 2026-07-10) and re-seeds its initialCameraPosition
      // from this provider on remount — so after goBranch(0) the map opens
      // ALREADY centered on the region. follow-mode none prevents MapLibre's
      // GPS tracking from immediately snapping the camera back to the user.
      final target = _cameraForBbox(adm);
      ref.read(cameraStateProvider.notifier).jumpTo(target);

      // If the map is still alive (rare: e.g. shell kept it mounted), also
      // animate for an immediate smooth move. Deferred a frame so the branch
      // switch below has taken effect.
      final current = ref.read(mapControllerProvider);
      if (current != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _animateTo(current, target);
        });
      }
    }

    // Close the sheet and switch to the Map tab.
    Navigator.of(context).pop();
    final shell = StatefulNavigationShell.maybeOf(context);
    if (shell != null) {
      shell.goBranch(0);
    } else {
      context.go('/');
    }
  }

  void _animateTo(MapLibreMapController controller, CameraState target) {
    // Wrap in try/catch — map must never crash (06-05 lesson).
    try {
      unawaited(
        controller.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(target.latitude, target.longitude),
            target.zoom,
          ),
          duration: const Duration(milliseconds: 600),
        ),
      );
    } on Object {
      // Swallow — map controller exceptions must not propagate (06-05 lesson).
    }
  }
}

/// Computes a [CameraState] that centers on [adm]'s bbox and picks a zoom that
/// fits the bbox into a typical phone viewport (follow-mode OFF so the seeded
/// position is not overridden by GPS tracking on map remount).
CameraState _cameraForBbox(AdminRegion adm) {
  final centerLat = (adm.bboxMinLat + adm.bboxMaxLat) / 2;
  final centerLon = (adm.bboxMinLon + adm.bboxMaxLon) / 2;
  return CameraState(
    latitude: centerLat,
    longitude: centerLon,
    zoom: _zoomForBbox(adm),
    // Explicit: follow-mode OFF is the whole point (prevents the remounted
    // map's GPS tracking from snapping away from the seeded region).
    // ignore: avoid_redundant_argument_values
    followMode: FollowMode.none,
  );
}

/// Web-mercator "fit bounds" zoom for the given bbox. Picks the zoom at which
/// the bbox's larger dimension fills ~80% of a nominal 384×760 dp viewport
/// (with a small margin), clamped to a sane [4, 15] range so a tiny Ortsteil
/// doesn't zoom to street level and a Bundesland doesn't clip.
double _zoomForBbox(AdminRegion adm) {
  const worldTile = 512.0; // MapLibre tile size in the zoom formula
  const viewportW = 384.0;
  const viewportH = 760.0;
  const fraction = 0.8; // fill ~80% of the viewport, leaving margin

  final lonSpan = (adm.bboxMaxLon - adm.bboxMinLon).abs().clamp(1e-6, 360.0);

  // Longitude: fraction of the world width the bbox occupies.
  final lonZoom =
      _log2((viewportW / worldTile) * (360.0 / lonSpan) * fraction);

  // Latitude: use the mercator-projected span so tall regions fit vertically.
  final latRad1 = adm.bboxMinLat * math.pi / 180.0;
  final latRad2 = adm.bboxMaxLat * math.pi / 180.0;
  final mercSpan =
      (_mercatorY(latRad2) - _mercatorY(latRad1)).abs().clamp(1e-9, 2 * math.pi);
  final latZoom =
      _log2((viewportH / worldTile) * (2 * math.pi / mercSpan) * fraction);

  final z = math.min(lonZoom, latZoom);
  return z.clamp(4.0, 15.0);
}

double _mercatorY(double latRad) =>
    math.log(math.tan(math.pi / 4 + latRad / 2));

double _log2(double x) => math.log(x) / math.ln2;

/// The glass-styled panel rendered inside the DraggableScrollableSheet.
class _GlassDetailPanel extends StatelessWidget {
  const _GlassDetailPanel({
    required this.region,
    required this.scrollController,
    required this.onJumpToMap,
  });

  final RegionCoverage region;
  final ScrollController scrollController;
  final VoidCallback onJumpToMap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Semi-transparent tinted rounded container — consistent with
    // GlassPillFallback (glass_pill.dart). BackdropFilter works fine over a
    // Scaffold surface (unlike over a MapLibre PlatformView), but we stay with
    // the same tinted approach for visual consistency and simplicity.
    final tint = isDark ? const Color(0x2A0A1728) : const Color(0x38FFFFFF);
    final borderColor =
        isDark ? const Color(0x40FFFFFF) : const Color(0x59FFFFFF);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.97),
        border: Border.all(color: borderColor),        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
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
                // Header: name + level tag (NO breadcrumb — CONTEXT.md 43).
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        region.name,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    RegionLevelBadge(
                      label: levelLabel(region.adminLevel),
                      colorScheme: colorScheme,
                      fontSize: 12,
                      horizontalPadding: 10,
                      verticalPadding: 4,
                      borderRadius: 8,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Coverage % — one decimal (CONTEXT.md line 49).
                _StatRow(
                  label: 'Befahren',
                  value: region.percentLabel,
                  valueStyle: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 12),
                // km stats (CONTEXT.md line 50: driven km + total km).
                _StatRow(
                  label: 'Strecke',
                  value: formatKmStats(region.drivenKm, region.totalKm),
                  valueStyle: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 32),
                // Jump-to-on-map.
                FilledButton.icon(
                  onPressed: onJumpToMap,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Im Karte anzeigen'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Label + value stats row.
class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    this.valueStyle,
  });

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
