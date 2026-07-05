import 'package:auto_explore/features/trips/domain/trip_fix_input.dart';

/// Golden [FixInput] fixture lists for ingestor unit tests.
///
/// All timestamps are anchored to a fixed base to make tests deterministic.
final _base = DateTime.utc(2026, 7, 5, 8);

DateTime _t(int offsetSeconds) =>
    _base.add(Duration(seconds: offsetSeconds));

/// 10 fixes 1 s apart at ~40 km/h (~11.1 m/s), accuracy 8 m.
/// Path: pure-northward steps along a Frankfurt road, each fix ~11.1 m apart.
/// Expected: 10 FixAccepted, finalize.avgSpeedKmh ≈ 40, passes keeper.
/// Note: lat step 0.0001° ≈ 11.1 m at lat 50 °N → distance-based avgSpeed ≈ 40 km/h.
final goldenSuburbanDrive10Fixes = List<FixInput>.unmodifiable([
  FixInput(
    ts: _t(0),
    lat: 50.1109,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-01',
  ),
  FixInput(
    ts: _t(1),
    lat: 50.111,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-02',
  ),
  FixInput(
    ts: _t(2),
    lat: 50.1111,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-03',
  ),
  FixInput(
    ts: _t(3),
    lat: 50.1112,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-04',
  ),
  FixInput(
    ts: _t(4),
    lat: 50.1113,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-05',
  ),
  FixInput(
    ts: _t(5),
    lat: 50.1114,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-06',
  ),
  FixInput(
    ts: _t(6),
    lat: 50.1115,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-07',
  ),
  FixInput(
    ts: _t(7),
    lat: 50.1116,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-08',
  ),
  FixInput(
    ts: _t(8),
    lat: 50.1117,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-09',
  ),
  FixInput(
    ts: _t(9),
    lat: 50.1118,
    lon: 8.6821,
    accuracyMeters: 8,
    speedMps: 11.1,
    activityType: 'in_vehicle',
    uuid: 'uuid-sub-10',
  ),
]);

/// 5 fixes → 2-min gap (120 s) → 5 fixes ~200 m further along same road.
/// Gap > 0 but < 5 min (300 s), so GapObserved NOT SplitRequired.
/// The ~200 m is well below the 500 m split threshold.
final goldenWithGap = List<FixInput>.unmodifiable([
  // First segment: 5 fixes at 1 Hz
  FixInput(
    ts: _t(0),
    lat: 50.2,
    lon: 8.7,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-01',
  ),
  FixInput(
    ts: _t(1),
    lat: 50.2001,
    lon: 8.7001,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-02',
  ),
  FixInput(
    ts: _t(2),
    lat: 50.2002,
    lon: 8.7002,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-03',
  ),
  FixInput(
    ts: _t(3),
    lat: 50.2003,
    lon: 8.7003,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-04',
  ),
  FixInput(
    ts: _t(4),
    lat: 50.2004,
    lon: 8.7004,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-05',
  ),
  // 2-min gap (120 s offset), ~200 m further (≈0.002° lat ≈ 222 m)
  FixInput(
    ts: _t(4 + 120),
    lat: 50.202,
    lon: 8.701,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-06',
  ),
  FixInput(
    ts: _t(4 + 121),
    lat: 50.2021,
    lon: 8.7011,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-07',
  ),
  FixInput(
    ts: _t(4 + 122),
    lat: 50.2022,
    lon: 8.7012,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-08',
  ),
  FixInput(
    ts: _t(4 + 123),
    lat: 50.2023,
    lon: 8.7013,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-09',
  ),
  FixInput(
    ts: _t(4 + 124),
    lat: 50.2024,
    lon: 8.7014,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-gap-10',
  ),
]);

/// 5 fixes → 6-min gap (360 s, > 5 min threshold) → recovered fix ~800 m away.
/// Distance > 500 m split threshold → SplitRequired emitted at the gap boundary.
final goldenSplitCandidate = List<FixInput>.unmodifiable([
  FixInput(
    ts: _t(0),
    lat: 50.3,
    lon: 8.8,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-split-01',
  ),
  FixInput(
    ts: _t(1),
    lat: 50.3001,
    lon: 8.8001,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-split-02',
  ),
  FixInput(
    ts: _t(2),
    lat: 50.3002,
    lon: 8.8002,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-split-03',
  ),
  FixInput(
    ts: _t(3),
    lat: 50.3003,
    lon: 8.8003,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-split-04',
  ),
  FixInput(
    ts: _t(4),
    lat: 50.3004,
    lon: 8.8004,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-split-05',
  ),
  // 6-min gap (360 s), recovered ~800 m away (≈0.0072° lat ≈ 800 m)
  FixInput(
    ts: _t(4 + 360),
    lat: 50.3076,
    lon: 8.801,
    accuracyMeters: 10,
    speedMps: 10,
    uuid: 'uuid-split-06',
  ),
]);

/// 8 fixes over 40 s within a tiny 30 m bbox (parking lot shuffle).
/// finalize → passesKeeperThreshold == false (bbox diagonal < 50 m).
final goldenParkingLotShuffle = List<FixInput>.unmodifiable([
  FixInput(
    ts: _t(0),
    lat: 50.4,
    lon: 9,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-01',
  ),
  FixInput(
    ts: _t(5),
    lat: 50.4001,
    lon: 9.0001,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-02',
  ),
  FixInput(
    ts: _t(10),
    lat: 50.4002,
    lon: 9.0001,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-03',
  ),
  FixInput(
    ts: _t(15),
    lat: 50.4001,
    lon: 9.0002,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-04',
  ),
  FixInput(
    ts: _t(20),
    lat: 50.4,
    lon: 9.0002,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-05',
  ),
  FixInput(
    ts: _t(25),
    lat: 50.4001,
    lon: 9,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-06',
  ),
  FixInput(
    ts: _t(30),
    lat: 50.4002,
    lon: 9,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-07',
  ),
  FixInput(
    ts: _t(35),
    lat: 50.4001,
    lon: 9.0001,
    accuracyMeters: 8,
    speedMps: 1,
    uuid: 'uuid-park-08',
  ),
]);

/// 45 s of fixes at 30 km/h (~8.3 m/s), 1 Hz.
/// Duration < 60 s → passesKeeperThreshold == false.
final goldenShortDrive45s = List<FixInput>.unmodifiable([
  for (var i = 0; i < 45; i++)
    FixInput(
      ts: _t(i),
      // ~8.3 m/s ≈ 0.0001° lat per second
      lat: 50.5 + i * 0.0001,
      lon: 9.1,
      accuracyMeters: 8,
      speedMps: 8.3,
      uuid: 'uuid-short-${i.toString().padLeft(2, '0')}',
    ),
]);

/// 60 fixes at 1 Hz, 1.5 m/s (traffic jam), total distance ~90 m.
/// Distance < 100 m → passesKeeperThreshold == false.
final goldenTinyDistanceCrawl = List<FixInput>.unmodifiable([
  for (var i = 0; i < 60; i++)
    FixInput(
      ts: _t(i),
      // 1.5 m/s ≈ 0.0000135° lat per second
      lat: 50.6 + i * 0.0000135,
      lon: 9.2,
      accuracyMeters: 8,
      speedMps: 1.5,
      uuid: 'uuid-crawl-${i.toString().padLeft(2, '0')}',
    ),
]);
