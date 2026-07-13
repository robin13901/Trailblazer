import 'dart:async';

import 'package:auto_explore/features/map/domain/road_snap_heading.dart';
import 'package:auto_explore/features/matching/data/matching_providers.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/matching/domain/way_segment.dart';
import 'package:auto_explore/features/matching/domain/way_segment_index.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_state.dart';
import 'package:auto_explore/features/trips/presentation/providers/tracking_state_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stabilizes the live driving direction by snapping it to the tangent of the
/// OSM road the driver is currently on, reusing the matcher's spatial index +
/// cache-first way source. Fully on-device; the only network dependency is the
/// first encounter with an uncached tile (which fails soft and warms the cache
/// for next time).
///
/// The camera reads [targetBearing] synchronously each animation frame — the
/// service holds mutable internal state and never notifies, so polling it does
/// not trigger widget rebuilds.
class RoadSnapHeadingService {
  RoadSnapHeadingService({required WayCandidateSource source})
      : _source = source;

  final WayCandidateSource _source;

  /// Half-side of the way-load box around the driver (meters). A 6 km box
  /// keeps enough road geometry in memory to cover several minutes of driving
  /// before a reload is needed.
  static const double _boxHalfMeters = 3000;

  /// Reload the index once the driver moves more than this far from the center
  /// the box was last loaded at — leaves a ~1 km margin inside [_boxHalfMeters]
  /// so we refetch before running out of geometry.
  static const double _reloadRadiusMeters = 2000;

  /// Search radius for the nearest-road query. Covers GPS noise + wide roads;
  /// beyond this we treat the driver as off-road and fall back to raw heading.
  static const double _snapRadiusMeters = 50;

  WaySegmentIndex? _index;
  double? _loadCenterLat;
  double? _loadCenterLon;
  bool _loading = false;

  /// The way id we snapped to on the previous fix — biases candidate selection
  /// so we don't flicker between crossing/adjacent roads at intersections.
  int? _lastWayId;

  double? _targetBearing;

  /// Latest stabilized camera bearing (0..360), or null before the first fix.
  /// Falls back to the raw GPS heading when no road snap is available.
  double? get targetBearing => _targetBearing;

  /// Feed one accepted fix. Updates [targetBearing] synchronously from the
  /// currently-loaded index (falling back to the raw heading), and kicks off an
  /// async index (re)load when the driver has left the loaded area.
  void onFix(LiveFixSample fix) {
    // Fire-and-forget: (re)build the index if we've moved out of the box. The
    // current fix still uses whatever index we have (possibly none yet).
    unawaited(_ensureIndex(fix.lat, fix.lon));

    final raw = fix.headingDegrees;
    final index = _index;
    if (index == null) {
      _targetBearing = raw;
      return;
    }

    final candidates = index.queryTopK(
      lat: fix.lat,
      lon: fix.lon,
      radiusMeters: _snapRadiusMeters,
      k: 4,
    );
    if (candidates.isEmpty) {
      _targetBearing = raw;
      return;
    }

    final seg = _pickSegment(candidates);
    _lastWayId = seg.wayId;
    final roadBearing = segmentTravelBearing(seg, raw);
    _targetBearing = blendHeading(roadBearing, raw);
  }

  /// Clear per-trip state (called on stop). Keeps the loaded index — the next
  /// trip likely starts in the same area, so we avoid a needless refetch.
  void reset() {
    _targetBearing = null;
    _lastWayId = null;
  }

  /// Prefer the segment on the same way we snapped to last fix (continuity);
  /// otherwise take the nearest (candidates are distance-ranked).
  WaySegment _pickSegment(List<WaySegment> candidates) {
    final last = _lastWayId;
    if (last != null) {
      for (final c in candidates) {
        if (c.wayId == last) return c;
      }
    }
    return candidates.first;
  }

  bool _needsReload(double lat, double lon) {
    if (_index == null) return true;
    final cLat = _loadCenterLat;
    final cLon = _loadCenterLon;
    if (cLat == null || cLon == null) return true;
    return haversineMeters(cLat, cLon, lat, lon) > _reloadRadiusMeters;
  }

  Future<void> _ensureIndex(double lat, double lon) async {
    if (_loading || !_needsReload(lat, lon)) return;
    _loading = true;
    try {
      const halfLat = _boxHalfMeters / metersPerDegreeLat;
      final halfLon = _boxHalfMeters / metersPerDegreeLon(lat);
      final ways = await _source.fetchWaysInBbox(
        minLat: lat - halfLat,
        minLon: lon - halfLon,
        maxLat: lat + halfLat,
        maxLon: lon + halfLon,
        // Cache-first, offline-safe: return whatever tiles are cached and
        // swallow network errors (same pattern as the coverage resolver).
        throwOnError: false,
      );
      _index = WaySegmentIndex.buildFromWays(ways);
      _loadCenterLat = lat;
      _loadCenterLon = lon;
    } on Object {
      // Keep the previous index (or null) on any failure; heading falls back
      // to raw GPS until a subsequent load succeeds.
    } finally {
      _loading = false;
    }
  }
}

/// Provider for the [RoadSnapHeadingService]. Wires the live-fix stream into
/// [RoadSnapHeadingService.onFix] and resets on trip stop. Kept alive by the
/// camera-sync widget while the map is mounted.
///
/// Plain Provider + ref.listen — no @Riverpod codegen (STATE.md 01-01).
final roadSnapHeadingServiceProvider = Provider<RoadSnapHeadingService>((ref) {
  final service = RoadSnapHeadingService(
    source: ref.watch(wayCandidateSourceProvider),
  );

  ref
    ..listen<AsyncValue<LiveFixSample>>(liveFixProvider, (_, next) {
      if (next case AsyncData(:final value)) {
        service.onFix(value);
      }
    })
    ..listen<TrackingState>(trackingStateProvider, (_, next) {
      if (next is TrackingIdle) {
        service.reset();
      }
    });

  return service;
});
