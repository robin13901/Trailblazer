// Trailblazer Phase 7, Plan 07-03:
// DrivenWayGeometryResolver — closes RESEARCH open-question #1.
//
// The driven_way_intervals table stores no geometry and no tile mapping.
// This resolver bridges that gap:
//   1. Reads all driven intervals from the DAO (way-centric, trip-agnostic).
//   2. Resolves OSM way geometry for the union bbox via the cache-first
//      WayCandidateSource (OverpassWayCandidateSource at runtime).
//   3. Computes per-way CoverageDatum via drivenLengthMeters + classifyCoverage.
//   4. Returns CoverageOverlayData (list of CoverageWay) — zero throws.
//
// Error posture (06-05 lesson — rendering must never crash the map):
//   * fetchWaysInBbox(throwOnError:false) returns cached tiles on network error.
//   * Missing geometry for a wayId → skip + log.fine (normal offline gap).
//   * Any unexpected error → return CoverageOverlayData.empty + log.warning.

import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/coverage/data/coverage_overlay_data.dart';
import 'package:auto_explore/features/coverage/domain/coverage_threshold.dart';
import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;

/// Resolves driven way geometries from the Overpass cache and classifies
/// per-way coverage from the driven_way_intervals DAO.
///
/// Injected with a [DrivenWayIntervalsDao] and a [WayCandidateSource].
/// At runtime the source is the cache-first `OverpassWayCandidateSource`;
/// tests inject a fake `WayCandidateSource` implementation.
///
/// This class is STATELESS — `resolve` reads fresh from the DAO and source
/// on every call. The reactive invalidation is handled by
/// `coverageOverlayDataProvider` in coverage_overlay_providers.dart, which
/// re-calls resolve() whenever the Drift watchUnionBbox() stream emits.
class DrivenWayGeometryResolver {
  DrivenWayGeometryResolver({
    required DrivenWayIntervalsDao intervalsDao,
    required WayCandidateSource waySource,
  })  : _intervalsDao = intervalsDao,
        _waySource = waySource;

  final DrivenWayIntervalsDao _intervalsDao;
  final WayCandidateSource _waySource;

  static final _log = Logger('DrivenWayGeometryResolver');

  /// Resolves all driven ways within [unionBounds] and returns their
  /// geometry + coverage classification.
  ///
  /// The [unionBounds] is the bounding box that spans all matched/confirmed
  /// trips — computed by `TripsDao.watchUnionBbox` and passed in from the
  /// reactive provider. The resolver does not query trips itself; it is
  /// focused solely on geometry + coverage arithmetic.
  ///
  /// **Algorithm:**
  ///   1. Read all driven intervals (`getAllIntervals`) — way-centric.
  ///      If empty → return [CoverageOverlayData.empty].
  ///   2. Fetch all ways in the union bbox (`fetchWaysInBbox(throwOnError:false)`)
  ///      so an offline gap yields whatever tiles are cached.
  ///   3. For each driven wayId:
  ///      - Skip if geometry unavailable (logged at fine level).
  ///      - Compute union length via `drivenLengthMeters`.
  ///      - Compute Haversine way length via `_polylineLengthMeters`.
  ///      - Classify via `classifyCoverage`.
  ///      - Skip if datum is undriven (fraction == 0 && !isFull) — below floor.
  ///   4. Return [CoverageOverlayData] wrapping the resolved list.
  ///
  /// Never throws — degrades to [CoverageOverlayData.empty] on unexpected error.
  Future<CoverageOverlayData> resolve(LatLngBounds unionBounds) async {
    try {
      // Step 1: Read all driven intervals.
      final allIntervals = await _intervalsDao.getAllIntervals();
      if (allIntervals.isEmpty) {
        _log.fine('resolve: no driven intervals — returning empty');
        return CoverageOverlayData.empty;
      }

      // Group intervals by wayId in Dart (avoids fragile SQL GROUP_CONCAT).
      final byWayId = <int, List<Interval>>{};
      for (final row in allIntervals) {
        byWayId
            .putIfAbsent(row.wayId, () => [])
            .add(Interval(row.startMeters, row.endMeters));
      }

      // Step 2: Cache-first geometry resolution for the union bbox.
      // throwOnError:false means a network failure returns whatever is cached.
      final ways = await _waySource.fetchWaysInBbox(
        minLat: unionBounds.southwest.latitude,
        minLon: unionBounds.southwest.longitude,
        maxLat: unionBounds.northeast.latitude,
        maxLon: unionBounds.northeast.longitude,
        throwOnError: false,
      );
      final byId = <int, WayCandidate>{
        for (final w in ways) w.wayId: w,
      };

      // Step 3: Classify coverage for each driven wayId.
      final result = <CoverageWay>[];
      var skippedMissing = 0;
      var skippedBelowFloor = 0;

      for (final entry in byWayId.entries) {
        final wayId = entry.key;
        final intervals = entry.value;

        final way = byId[wayId];
        if (way == null) {
          _log.fine('resolve: geometry miss for wayId $wayId — skipping');
          skippedMissing++;
          continue;
        }

        final unionLen = drivenLengthMeters(intervals);
        final wayLen = _polylineLengthMeters(way.geometry);
        final datum = classifyCoverage(unionLen, wayLen);

        // CoverageDatum.undriven() has fraction==0 and isFull==false.
        if (datum.fraction <= 0 && !datum.isFull) {
          skippedBelowFloor++;
          continue;
        }

        result.add(CoverageWay(wayId: wayId, geometry: way.geometry, datum: datum));
      }

      _log.info(
        'resolve: ${result.length} ways resolved, '
        '$skippedMissing geometry-miss, $skippedBelowFloor below-floor',
      );
      return CoverageOverlayData(result);
    } on DomainError catch (e, st) {
      _log.warning('resolve: DomainError — degrading to empty', e, st);
      return CoverageOverlayData.empty;
    } on Object catch (e, st) {
      _log.warning(
        'resolve: unexpected error — degrading to empty',
        DomainError.wrap(e, st),
        st,
      );
      return CoverageOverlayData.empty;
    }
  }
}

/// Haversine sum of consecutive point distances along [geometry].
///
/// Extracted from TripDetailScreen._polylineLengthMeters and duplicated here
/// to avoid importing a presentation-layer private function. The logic is
/// identical; only the scope differs.
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
