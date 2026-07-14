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

  // v5 (2026-07-13): the REAL total road length of the whole region polygon,
  // computed once via tiled area-clipped Overpass `sum(length())` queries and
  // cached forever. `null` = not yet computed (the region browser shows a
  // spinner and falls back to `totalLengthM`). This fixes the bug where a
  // region's total only counted roads near the user's trips (e.g. Bayern
  // showing ~30 km). See RegionTotalLengthService.
  RealColumn get realTotalLengthM => real().nullable()();

  // When the real total was last computed (null until first computed).
  DateTimeColumn get realTotalUpdatedAt => dateTime().nullable()();

  // v6 (2026-07-14): resumable-compute accumulator for the tiled real-total
  // pass. JSON shape: {"v":1,"tiles":<cellDegrees>,"cells":{"<lat>,<lon>":m,…}}
  // where each key is a completed bbox cell and its value the summed road
  // meters. Non-null while a region's total is mid-compute; cleared back to
  // null once `real_total_length_m` is written. Lets RegionTotalLengthService
  // resume across app launches / kills instead of restarting a ~1600-cell
  // Bundesland pass from scratch. See RegionTotalLengthService.
  TextColumn get realTotalProgressJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {regionId};
}
