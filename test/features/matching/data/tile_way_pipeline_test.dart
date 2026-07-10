import 'dart:convert';
import 'dart:io' show gzip;

import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/tile_way_pipeline.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers: synthesize gzipped Overpass tile payloads.
// ---------------------------------------------------------------------------

/// One Overpass `way` element with the given id + geometry (list of [lat,lon]).
Map<String, dynamic> _way(int id, List<List<double>> pts) => {
      'type': 'way',
      'id': id,
      'geometry': [
        for (final p in pts) {'lat': p[0], 'lon': p[1]},
      ],
      'tags': {'highway': 'residential'},
    };

/// Gzip a synthetic Overpass envelope wrapping [ways].
List<int> _gzTile(List<Map<String, dynamic>> ways) {
  final env = {'version': 0.6, 'elements': ways};
  return gzip.encode(utf8.encode(jsonEncode(env)));
}

GpsFix _fix(double lat, double lon) => GpsFix(
      lat: lat,
      lon: lon,
      accuracyMeters: 5,
      speedKmh: 50,
      ts: DateTime.fromMillisecondsSinceEpoch(0),
    );

const _wideBbox = LatLonBbox(minLat: 49, minLon: 8, maxLat: 50, maxLon: 10);

void main() {
  group('parseAndFilterTiles', () {
    test('empty input → empty output', () {
      expect(
        parseAndFilterTiles(gzippedTiles: const [], tileBboxes: const [], fixes: const []),
        isEmpty,
      );
    });

    test('keeps corridor ways, drops far-field ways', () {
      final fixes = [
        _fix(49.5000, 9),
        _fix(49.5010, 9.0010),
        _fix(49.5020, 9.0020),
      ];
      final tile = _gzTile([
        _way(1, [
          [49.5005, 9.0005],
          [49.5015, 9.0015],
        ]),
        _way(2, [
          [49.8000, 9.4000], // ~40 km away — outside corridor
          [49.8010, 9.4010],
        ]),
      ]);
      final kept = parseAndFilterTiles(
        gzippedTiles: [tile],
        tileBboxes: [_wideBbox],
        fixes: fixes,
      );
      expect(kept.map((w) => w.wayId), [1]);
    });

    test('dedupes a way that appears in two tiles', () {
      final fixes = [_fix(49.5000, 9), _fix(49.5010, 9.0010)];
      final onPath = _way(7, [
        [49.5005, 9.0005],
        [49.5015, 9.0015],
      ]);
      // Same wayId 7 present in two separate tiles (tile boundary overlap).
      final t1 = _gzTile([onPath]);
      final t2 = _gzTile([onPath]);
      final kept = parseAndFilterTiles(
        gzippedTiles: [t1, t2],
        tileBboxes: [_wideBbox, _wideBbox],
        fixes: fixes,
      );
      expect(kept.map((w) => w.wayId), [7]);
    });

    test('empty fixes → keeps all deduped, bbox-clipped ways (passthrough)', () {
      final tile = _gzTile([
        _way(1, [
          [49.5, 9],
          [49.51, 9.01],
        ]),
      ]);
      final kept = parseAndFilterTiles(
        gzippedTiles: [tile],
        tileBboxes: [_wideBbox],
        fixes: const [],
      );
      expect(kept.map((w) => w.wayId), [1]);
    });

    test('bbox clip drops a way entirely outside the tile bbox', () {
      final fixes = [_fix(49.5, 9)];
      // Way sits far outside the narrow tile bbox around the fix.
      final tile = _gzTile([
        _way(9, [
          [10, 10],
          [10.001, 10.001],
        ]),
      ]);
      final kept = parseAndFilterTiles(
        gzippedTiles: [tile],
        tileBboxes: [
          const LatLonBbox(minLat: 49.49, minLon: 8.99, maxLat: 49.51, maxLon: 9.01),
        ],
        fixes: fixes,
      );
      expect(kept, isEmpty);
    });
  });
}
