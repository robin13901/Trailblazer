import 'package:auto_explore/core/db/tables/vehicles_table.dart';
import 'package:drift/drift.dart';

class BtFingerprints extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get vehicleId =>
      integer().references(Vehicles, #id, onDelete: KeyAction.cascade)();
  TextColumn get macAddress => text()();
  TextColumn get deviceName => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
