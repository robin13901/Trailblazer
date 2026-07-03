import 'package:auto_explore/core/db/tables/trips_table.dart';
import 'package:drift/drift.dart';

class TripPoints extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tripId =>
      integer().references(Trips, #id, onDelete: KeyAction.cascade)();
  IntColumn get seq => integer()();
  DateTimeColumn get ts => dateTime()();
  RealColumn get lat => real()();
  RealColumn get lon => real()();
  RealColumn get speedKmh => real().nullable()();
  RealColumn get accuracyMeters => real().nullable()();
  RealColumn get altitudeMeters => real().nullable()();
  TextColumn get motionType => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {tripId, seq},
  ];
}
