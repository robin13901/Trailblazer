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
}
