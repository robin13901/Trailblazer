// Test file uses non-const constructors so we can vary args without rewriting
// the whole call site each time; the builder itself is stateless.
// ignore_for_file: prefer_const_constructors

import 'package:auto_explore/features/matching/data/overpass_query_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OverpassQueryBuilder', () {
    test('interpolates bbox coordinates in Overpass order (S,W,N,E)', () {
      final builder = OverpassQueryBuilder();
      final query = builder.buildBboxHighwayQuery(
        minLat: 52.49,
        minLon: 13.37,
        maxLat: 52.51,
        maxLon: 13.41,
      );
      expect(query, contains('way[highway](52.49,13.37,52.51,13.41);'));
    });

    test('default timeout is 25 seconds', () {
      final builder = OverpassQueryBuilder();
      final query = builder.buildBboxHighwayQuery(
        minLat: 0,
        minLon: 0,
        maxLat: 1,
        maxLon: 1,
      );
      expect(query, startsWith('[out:json][timeout:25];'));
    });

    test('honors caller-supplied timeout override', () {
      final builder = OverpassQueryBuilder();
      final query = builder.buildBboxHighwayQuery(
        minLat: 0,
        minLon: 0,
        maxLat: 1,
        maxLon: 1,
        timeoutSeconds: 180,
      );
      expect(query, startsWith('[out:json][timeout:180];'));
    });

    test('emits `out geom qt;` trailer for quadtree-sorted geometry', () {
      final builder = OverpassQueryBuilder();
      final query = builder.buildBboxHighwayQuery(
        minLat: 0,
        minLon: 0,
        maxLat: 1,
        maxLon: 1,
      );
      expect(query, endsWith('out geom qt;'));
    });

    test('uses multi-line format for probe-friendliness', () {
      final builder = OverpassQueryBuilder();
      final query = builder.buildBboxHighwayQuery(
        minLat: 47.9,
        minLon: 11.3,
        maxLat: 52.8,
        maxLon: 13.7,
      );
      final lines = query.split('\n');
      expect(lines, hasLength(3));
      expect(lines[0], '[out:json][timeout:25];');
      expect(lines[1], 'way[highway](47.9,11.3,52.8,13.7);');
      expect(lines[2], 'out geom qt;');
    });
  });
}
