import 'package:auto_explore/core/db/tables/trips_table.dart';
import 'package:drift/drift.dart';

class DrivenWayIntervals extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get wayId => integer()(); // OSM way ID
  IntColumn get tripId => integer()
      .references(Trips, #id, onDelete: KeyAction.setNull)
      .nullable()();
  RealColumn get startMeters => real()();
  RealColumn get endMeters => real()();
  // direction: 'forward' | 'backward' | 'both'
  TextColumn get direction => text().withDefault(const Constant('forward'))();
  DateTimeColumn get matchedAt => dateTime().withDefault(currentDateAndTime)();
}
