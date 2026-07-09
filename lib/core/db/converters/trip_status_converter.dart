import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart';

/// Persists [TripStatus] as its enum name string in SQLite.
///
/// Values stored: 'recording' | 'pendingRoadData' | 'pending' | 'matched'
/// | 'confirmed' | 'rejected'.
/// The underlying column type stays TEXT — no schema change when adding enum
/// variants, but existing values must stay stable once written.
class TripStatusConverter extends TypeConverter<TripStatus, String> {
  const TripStatusConverter();

  @override
  TripStatus fromSql(String fromDb) =>
      TripStatus.values.firstWhere((v) => v.name == fromDb);

  @override
  String toSql(TripStatus value) => value.name;
}
