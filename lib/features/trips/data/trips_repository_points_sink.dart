// Hide the Drift-generated TripPoint row class to avoid ambiguous_import with
// the domain TripPoint DTO. Only TripPointsCompanion is needed from this lib.
import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_batcher.dart'
    show TripPointsSink;
import 'package:auto_explore/features/trips/domain/trip_point.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';

/// Adapts [TripsRepository] to the domain-layer [TripPointsSink] contract
/// from Plan 03-02. Converts domain TripPoint DTOs → [TripPointsCompanion]
/// and folds Result.Err into a logged warning so the batcher's [Future<void>]
/// contract holds — errors are swallowed and logged, never rethrown, per
/// STATE.md 01-04 (swallow-and-log at persistence boundaries).
class TripsRepositoryPointsSink implements TripPointsSink {
  TripsRepositoryPointsSink(this._repo, {Logger? logger})
      : _log = logger ?? Logger('tracking.points_sink');

  final TripsRepository _repo;
  final Logger _log;

  @override
  Future<void> appendPoints(int tripId, List<TripPoint> points) async {
    if (points.isEmpty) return;
    final companions = points.map(_toCompanion).toList(growable: false);
    final result = await _repo.appendPoints(tripId, companions);
    result.when(
      ok: (_) {},
      err: (e) => _log.warning(
        'appendPoints failed for tripId=$tripId '
        '(${points.length} points dropped): ${e.message}',
      ),
    );
  }

  TripPointsCompanion _toCompanion(TripPoint p) => TripPointsCompanion(
        tripId: Value(p.tripId),
        seq: Value(p.seq),
        ts: Value(p.ts),
        lat: Value(p.lat),
        lon: Value(p.lon),
        speedKmh: Value(p.speedKmh),
        accuracyMeters: Value(p.accuracyMeters),
        altitudeMeters: Value(p.altitudeMeters),
        motionType: Value(p.motionType),
      );
}
