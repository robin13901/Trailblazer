// Test file uses non-const parser constructors for readability across many
// small groups; the parser is stateless so const would work but isn't required.
// ignore_for_file: prefer_const_constructors

import 'dart:convert';
import 'dart:io';

import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OverpassResponseParser — fixtures', () {
    test('parses Kreuzberg (urban, 5×5 km) fixture into >500 Kfz ways', () {
      final raw = _readGzipFixture('urban_kreuzberg_5x5km.json.gz');
      final ways = OverpassResponseParser().parseWays(raw);
      expect(
        ways.length,
        greaterThan(500),
        reason: 'Kreuzberg 5×5 km bbox should yield >500 Kfz ways',
      );
      // All returned ways are Kfz-allowlisted.
      for (final w in ways) {
        expect(kfzHighwayClasses.contains(w.highwayClass), isTrue,
            reason: 'Non-Kfz class leaked: ${w.highwayClass}');
      }
      // All returned geometries have >=2 points.
      for (final w in ways) {
        expect(w.geometry.length, greaterThanOrEqualTo(2));
      }
    });

    test('parses Grebenhain (rural, 5×5 km) fixture into >50 Kfz ways', () {
      final raw = _readGzipFixture('rural_grebenhain_5x5km.json.gz');
      final ways = OverpassResponseParser().parseWays(raw);
      expect(
        ways.length,
        greaterThan(50),
        reason: 'Grebenhain 5×5 km bbox should yield >50 Kfz ways',
      );
      for (final w in ways) {
        expect(kfzHighwayClasses.contains(w.highwayClass), isTrue,
            reason: 'Non-Kfz class leaked: ${w.highwayClass}');
      }
    });
  });

  group('OverpassResponseParser — Kfz filter', () {
    test('drops footway/cycleway/path/track/service elements', () {
      const jsonBody = '''
{
  "version": 0.6,
  "generator": "test",
  "elements": [
    { "type": "way", "id": 1, "geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
      "tags": { "highway": "footway" } },
    { "type": "way", "id": 2, "geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
      "tags": { "highway": "cycleway" } },
    { "type": "way", "id": 3, "geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
      "tags": { "highway": "path" } },
    { "type": "way", "id": 4, "geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
      "tags": { "highway": "track" } },
    { "type": "way", "id": 5, "geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
      "tags": { "highway": "service" } },
    { "type": "way", "id": 6, "geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
      "tags": { "highway": "residential" } }
  ]
}
''';
      final ways = OverpassResponseParser().parseWays(jsonBody);
      expect(ways.map((w) => w.wayId).toList(), [6]);
      expect(ways.single.highwayClass, 'residential');
    });

    test('keeps all 14 Kfz allowlist entries', () {
      final elements = kfzHighwayClasses
          .mapIndexed(
            (i, hw) =>
                '{"type":"way","id":${i + 1},"geometry":[{"lat":0,"lon":0},'
                '{"lat":${i + 1},"lon":${i + 1}}],"tags":{"highway":"$hw"}}',
          )
          .join(',');
      final body =
          '{"version":0.6,"generator":"t","elements":[$elements]}';
      final ways = OverpassResponseParser().parseWays(body);
      expect(ways, hasLength(kfzHighwayClasses.length));
      expect(
        ways.map((w) => w.highwayClass).toSet(),
        kfzHighwayClasses,
      );
    });
  });

  group('OverpassResponseParser — oneway normalization', () {
    test('yes → forward', () {
      final ways = _parseOne(highway: 'primary', oneway: 'yes');
      expect(ways.single.oneway, OnewayDirection.forward);
    });

    test('-1 → backward', () {
      final ways = _parseOne(highway: 'primary', oneway: '-1');
      expect(ways.single.oneway, OnewayDirection.backward);
    });

    test('no → no', () {
      final ways = _parseOne(highway: 'primary', oneway: 'no');
      expect(ways.single.oneway, OnewayDirection.no);
    });

    test('absent + non-implicit → no', () {
      final ways = _parseOne(highway: 'primary');
      expect(ways.single.oneway, OnewayDirection.no);
    });

    test('absent + implicit (motorway) → forward', () {
      final ways = _parseOne(highway: 'motorway');
      expect(ways.single.oneway, OnewayDirection.forward);
    });

    test('absent + implicit (motorway_link) → forward', () {
      final ways = _parseOne(highway: 'motorway_link');
      expect(ways.single.oneway, OnewayDirection.forward);
    });

    test('absent + implicit (trunk_link) → forward', () {
      final ways = _parseOne(highway: 'trunk_link');
      expect(ways.single.oneway, OnewayDirection.forward);
    });

    test('trunk itself is NOT implicit-oneway', () {
      final ways = _parseOne(highway: 'trunk');
      expect(ways.single.oneway, OnewayDirection.no);
    });
  });

  group('OverpassResponseParser — maxspeed', () {
    test('plain integer string → km/h', () {
      final ways = _parseOne(highway: 'primary', maxspeed: '50');
      expect(ways.single.maxspeedKmh, 50);
    });

    test('kmh suffix', () {
      final ways = _parseOne(highway: 'primary', maxspeed: '100 kmh');
      expect(ways.single.maxspeedKmh, 100);
    });

    test('km/h suffix', () {
      final ways = _parseOne(highway: 'primary', maxspeed: '30 km/h');
      expect(ways.single.maxspeedKmh, 30);
    });

    test('mph suffix converts to km/h', () {
      final ways = _parseOne(highway: 'primary', maxspeed: '60 mph');
      expect(ways.single.maxspeedKmh, 97); // 60 * 1.609344 ≈ 96.56 → round 97
    });

    test('signals → null', () {
      final ways = _parseOne(highway: 'primary', maxspeed: 'signals');
      expect(ways.single.maxspeedKmh, isNull);
    });

    test('walk → null', () {
      final ways = _parseOne(highway: 'primary', maxspeed: 'walk');
      expect(ways.single.maxspeedKmh, isNull);
    });

    test('absent → null', () {
      final ways = _parseOne(highway: 'primary');
      expect(ways.single.maxspeedKmh, isNull);
    });
  });

  group('OverpassResponseParser — defensive parsing', () {
    test('non-JSON body → empty list, no throw', () {
      final ways = OverpassResponseParser().parseWays('not json <html>');
      expect(ways, isEmpty);
    });

    test('missing elements array → empty list', () {
      final ways = OverpassResponseParser().parseWays('{}');
      expect(ways, isEmpty);
    });

    test('skips non-way elements (nodes, relations)', () {
      const body = '''
{"elements":[
  {"type":"node","id":1,"lat":0,"lon":0},
  {"type":"relation","id":2},
  {"type":"way","id":3,"geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
   "tags":{"highway":"residential"}}
]}
''';
      final ways = OverpassResponseParser().parseWays(body);
      expect(ways.map((w) => w.wayId).toList(), [3]);
    });

    test('skips ways with fewer than 2 geometry points', () {
      const body = '''
{"elements":[
  {"type":"way","id":1,"geometry":[{"lat":0,"lon":0}],
   "tags":{"highway":"residential"}},
  {"type":"way","id":2,"geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}],
   "tags":{"highway":"residential"}}
]}
''';
      final ways = OverpassResponseParser().parseWays(body);
      expect(ways.map((w) => w.wayId).toList(), [2]);
    });

    test('skips ways with missing tags block', () {
      const body = '''
{"elements":[
  {"type":"way","id":1,"geometry":[{"lat":0,"lon":0},{"lat":1,"lon":1}]}
]}
''';
      final ways = OverpassResponseParser().parseWays(body);
      expect(ways, isEmpty);
    });
  });
}

List<WayCandidate> _parseOne({
  required String highway,
  String? oneway,
  String? maxspeed,
  String? name,
  String? ref,
}) {
  final tags = <String, String>{'highway': highway};
  if (oneway != null) tags['oneway'] = oneway;
  if (maxspeed != null) tags['maxspeed'] = maxspeed;
  if (name != null) tags['name'] = name;
  if (ref != null) tags['ref'] = ref;
  final body = jsonEncode({
    'elements': [
      {
        'type': 'way',
        'id': 42,
        'geometry': [
          {'lat': 0, 'lon': 0},
          {'lat': 1, 'lon': 1},
        ],
        'tags': tags,
      },
    ],
  });
  return OverpassResponseParser().parseWays(body);
}

String _readGzipFixture(String name) {
  final path = 'test/fixtures/overpass/$name';
  final bytes = File(path).readAsBytesSync();
  return utf8.decode(gzip.decode(bytes));
}

extension _MapIndexed<E> on Iterable<E> {
  Iterable<T> mapIndexed<T>(T Function(int i, E e) f) sync* {
    var i = 0;
    for (final e in this) {
      yield f(i, e);
      i++;
    }
  }
}
