// Trailblazer trip-path data provider (extracted 2026-07-22 from the retired
// TripDetailScreen when the full-screen CustomPainter view was replaced by a
// bottom sheet + on-map turquoise overlay).
//
// Loads the geometry a single trip needs to render on the shared Map tab:
//   * matchedSegments — the on-road line, reconstructed from
//     `driven_way_intervals` (way id + start/end meters) clipped onto OSM way
//     geometry fetched via the cache-first WayCandidateSource. This is the
//     line the TripPathBridge paints; it does NOT depend on `trip_points`, so
//     it survives raw-GPS retention deletion.
//   * rawPolyline — the raw GPS trail from `trip_points`. Retained in the
//     payload for completeness (tests, future use) but the on-map overlay
//     deliberately draws only matchedSegments so it stays delete-safe.
//   * bounds — from the trip's persisted bbox columns (delete-safe), falling
//     back to the raw polyline.
//
// Offline fallback: when the way source throws (network error + cache miss) OR
// returns no ways while intervals exist (cache-expired), matchedSegments is
// left empty and `offline` is set.

import 'dart:math' as math;

import 'package:auto_explore/core/db/app_database_providers.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_dao_inbox_queries.dart';
import 'package:auto_explore/features/trips/data/trips_repository_providers.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:auto_explore/features/trips/presentation/widgets/trip_card.dart'
    show tripBounds;
import 'package:auto_explore/features/trips/presentation/widgets/trip_overlay_layers.dart'
    show TripDetailData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Loads the full [TripDetailData] for a trip id: the read-model item, the raw
/// GPS polyline from `trip_points`, and — when the trip matched — the matched
/// interval segments reconstructed from Overpass way geometry.
///
/// The `FutureProviderFamily` concrete type is internal to Riverpod, so the
/// type is left inferred.
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
/// be unit-tested with fake DAOs + a fake [WayCandidateSource].
///
/// Offline fallback: when the way source throws (network error + cache miss)
/// OR returns no ways while intervals exist (cache-expired), the matched
/// overlay is skipped, `offline` is set, and only the raw polyline remains.
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
  // network call.
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
      snapMeters: kWaySubsegmentSnapMeters,
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
