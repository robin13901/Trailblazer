import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FixInput', () {
    test('headingDegrees round-trips through the constructor', () {
      final fix = FixInput(
        ts: DateTime(2026, 7, 9, 12),
        lat: 49,
        lon: 8,
        accuracyMeters: 5,
        speedMps: 10,
        headingDegrees: 137.5,
      );

      expect(fix.headingDegrees, 137.5);
    });

    test('headingDegrees defaults to null when omitted', () {
      final fix = FixInput(
        ts: DateTime(2026, 7, 9, 12),
        lat: 49,
        lon: 8,
        accuracyMeters: 5,
      );

      expect(fix.headingDegrees, isNull);
    });

    test('all optional fields coexist without clobbering each other', () {
      final fix = FixInput(
        ts: DateTime(2026, 7, 9, 12),
        lat: 49,
        lon: 8,
        accuracyMeters: 5,
        speedMps: 12.5,
        headingDegrees: 270,
        altitudeMeters: 300,
        activityType: 'in_vehicle',
        uuid: 'abc-123',
      );

      expect(fix.speedMps, 12.5);
      expect(fix.headingDegrees, 270);
      expect(fix.altitudeMeters, 300);
      expect(fix.activityType, 'in_vehicle');
      expect(fix.uuid, 'abc-123');
    });
  });
}
