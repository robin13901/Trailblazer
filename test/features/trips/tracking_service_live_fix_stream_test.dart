// Hide the Drift-generated TripPoint row class to avoid ambiguous_import.
import 'package:auto_explore/core/db/app_database.dart' hide TripPoint;
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/data/trips_repository.dart';
import 'package:auto_explore/features/trips/data/trips_repository_points_sink.dart';
import 'package:auto_explore/features/trips/domain/live_fix_sample.dart';
import 'package:auto_explore/features/trips/domain/tracking_service.dart';
import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_background_geolocation_facade.dart';

/// Tests for the live-nav per-fix broadcast ([TrackingService.liveFixStream]).
///
/// The dashed trail layer and the road-snap heading service both consume this
/// stream, so the invariant is: exactly one [LiveFixSample] per ACCEPTED fix,
/// carrying the fix coordinate and the service's computed heading. Rejected
/// fixes must not emit.
void main() {
  late AppDatabase db;
  late TripsRepository repo;
  late TripsRepositoryPointsSink sink;
  late FakeBackgroundGeolocationFacade facade;

  TrackingService makeService() {
    return TrackingService(
      facade: facade,
      repository: repo,
      pointsSink: sink,
    );
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TripsRepository(TripsDao(db));
    sink = TripsRepositoryPointsSink(repo);
    facade = FakeBackgroundGeolocationFacade();
  });

  tearDown(() async {
    facade.dispose();
    await db.close();
  });

  group('TrackingService — liveFixStream', () {
    test('emits one LiveFixSample per accepted fix with matching coordinates',
        () async {
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      final samples = <LiveFixSample>[];
      final sub = svc.liveFixStream.listen(samples.add);

      // 3 in-vehicle fixes moving north — all accepted (accuracy 5 m << 25 m,
      // 1 s apart, ~55 m/step).
      final baseTs = DateTime.now();
      for (var i = 0; i < 3; i++) {
        facade.emitFix(FixInput(
          ts: baseTs.add(Duration(seconds: i + 1)),
          lat: 52.5200 + i * 0.0005,
          lon: 13.4050,
          accuracyMeters: 5,
          speedMps: 8.33,
          activityType: 'in_vehicle',
          uuid: 'uuid-livefix-$i',
        ));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(svc.diagnostics.acceptCount, 3);
      expect(samples, hasLength(3));
      // Coordinates round-trip verbatim from the accepted fixes.
      expect(samples[0].lat, closeTo(52.5200, 1e-9));
      expect(samples[2].lat, closeTo(52.5200 + 2 * 0.0005, 1e-9));
      expect(samples.every((s) => s.lon == 13.4050), isTrue);

      await svc.dispose();
    });

    test('carries a northbound heading (~0°) after movement', () async {
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      final samples = <LiveFixSample>[];
      final sub = svc.liveFixStream.listen(samples.add);

      // Fixes with no OS course over ground → heading is the motion-vector
      // bearing between consecutive fixes. Moving due north → ~0°/360°.
      final baseTs = DateTime.now();
      for (var i = 0; i < 3; i++) {
        facade.emitFix(FixInput(
          ts: baseTs.add(Duration(seconds: i + 1)),
          lat: 52.5200 + i * 0.0005,
          lon: 13.4050,
          accuracyMeters: 5,
          speedMps: 8.33,
          activityType: 'in_vehicle',
          uuid: 'uuid-livefix-hdg-$i',
        ));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // The last sample's heading should be near due north (0 or 360).
      final heading = samples.last.headingDegrees;
      expect(heading, isNotNull);
      final norm = heading! % 360.0;
      final closeToNorth = norm < 5.0 || norm > 355.0;
      expect(closeToNorth, isTrue,
          reason: 'northbound motion vector should read ~0°, got $norm');

      await svc.dispose();
    });

    test('a rejected fix does not emit on liveFixStream', () async {
      final svc = makeService();
      await svc.init();
      await svc.startManual();

      final samples = <LiveFixSample>[];
      final sub = svc.liveFixStream.listen(samples.add);

      final baseTs = DateTime.now();
      // Accept, reject (accuracy 500 > 25 m), accept.
      facade.emitFix(FixInput(
        ts: baseTs,
        lat: 52.5200,
        lon: 13.4050,
        accuracyMeters: 5,
        speedMps: 8.33,
        activityType: 'in_vehicle',
        uuid: 'uuid-livefix-rej-a',
      ));
      await Future<void>.delayed(Duration.zero);
      facade.emitFix(FixInput(
        ts: baseTs.add(const Duration(seconds: 1)),
        lat: 52.5205,
        lon: 13.4050,
        accuracyMeters: 500,
        speedMps: 8.33,
        activityType: 'in_vehicle',
        uuid: 'uuid-livefix-rej-b',
      ));
      await Future<void>.delayed(Duration.zero);
      facade.emitFix(FixInput(
        ts: baseTs.add(const Duration(seconds: 2)),
        lat: 52.5210,
        lon: 13.4050,
        accuracyMeters: 5,
        speedMps: 8.33,
        activityType: 'in_vehicle',
        uuid: 'uuid-livefix-rej-c',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(svc.diagnostics.acceptCount, 2);
      expect(svc.diagnostics.rejectCount, 1);
      // 2 accepted → exactly 2 live samples (the reject produced none).
      expect(samples, hasLength(2));

      await svc.dispose();
    });
  });
}
