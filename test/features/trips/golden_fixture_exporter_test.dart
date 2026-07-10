// Trailblazer Phase 6, Plan 06-06 Task 1 tests:
// GoldenFixtureExporter — 3-file golden-fixture export from a seeded trip.
//
// Coverage:
//   * export creates gps_trace.json + ways.json.gz + expected_ways.json.
//   * gps_trace.json parses and has one entry per seeded point.
//   * expected_ways.json parses and matches the seeded interval count/order.
//   * ways.json.gz is a valid gzip stream (1F 8B magic).
//   * invalid slug → StorageError (a DomainError subtype).
//   * slug collision (dir already exists) → clean overwrite.
//   * round-trip (Issue 7): the exported ways.json.gz re-parses through the
//     exact corpus helper (FixtureWayCandidateSource.fromGzippedOverpassJson)
//     and the resulting way ids cover the seeded interval way ids.

import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/core/db/app_database.dart';
import 'package:auto_explore/core/db/daos/driven_way_intervals_dao.dart';
import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/data/golden_fixture_exporter.dart';
import 'package:auto_explore/features/trips/data/trips_dao.dart';
import 'package:auto_explore/features/trips/domain/trip_status.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:path/path.dart' as p;

import '../../helpers/fixture_way_candidate_source.dart';

/// A [WayCandidateSource] that returns a fixed list, ignoring the bbox.
class _FakeWaySource implements WayCandidateSource {
  _FakeWaySource(this.ways);

  final List<WayCandidate> ways;

  @override
  Future<List<WayCandidate>> fetchWaysInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async =>
      ways;

  @override
  Future<List<RawTilePayload>> fetchRawTilesInBbox({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    bool throwOnError = true,
  }) async =>
      const [];
}

WayCandidate _way(int id) => WayCandidate(
      wayId: id,
      geometry: const [
        LatLng(49.79, 9.18),
        LatLng(49.80, 9.20),
        LatLng(49.81, 9.22),
      ],
      // Must be Kfz-allowlisted so it survives the corpus parser's filter.
      highwayClass: 'residential',
      name: 'Test Straße',
      oneway: OnewayDirection.forward,
      maxspeedKmh: 50,
    );

void main() {
  late AppDatabase db;
  late TripsDao tripsDao;
  late DrivenWayIntervalsDao intervalsDao;
  late Directory tempDir;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tripsDao = TripsDao(db);
    intervalsDao = DrivenWayIntervalsDao(db);
    await db.customSelect('SELECT 1').getSingle();
    tempDir = await Directory.systemTemp.createTemp('golden_export_test');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<int> seedTrip() => db.into(db.trips).insert(
        TripsCompanion.insert(
          startedAt: DateTime.utc(2026, 7, 9, 8),
          endedAt: Value(DateTime.utc(2026, 7, 9, 8, 42)),
          status: const Value(TripStatus.matched),
          manuallyStarted: const Value(false),
        ),
      );

  Future<void> seedPoints(int tripId, int count) async {
    for (var i = 0; i < count; i++) {
      await db.into(db.tripPoints).insert(
            TripPointsCompanion.insert(
              tripId: tripId,
              seq: i,
              ts: DateTime.utc(2026, 7, 9, 8, 0, i),
              lat: 49.79 + i * 0.001,
              lon: 9.18 + i * 0.001,
              speedKmh: const Value(60),
              accuracyMeters: const Value(5),
            ),
          );
    }
  }

  Future<void> seedInterval(int tripId, int wayId) =>
      db.into(db.drivenWayIntervals).insert(
            DrivenWayIntervalsCompanion.insert(
              wayId: wayId,
              tripId: Value(tripId),
              startMeters: 0,
              endMeters: 100,
              matchedAt: Value(DateTime.utc(2026, 7, 9, 10)),
            ),
          );

  GoldenFixtureExporter buildExporter(List<WayCandidate> ways) =>
      GoldenFixtureExporter(
        tripsDao: tripsDao,
        waySource: _FakeWaySource(ways),
        intervalsDao: intervalsDao,
        appDocsFactory: () async => tempDir,
      );

  test('export creates the three fixture files with correct names', () async {
    final tripId = await seedTrip();
    await seedPoints(tripId, 5);
    await seedInterval(tripId, 1);
    final exporter = buildExporter([_way(1)]);

    final dirPath = await exporter.export(
      tripId: tripId,
      slug: '002_kleinheubach_roundabout',
    );

    expect(File(p.join(dirPath, 'gps_trace.json')).existsSync(), isTrue);
    expect(File(p.join(dirPath, 'ways.json.gz')).existsSync(), isTrue);
    expect(File(p.join(dirPath, 'expected_ways.json')).existsSync(), isTrue);
    // No stray .tmp files survive the atomic rename.
    expect(
      Directory(dirPath)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('gps_trace.json has one entry per seeded point', () async {
    final tripId = await seedTrip();
    await seedPoints(tripId, 4);
    await seedInterval(tripId, 1);
    final exporter = buildExporter([_way(1)]);

    final dirPath = await exporter.export(tripId: tripId, slug: '003_town_x');

    final raw = File(p.join(dirPath, 'gps_trace.json')).readAsStringSync();
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    expect(list, hasLength(4));
    expect(list.first['lat'], 49.79);
    expect(list.first['ts'], isA<String>());
    expect(list.first['speedKmh'], 60.0);
  });

  test('expected_ways.json matches seeded intervals count + order', () async {
    final tripId = await seedTrip();
    await seedPoints(tripId, 3);
    await seedInterval(tripId, 7);
    await seedInterval(tripId, 9);
    final exporter = buildExporter([_way(7), _way(9)]);

    final dirPath = await exporter.export(tripId: tripId, slug: '004_grid');

    final raw = File(p.join(dirPath, 'expected_ways.json')).readAsStringSync();
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    expect(list.map((e) => e['wayId']).toList(), [7, 9]);
    expect(list.first['direction'], 'forward');
  });

  test('ways.json.gz is a valid gzip stream (1F 8B magic)', () async {
    final tripId = await seedTrip();
    await seedPoints(tripId, 3);
    await seedInterval(tripId, 1);
    final exporter = buildExporter([_way(1)]);

    final dirPath = await exporter.export(tripId: tripId, slug: '005_gz');

    final bytes = File(p.join(dirPath, 'ways.json.gz')).readAsBytesSync();
    expect(bytes[0], 0x1F);
    expect(bytes[1], 0x8B);
    // And it decompresses to a parseable Overpass envelope.
    final json = jsonDecode(utf8.decode(gzip.decode(bytes)))
        as Map<String, dynamic>;
    expect(json['elements'], isA<List<dynamic>>());
  });

  test('invalid slug throws a DomainError (StorageError)', () async {
    final tripId = await seedTrip();
    await seedPoints(tripId, 3);
    final exporter = buildExporter([_way(1)]);

    expect(
      () => exporter.export(tripId: tripId, slug: 'Bad Slug!'),
      throwsA(isA<StorageError>()),
    );
    expect(
      () => exporter.export(tripId: tripId, slug: 'kleinheubach'),
      throwsA(isA<DomainError>()),
    );
  });

  test('slug collision overwrites the existing directory cleanly', () async {
    final tripId = await seedTrip();
    await seedPoints(tripId, 3);
    await seedInterval(tripId, 1);
    final exporter = buildExporter([_way(1)]);

    final dirPath = await exporter.export(tripId: tripId, slug: '006_collide');
    // Plant a stale file that must NOT survive the re-export.
    File(p.join(dirPath, 'stale.txt')).writeAsStringSync('old');

    final dirPath2 =
        await exporter.export(tripId: tripId, slug: '006_collide');

    expect(dirPath2, dirPath);
    expect(File(p.join(dirPath, 'stale.txt')).existsSync(), isFalse);
    expect(File(p.join(dirPath, 'gps_trace.json')).existsSync(), isTrue);
  });

  test('round-trip: exported ways.json.gz re-parses through the corpus helper',
      () async {
    final tripId = await seedTrip();
    await seedPoints(tripId, 3);
    await seedInterval(tripId, 7);
    await seedInterval(tripId, 9);
    final exporter = buildExporter([_way(7), _way(9)]);

    final dirPath = await exporter.export(tripId: tripId, slug: '007_roundtrip');

    // Re-parse with the EXACT helper golden_corpus_test.dart uses.
    final source = await FixtureWayCandidateSource.fromGzippedOverpassJson(
      p.join(dirPath, 'ways.json.gz'),
    );
    final ways = await source.fetchWaysInBbox(
      minLat: 49,
      minLon: 8,
      maxLat: 50,
      maxLon: 10,
    );

    final wayIds = ways.map((w) => w.wayId).toSet();
    expect(wayIds, isNotEmpty);
    // Every seeded interval way id is present in the exported candidate set.
    final expectedRaw =
        File(p.join(dirPath, 'expected_ways.json')).readAsStringSync();
    final expectedIds = (jsonDecode(expectedRaw) as List)
        .cast<Map<String, dynamic>>()
        .map((e) => e['wayId'] as int)
        .toSet();
    expect(wayIds.containsAll(expectedIds), isTrue);
    // Tags survive the re-emit (proves Path B shape is faithful).
    expect(ways.first.highwayClass, 'residential');
  });
}
