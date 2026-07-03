import 'package:drift/drift.dart';

class Trips extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  RealColumn get distanceMeters => real().nullable()();
  RealColumn get avgSpeedKmh => real().nullable()();
  RealColumn get maxSpeedKmh => real().nullable()();
  // status: 'pending' | 'confirmed' | 'rejected'
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get vehicleId => integer().nullable()();
  BoolColumn get manuallyStarted =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get autoStopped => boolean().withDefault(const Constant(false))();
  TextColumn get bluetoothHint => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
