import 'package:drift/drift.dart';

class CoverageCache extends Table {
  TextColumn get regionId => text()(); // OSM relation ID as string
  RealColumn get drivenLengthM =>
      real().withDefault(const Constant<double>(0))();
  RealColumn get totalLengthM =>
      real().withDefault(const Constant<double>(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get extractVersion => text().nullable()();
  IntColumn get invalidationGen => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {regionId};
}
