import 'package:auto_explore/core/db/converters/trip_status_converter.dart';
import 'package:drift/drift.dart';

class Trips extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  RealColumn get distanceMeters => real().nullable()();
  RealColumn get avgSpeedKmh => real().nullable()();
  RealColumn get maxSpeedKmh => real().nullable()();
  // status: persisted as TEXT via TripStatusConverter.
  // Default 'pending' kept for back-compat with any v1 rows not yet migrated.
  TextColumn get status => text()
      .withDefault(const Constant('pending'))
      .map(const TripStatusConverter())();
  BoolColumn get manuallyStarted =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get autoStopped => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  // v2 summary columns — added via addColumn migration (from < 2).
  // Nullable so existing v1 rows are untouched on upgrade.
  RealColumn get bboxMinLat => real().nullable()();
  RealColumn get bboxMinLon => real().nullable()();
  RealColumn get bboxMaxLat => real().nullable()();
  RealColumn get bboxMaxLon => real().nullable()();
  IntColumn get pointCount => integer().nullable()();

  // v5 (2026-07-13): the persistent coverage line for this trip.
  //
  // A JSON array of on-road polyline segments — the raw GPS trail trimmed to
  // the fixes the matcher accepted as on-road (off-road fixes such as parking
  // lots are dropped). Shape: `[[[lat,lon],[lat,lon],…], …]`. Rendered solid
  // in the coverage color; this is the visible "roads I've driven" geometry.
  //
  // Stored on the trip row (never swept) so it survives raw-GPS retention
  // deletion of `trip_points`. Road-matched `driven_way_intervals` remain the
  // source for region-km math; this column is the visual layer only.
  TextColumn get coveragePathJson => text().nullable()();

  // v7 (2026-07-22): denormalized trip endpoints (first/last `trip_points`
  // fix by seq). Persisted on the trip row so the start/end reverse-geocoded
  // place names survive raw-GPS retention deletion of `trip_points` (the
  // inbox/history read-model previously derived these via a live subquery over
  // `trip_points`, which broke once the raw fixes were purged). Nullable so
  // existing rows are untouched on upgrade; backfilled from `trip_points` in
  // the v6→v7 migration.
  RealColumn get startLat => real().nullable()();
  RealColumn get startLon => real().nullable()();
  RealColumn get endLat => real().nullable()();
  RealColumn get endLon => real().nullable()();
}
