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

  /// GPS course-over-ground in degrees (0=N, 90=E), from
  /// flutter_background_geolocation's `coords.heading` (mirrored onto
  /// `TrackingRecording.headingDegrees` live). Nullable: absent on historical
  /// rows written before schema v8, and null when the device reports no
  /// heading (stationary / no fix). The matcher prefers this stored value when
  /// present and the vehicle is moving, else derives a bearing from
  /// consecutive fixes (see `ViterbiDecoder._travelBearing`).
  RealColumn get heading => real().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {tripId, seq},
  ];
}
