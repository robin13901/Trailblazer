// Trailblazer trips:
// TripDetailSheet — draggable bottom sheet for a single trip's stats +
// "Auf Karte anzeigen" (2026-07-22, replacing the retired full-screen
// TripDetailScreen / TripRouteView).
//
// Mirrors RegionDetailSheet: a showModalBottomSheet hosting a
// DraggableScrollableSheet with a glass panel. Content is stats-only —
// place names + Dauer / Distanz / Ø-Tempo + Start/Ziel (place + time) — plus a
// "Auf Karte anzeigen" button that seeds the camera to the trip bounds, sets
// selectedTripProvider, and switches to the Map tab. The TripPathBridge
// (mounted in MapScreen) then paints the trip's on-road line in turquoise.
//
// Reuses regionSheetOpenProvider so the map shell hides its bottom-nav pill
// while the sheet is open (same as the region sheet).

import 'dart:async';
import 'dart:math' as math;

import 'package:auto_explore/features/map/domain/camera_state.dart';
import 'package:auto_explore/features/map/domain/follow_mode.dart';
import 'package:auto_explore/features/map/presentation/providers/camera_state_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/live_camera_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
import 'package:auto_explore/features/map/presentation/providers/selected_trip_provider.dart';
import 'package:auto_explore/features/regions/presentation/providers/region_sheet_open_provider.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/widgets/debug_export_button.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart'
    show
        formatDistance,
        formatDuration,
        formatSpeed,
        formatTripDateTime,
        placeNamesLabel,
        tripBounds;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Opens a draggable bottom sheet with stats for [item].
///
/// Sets [regionSheetOpenProvider] true for the sheet's lifetime so the map
/// shell hides its bottom nav pill (shared with the region sheet — it means
/// "a detail sheet is open").
Future<void> showTripDetailSheet(
  BuildContext context,
  WidgetRef ref,
  TripListItem item,
) async {
  ref.read(regionSheetOpenProvider.notifier).isOpen = true;
  // Size the sheet to roughly hug its content instead of a fixed screen
  // fraction. The content (handle + title + 3 stat rows + 2 two-line endpoint
  // rows + button) is ~460 dp tall; expressing that as a fraction of THIS
  // device's height keeps the "Auf Karte anzeigen" button just above the
  // bottom edge on every screen size, rather than leaving a big empty gap
  // below it on tall phones (on-device feedback 2026-07-23). Clamped so it
  // never collapses too small nor exceeds the drag ceiling.
  const contentHeightDp = 460.0;
  final screenHeight = MediaQuery.sizeOf(context).height;
  final initialSize = (contentHeightDp / screenHeight).clamp(0.35, 0.85);
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: initialSize,
        maxChildSize: 0.85,
        builder: (ctx, scrollController) => _TripDetailContent(
          item: item,
          scrollController: scrollController,
        ),
      ),
    );
  } finally {
    ref.read(regionSheetOpenProvider.notifier).isOpen = false;
  }
}

class _TripDetailContent extends ConsumerWidget {
  const _TripDetailContent({
    required this.item,
    required this.scrollController,
  });

  final TripListItem item;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 0-dim guard (mirrors region_detail_sheet.dart).
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        return _GlassDetailPanel(
          item: item,
          scrollController: scrollController,
          onShowOnMap: () => _handleShowOnMap(context, ref),
        );
      },
    );
  }

  void _handleShowOnMap(BuildContext context, WidgetRef ref) {
    final bounds = tripBounds(item);
    if (bounds != null) {
      final target = _cameraForBounds(bounds);
      ref.read(cameraStateProvider.notifier).jumpTo(target);

      // Update the focus pill immediately (it watches liveCameraProvider, not
      // cameraStateProvider) — same reasoning as the region sheet.
      ref.read(liveCameraProvider.notifier).update(
            CameraPosition(
              target: LatLng(target.latitude, target.longitude),
              zoom: target.zoom,
            ),
          );

      // Draw the trip's on-road line. The TripPathBridge (in MapScreen) watches
      // selectedTripProvider and drives the MapLibre layers (turquoise).
      ref.read(selectedTripProvider.notifier).show(item.id);

      // If the map is still alive, also fit the bounds for a smooth move,
      // deferred a frame so the branch switch below has taken effect.
      final current = ref.read(mapControllerProvider);
      if (current != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _fitBounds(current, bounds);
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

  void _fitBounds(MapLibreMapController controller, LatLngBounds bounds) {
    try {
      unawaited(
        controller.animateCamera(
          CameraUpdate.newLatLngBounds(
            bounds,
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

/// A [CameraState] centering on the trip bbox with a fitted zoom, follow-mode
/// OFF so the remounting map's GPS tracking doesn't snap away from the trip.
CameraState _cameraForBounds(LatLngBounds bounds) {
  final centerLat =
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2;
  final centerLon =
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2;
  return CameraState(
    latitude: centerLat,
    longitude: centerLon,
    zoom: _zoomForBounds(bounds),
    // Explicit: follow-mode OFF is the whole point (prevents the remounted
    // map's GPS tracking from snapping away from the seeded trip view).
    // ignore: avoid_redundant_argument_values
    followMode: FollowMode.none,
  );
}

/// Web-mercator "fit bounds" zoom for the trip bbox, filling ~80% of a nominal
/// 384×760 dp viewport, clamped to a sane [4, 16] range.
double _zoomForBounds(LatLngBounds bounds) {
  const worldTile = 512.0;
  const viewportW = 384.0;
  const viewportH = 760.0;
  const fraction = 0.8;

  final lonSpan = (bounds.northeast.longitude - bounds.southwest.longitude)
      .abs()
      .clamp(1e-6, 360.0);
  final lonZoom =
      _log2((viewportW / worldTile) * (360.0 / lonSpan) * fraction);

  final latRad1 = bounds.southwest.latitude * math.pi / 180.0;
  final latRad2 = bounds.northeast.latitude * math.pi / 180.0;
  final mercSpan = (_mercatorY(latRad2) - _mercatorY(latRad1))
      .abs()
      .clamp(1e-9, 2 * math.pi);
  final latZoom =
      _log2((viewportH / worldTile) * (2 * math.pi / mercSpan) * fraction);

  return math.min(lonZoom, latZoom).clamp(4.0, 16.0);
}

double _mercatorY(double latRad) =>
    math.log(math.tan(math.pi / 4 + latRad / 2));

double _log2(double x) => math.log(x) / math.ln2;

/// The glass-styled panel rendered inside the DraggableScrollableSheet.
class _GlassDetailPanel extends ConsumerWidget {
  const _GlassDetailPanel({
    required this.item,
    required this.scrollController,
    required this.onShowOnMap,
  });

  final TripListItem item;
  final ScrollController scrollController;
  final VoidCallback onShowOnMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final tint = isDark ? const Color(0x2A0A1728) : const Color(0x38FFFFFF);
    final borderColor =
        isDark ? const Color(0x40FFFFFF) : const Color(0x59FFFFFF);

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
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              children: [
                // Header: place-name label (start → end / loop).
                _TripTitle(item: item),
                const SizedBox(height: 20),
                _StatRow(
                  label: 'Dauer',
                  value: formatDuration(item.duration),
                  valueStyle: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Distanz',
                  value: formatDistance(item.distanceMeters),
                  valueStyle: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                _StatRow(
                  label: 'Ø-Tempo',
                  value:
                      formatSpeed(item.distanceMeters, item.durationSeconds),
                  valueStyle: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                _EndpointRow(
                  label: 'Start',
                  time: formatTripDateTime(item.startedAt),
                  lat: item.startLat,
                  lon: item.startLon,
                ),
                const SizedBox(height: 12),
                _EndpointRow(
                  label: 'Ziel',
                  time: item.endedAt == null
                      ? '—'
                      : formatTripDateTime(item.endedAt!),
                  lat: item.endLat,
                  lon: item.endLon,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: onShowOnMap,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Auf Karte anzeigen'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 12),
                  DebugExportButton(tripId: item.id),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Trip title — the resolved place-name label ("Start → Ziel" or a loop name).
class _TripTitle extends ConsumerWidget {
  const _TripTitle({required this.item});

  final TripListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
        );

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

/// A Start/Ziel row: label + place name (resolved) on one line, timestamp below.
class _EndpointRow extends ConsumerWidget {
  const _EndpointRow({
    required this.label,
    required this.time,
    required this.lat,
    required this.lon,
  });

  final String label;
  final String time;
  final double? lat;
  final double? lon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Resolve THIS endpoint's place name (start==end lookup is memoized, so a
    // single-point lookup here is cheap enough and keeps the row independent).
    final placeName = _resolvePlaceName(ref);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      // crossAxisAlignment defaults to center — the "Start"/"Ziel" label sits
      // vertically centered across the two right-hand lines (place name +
      // timestamp) rather than pinned to the top line (on-device feedback
      // 2026-07-23; was CrossAxisAlignment.start).
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                placeName,
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.end,
              ),
              Text(
                time,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// This endpoint's resolved place name, or "—" when its coords are unknown
  /// (e.g. a zero-point trip). Reuses the memoized [tripPlacesProvider] with
  /// both endpoints set to this point, reading its `startName`.
  String _resolvePlaceName(WidgetRef ref) {
    if (lat == null || lon == null) return '—';
    final places = ref.watch(
      tripPlacesProvider((
        startLat: lat!,
        startLon: lon!,
        endLat: lat!,
        endLon: lon!,
      )),
    );
    return places.maybeWhen(
      data: (p) => p.startName ?? 'Standort',
      orElse: () => 'Standort…',
    );
  }
}

/// Label + value stats row (mirrors region_detail_sheet.dart's _StatRow).
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
