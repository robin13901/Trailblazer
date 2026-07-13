// Trailblazer Phase 6, Plan 06-05 Task 3 (route render swapped in 06-07):
// TripDetailScreen — the full-screen `/trips/:id` detail view.
//
// Renders a trip's raw GPS polyline (muted) plus its matched intervals
// (accent) as a STATIC route render ([TripRouteView] — a CustomPainter, no
// MapLibre surface), a compact stat strip, and a delete action that runs the
// same ordered discard as the Inbox card. Two banners cover the edge cases:
//   * Fail-matched (intervalCount == 0) — "No roads matched" warning banner;
//     the matched overlay is skipped.
//   * Offline (way geometry unavailable — network error + cache miss, or
//     empty ways while intervals exist) — info banner; only the raw polyline
//     draws (Issue 6).
//
// **Why no map here (06-07 re-drive #4):** mounting a second live MapLibreMap
// on this route spun up a second native GL/EGL surface (~500 MB) on top of the
// Map tab's, OOM-crashing the app on navigation. TripRouteView paints the same
// geometry the loader already computes. The MapLibre overlay helpers in
// `trip_overlay_layers.dart` are retained for Phase 7's app-wide coverage
// rendering on the single Map-tab map.

import 'dart:async';
import 'dart:math' as math;

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/data/trips_repository_inbox_extensions.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:auto_explore/features/trips/presentation/widgets/debug_export_button.dart';
import 'package:auto_explore/features/trips/presentation/widgets/discard_confirmation_dialog.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart'
    show formatDistance, formatDuration, tripBounds;
import 'package:auto_explore/features/trips/presentation/widgets/trip_overlay_layers.dart'
    show TripDetailData;
import 'package:auto_explore/features/trips/presentation/widgets/trip_route_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Loads the full [TripDetailData] for a trip id: the read-model item, the raw
/// GPS polyline from `trip_points`, and — when the trip matched — the matched
/// interval segments reconstructed from Overpass way geometry.
///
/// The `FutureProviderFamily` concrete type is internal to Riverpod, so the
/// type is left inferred (matches `tripPlacesProvider`).
// ignore: specify_nonobvious_property_types
final tripDetailDataProvider =
    FutureProvider.family<TripDetailData, int>((ref, tripId) async {
  final db = ref.watch(appDatabaseProvider);
  return loadTripDetailData(
    tripId: tripId,
    inboxDao: TripsInboxDao(db),
    tripsDao: ref.watch(tripsDaoProvider),
    intervalsDao: DrivenWayIntervalsDao(db),
    waySource: ref.watch(wayCandidateSourceProvider),
  );
});

/// Pure loader for a trip's detail data — extracted from the provider so it can
/// be unit-tested with fake DAOs + a fake [WayCandidateSource] (the offline
/// branches are proven here without a live map).
///
/// Offline fallback (Issue 6): when the way source throws (network error +
/// cache miss) OR returns no ways while intervals exist (cache-expired), the
/// matched overlay is skipped, `offline` is set, and only the raw polyline
/// remains renderable.
Future<TripDetailData> loadTripDetailData({
  required int tripId,
  required TripsInboxDao inboxDao,
  required TripsDao tripsDao,
  required DrivenWayIntervalsDao intervalsDao,
  required WayCandidateSource waySource,
}) async {
  final item = await inboxDao.getTripWithIntervalCount(tripId);
  if (item == null) {
    throw DatabaseError('Trip $tripId not found');
  }

  final points = await tripsDao.listPointsForTrip(tripId);
  final rawPolyline = [
    for (final p in points) LatLng(p.lat, p.lon),
  ];
  final bounds = tripBounds(item) ?? _boundsFromPolyline(rawPolyline);

  // Fail-matched: the matcher ran but produced no intervals. No overlay, no
  // network call — the warning banner covers it.
  if (item.intervalCount == 0) {
    return TripDetailData(
      item: item,
      rawPolyline: rawPolyline,
      matchedSegments: const [],
      bounds: bounds,
      matchedWayCount: 0,
      matchedFraction: null,
      offline: false,
    );
  }

  final intervals = await intervalsDao.getByTrip(tripId);

  // Resolve way geometry (cache-first via the source). A network error with a
  // cache miss surfaces as a thrown DomainError → offline.
  var offline = false;
  var ways = <WayCandidate>[];
  if (bounds == null) {
    offline = true;
  } else {
    try {
      ways = await waySource.fetchWaysInBbox(
        minLat: bounds.southwest.latitude,
        minLon: bounds.southwest.longitude,
        maxLat: bounds.northeast.latitude,
        maxLon: bounds.northeast.longitude,
      );
    } on DomainError {
      offline = true;
    }
  }

  // Cache-expired scenario: no ways came back but the trip DID match — treat
  // as offline (matched overlay unavailable) rather than as fail-matched.
  if (ways.isEmpty && intervals.isNotEmpty) {
    offline = true;
  }

  if (offline) {
    return TripDetailData(
      item: item,
      rawPolyline: rawPolyline,
      matchedSegments: const [],
      bounds: bounds,
      matchedWayCount: intervals.map((i) => i.wayId).toSet().length,
      matchedFraction: null,
      offline: true,
    );
  }

  final wayById = {for (final w in ways) w.wayId: w};
  final segments = <List<LatLng>>[];
  final matchedWayIds = <int>{};
  var drivenLength = 0.0;
  for (final interval in intervals) {
    final way = wayById[interval.wayId];
    if (way == null) continue;
    matchedWayIds.add(interval.wayId);
    drivenLength += (interval.endMeters - interval.startMeters).abs();
    final seg = reconstructWaySubsegment(
      way.geometry,
      interval.startMeters,
      interval.endMeters,
    );
    if (seg.length >= 2) segments.add(seg);
  }

  var totalLength = 0.0;
  for (final id in matchedWayIds) {
    totalLength += _polylineLengthMeters(wayById[id]!.geometry);
  }
  final fraction =
      totalLength > 0 ? (drivenLength / totalLength).clamp(0.0, 1.0) : null;

  return TripDetailData(
    item: item,
    rawPolyline: rawPolyline,
    matchedSegments: segments,
    bounds: bounds,
    matchedWayCount: matchedWayIds.length,
    matchedFraction: fraction,
    offline: false,
  );
}

/// Extract the sub-polyline of [geometry] between [startMeters] and
/// [endMeters] (distances measured along the way from its first node). Handles
/// reversed intervals (start > end) by normalizing the range.
List<LatLng> reconstructWaySubsegment(
  List<LatLng> geometry,
  double startMeters,
  double endMeters,
) {
  if (geometry.length < 2) return const [];
  final lo = math.min(startMeters, endMeters);
  final hi = math.max(startMeters, endMeters);
  final result = <LatLng>[];
  var cumulative = 0.0;
  for (var i = 0; i < geometry.length - 1; i++) {
    final a = geometry[i];
    final b = geometry[i + 1];
    final segLen = haversineMeters(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    final segStart = cumulative;
    final segEnd = cumulative + segLen;
    if (segLen > 0 && segEnd >= lo && segStart <= hi) {
      final tStart = ((lo - segStart) / segLen).clamp(0.0, 1.0);
      final tEnd = ((hi - segStart) / segLen).clamp(0.0, 1.0);
      final pStart = _lerpLatLng(a, b, tStart);
      final pEnd = _lerpLatLng(a, b, tEnd);
      if (result.isEmpty) {
        result.add(pStart);
      }
      result.add(pEnd);
    }
    cumulative = segEnd;
  }
  return result;
}

LatLng _lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );

double _polylineLengthMeters(List<LatLng> geometry) {
  var total = 0.0;
  for (var i = 0; i < geometry.length - 1; i++) {
    total += haversineMeters(
      geometry[i].latitude,
      geometry[i].longitude,
      geometry[i + 1].latitude,
      geometry[i + 1].longitude,
    );
  }
  return total;
}

LatLngBounds? _boundsFromPolyline(List<LatLng> polyline) {
  if (polyline.length < 2) return null;
  var minLat = polyline.first.latitude;
  var maxLat = polyline.first.latitude;
  var minLon = polyline.first.longitude;
  var maxLon = polyline.first.longitude;
  for (final p in polyline) {
    minLat = math.min(minLat, p.latitude);
    maxLat = math.max(maxLat, p.latitude);
    minLon = math.min(minLon, p.longitude);
    maxLon = math.max(maxLon, p.longitude);
  }
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

/// Full-screen trip-detail view at `/trips/:id`.
class TripDetailScreen extends ConsumerStatefulWidget {
  const TripDetailScreen({required this.tripId, super.key});

  final int tripId;

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends ConsumerState<TripDetailScreen> {
  Future<void> _onDelete() async {
    final confirmed = await DiscardConfirmationDialog.show(context);
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final result =
        await ref.read(tripsInboxRepositoryProvider).discardTrip(widget.tripId);
    if (!mounted) return;
    result.when(
      ok: (_) => router.pop(),
      err: (e) => messenger.showSnackBar(SnackBar(content: Text(e.message))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tripDetailDataProvider(widget.tripId));
    return Scaffold(
      appBar: AppBar(
        title: Text('Fahrt Nr. ${widget.tripId}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Fahrt löschen',
            onPressed: _onDelete,
          ),
        ],
      ),
      body: async.when(
        data: _buildBody,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBody(message: '$e'),
      ),
      // Debug-only golden-fixture export. Absent in release/profile builds
      // (kDebugMode short-circuits inside the widget).
      floatingActionButton: DebugExportButton(tripId: widget.tripId),
    );
  }

  Widget _buildBody(TripDetailData data) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (data.item.isFailMatched) const _FailMatchedBanner(),
        if (data.offline) const _OfflineBanner(),
        Expanded(
          // Static route render — NO MapLibre surface. Mounting a second live
          // map here OOM-crashed the app on navigation (Plan 06-07 re-drive
          // #4); TripRouteView paints the same geometry with a CustomPainter.
          child: TripRouteView(
            data: data,
            rawColor: scheme.outline,
            matchedColor: scheme.primary,
          ),
        ),
        _StatStrip(data: data),
      ],
    );
  }
}

/// Warning banner for a fail-matched trip (intervalCount == 0).
class _FailMatchedBanner extends StatelessWidget {
  const _FailMatchedBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Banner(
      icon: Icons.warning_amber_rounded,
      background: scheme.errorContainer,
      foreground: scheme.onErrorContainer,
      message: 'Keine Straßen abgeglichen. GPS war möglicherweise in Innenräumen '
          'oder auf einem Parkplatz.',
    );
  }
}

/// Info banner for the offline / cache-miss case (Issue 6).
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Banner(
      icon: Icons.cloud_off_outlined,
      background: scheme.surfaceContainerHighest,
      foreground: scheme.onSurfaceVariant,
      message: 'Abgeglichene Straßen offline nicht verfügbar. Zeige Roh-GPS-Spur.',
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.message,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact stat strip below the map: duration · distance · matched summary.
class _StatStrip extends StatelessWidget {
  const _StatStrip({required this.data});

  final TripDetailData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = data.item;

    final String matchedLabel;
    if (data.offline) {
      matchedLabel = '— (offline)';
    } else if (data.matchedFraction != null) {
      final pct = (data.matchedFraction! * 100).round();
      matchedLabel = '${data.matchedWayCount} Straßen ($pct %)';
    } else {
      matchedLabel = '${data.matchedWayCount} Straßen';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Text(
        'Dauer: ${formatDuration(item.duration)} · '
        'Distanz: ${formatDistance(item.distanceMeters)} · '
        'Abgeglichen: $matchedLabel',
        style: theme.textTheme.bodyMedium,
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// DomainError-aware error body (e.g. trip not found — route stability).
class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Diese Fahrt konnte nicht geladen werden.\n$message',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
