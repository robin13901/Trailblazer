// Trailblazer Phase 8, Plan 08-05 (Wave 2):
// RegionDetailSheet — draggable bottom sheet for region stats + Jump-to-map.
//
// Stats-only (CONTEXT.md line 44-45, Plan 08-05 SC):
//   name + level tag + coverage % + km stats + Jump-to-on-map
//   NO breadcrumb, NO driven-ways list, NO top-trips list (permanently dropped).
//
// Jump-to-on-map pattern (RESEARCH Pitfall 6, lines 480-487):
//   1. Navigator.pop() — close sheet
//   2. StatefulNavigationShell.of(context)?.goBranch(0) OR context.go('/')
//   3. ref.listenManual(mapControllerProvider, ...) — await non-null controller,
//      then animateCamera(CameraUpdate.newLatLngBounds(adm.bbox, padding 40))
//
// 0-dim guard replicates glass_pill.dart:41-48 (RESEARCH Pitfall 5).
// withValues(alpha:) throughout; package imports only.

import 'dart:async';

import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/admin/data/admin_region_providers.dart';
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
    // Step 1: close the sheet.
    Navigator.of(context).pop();

    // Step 2: navigate to the map tab.
    // StatefulNavigationShell.maybeOf() returns null outside the shell context
    // (e.g. in widget tests).
    final shell = StatefulNavigationShell.maybeOf(context);
    if (shell != null) {
      shell.goBranch(0);
    } else {
      context.go('/');
    }

    // Step 3: look up region bbox and animate camera.
    final lookup = ref.read(adminRegionLookupProvider);
    final adm = lookup.regionByOsmId(region.osmId);
    if (adm == null) return;

    // The shell uses StatefulShellRoute.indexedStack, so the map tab (and its
    // controller) stays alive while the Regions tab is on top. But the map
    // surface was NOT the painted/frontmost branch until goBranch(0) above —
    // issuing animateCamera in this same synchronous tick fits the bounds
    // against a not-yet-frontmost platform view and the move is lost (bug
    // 2026-07-11: "map opens on last position, no pan/zoom"). Defer the
    // animation until AFTER the branch switch has painted a frame and the
    // platform view has settled, then fit the bounds.
    final current = ref.read(mapControllerProvider);
    if (current != null) {
      _animateToBboxDeferred(current, adm);
      return;
    }

    // Cold start: map tab has never mounted (controller still null). Wait for
    // onMapCreated to set the controller, then animate (also deferred).
    ProviderSubscription<MapLibreMapController?>? sub;
    sub = ref.listenManual(mapControllerProvider, (_, next) {
      if (next != null) {
        _animateToBboxDeferred(next, adm);
        sub?.close();
      }
    });
  }

  /// Fits the camera to [adm]'s bbox once the map surface has come forward.
  /// Waits for the next frame (so the IndexedStack has painted the map branch)
  /// plus a short settle delay for the platform view to size, then animates.
  void _animateToBboxDeferred(MapLibreMapController controller, AdminRegion adm) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 320), () {
        _animateToBbox(controller, adm);
      });
    });
  }

  void _animateToBbox(MapLibreMapController controller, AdminRegion adm) {
    // Wrap in try/catch — map must never crash (06-05 lesson).
    try {
      unawaited(
        controller.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(adm.bboxMinLat, adm.bboxMinLon),
              northeast: LatLng(adm.bboxMaxLat, adm.bboxMaxLon),
            ),
            left: 40,
            top: 40,
            right: 40,
            bottom: 40,
          ),
          duration: const Duration(milliseconds: 600),
        ),
      );
    } on Object {
      // Swallow — map controller exceptions must not propagate (06-05 lesson).
    }
  }
}

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
