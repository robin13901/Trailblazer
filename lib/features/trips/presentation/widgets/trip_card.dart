// Trailblazer Phase 6, Plan 06-05 Task 1:
// TripCard — one Inbox card per pending (matched) trip.
//
// Shows place names, date/time · duration · distance, and Keep + Discard
// buttons. The whole card surface is tappable → /trips/:id.
//
// Keep flips status matched→confirmed silently (no toast on success). Discard
// shows a confirmation modal; on confirm it runs the repository's ordered
// delete and clears the thumbnail cache.

import 'package:auto_explore/features/trips/data/thumbnail_providers.dart';
import 'package:auto_explore/features/trips/data/trip_place_lookup_providers.dart';
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/domain/trip_list_item.dart';
import 'package:auto_explore/features/trips/presentation/widgets/discard_confirmation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

// ---------------------------------------------------------------------------
// Shared trip-formatting helpers (reused by HistoryRow + TripDetailScreen).
// ---------------------------------------------------------------------------

const List<String> _kWeekdayNames = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _kMonthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// e.g. "Wed 8 Jul, 14:32". Locale-agnostic (no intl dependency).
String formatTripDateTime(DateTime dt) {
  final weekday = _kWeekdayNames[dt.weekday - 1];
  final month = _kMonthNames[dt.month - 1];
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$weekday ${dt.day} $month, $hh:$mm';
}

/// e.g. "42 min" or "1 h 12 min". Null-safe → "—" when duration is unknown.
String formatDuration(Duration? d) {
  if (d == null) return '—';
  final totalMinutes = d.inMinutes;
  if (totalMinutes < 60) return '$totalMinutes min';
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  return '$hours h $minutes min';
}

/// e.g. "28.4 km" or "820 m". Null-safe → "—".
String formatDistance(double? meters) {
  if (meters == null) return '—';
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000;
  return '${km.toStringAsFixed(1)} km';
}

/// Human-readable start→end place label from resolved place names. Loops
/// collapse to a single name; nulls fall back to "Location".
String placeNamesLabel(String? startName, String? endName) {
  final start = startName ?? 'Standort';
  final end = endName ?? 'Standort';
  if (startName != null && startName == endName) return start;
  return '$start → $end';
}

/// Build a [LatLngBounds] for a trip from its bbox corners, falling back to a
/// tiny box around the start/end coords, or `null` when nothing is known.
LatLngBounds? tripBounds(TripListItem item) {
  if (item.bboxMinLat != null &&
      item.bboxMinLon != null &&
      item.bboxMaxLat != null &&
      item.bboxMaxLon != null) {
    return LatLngBounds(
      southwest: LatLng(item.bboxMinLat!, item.bboxMinLon!),
      northeast: LatLng(item.bboxMaxLat!, item.bboxMaxLon!),
    );
  }
  final coords = tripEndpoints(item);
  if (coords.length < 2) return null;
  final lats = coords.map((c) => c.latitude).toList();
  final lons = coords.map((c) => c.longitude).toList();
  var minLat = lats.reduce((a, b) => a < b ? a : b);
  var maxLat = lats.reduce((a, b) => a > b ? a : b);
  var minLon = lons.reduce((a, b) => a < b ? a : b);
  var maxLon = lons.reduce((a, b) => a > b ? a : b);
  // Guard against a zero-area bbox (start == end) — LatLngBounds asserts
  // southwest.latitude <= northeast.latitude but a zero span renders poorly.
  if (maxLat - minLat < 1e-4) {
    minLat -= 5e-4;
    maxLat += 5e-4;
  }
  if (maxLon - minLon < 1e-4) {
    minLon -= 5e-4;
    maxLon += 5e-4;
  }
  return LatLngBounds(
    southwest: LatLng(minLat, minLon),
    northeast: LatLng(maxLat, maxLon),
  );
}

/// The start/end endpoints of a trip as a polyline. The full GPS trace is not
/// carried in the [TripListItem] read-model, so the card thumbnail draws a
/// straight start→end segment; the detail screen loads the full polyline.
List<LatLng> tripEndpoints(TripListItem item) {
  final points = <LatLng>[];
  if (item.startLat != null && item.startLon != null) {
    points.add(LatLng(item.startLat!, item.startLon!));
  }
  if (item.endLat != null && item.endLon != null) {
    points.add(LatLng(item.endLat!, item.endLon!));
  }
  return points;
}

// ---------------------------------------------------------------------------

/// One Inbox card for a pending (matched) trip.
class TripCard extends ConsumerStatefulWidget {
  const TripCard({required this.item, super.key});

  final TripListItem item;

  @override
  ConsumerState<TripCard> createState() => _TripCardState();
}

class _TripCardState extends ConsumerState<TripCard> {
  Future<void> _onKeep() async {
    final messenger = ScaffoldMessenger.of(context);
    final result =
        await ref.read(tripsInboxRepositoryProvider).confirmTrip(widget.item.id);
    if (!mounted) return;
    result.when(
      // Silent on success (CONTEXT: Keep is silent, no modal, no toast).
      ok: (_) {},
      err: (e) => messenger.showSnackBar(
        SnackBar(content: Text(e.message)),
      ),
    );
  }

  Future<void> _onDiscard() async {
    final confirmed = await DiscardConfirmationDialog.show(context);
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(tripsInboxRepositoryProvider);
    final cache = ref.read(thumbnailCacheProvider.notifier);
    final result = await repo.discardTrip(widget.item.id);
    if (!mounted) return;
    await result.when(
      ok: (_) async {
        // Clear the cached thumbnail only after the repository confirms the
        // delete succeeded.
        await cache.delete(widget.item.id);
      },
      err: (e) async {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/trips/${item.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PlaceNames(item: item),
                  const SizedBox(height: 4),
                  Text(
                    '${formatTripDateTime(item.startedAt)} · '
                    '${formatDuration(item.duration)} · '
                    '${formatDistance(item.distanceMeters)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _onDiscard,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: const Text('Verwerfen'),
                  ),
                  FilledButton(
                    onPressed: _onKeep,
                    child: const Text('Behalten'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Watches [tripPlacesProvider] for the card's endpoint place names.
class _PlaceNames extends ConsumerWidget {
  const _PlaceNames({required this.item});

  final TripListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium;

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
