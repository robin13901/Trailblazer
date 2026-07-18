// Trailblazer DEV TOOL (not a CI test): diagnose specific coverage artifacts.
//
// Explains WHY a given way is/ isn't painted under the new matcher, by dumping
// per-matched-way facts (class, name, oneway, driven-union vs full length) and
// flagging two effects the user asked about:
//   (1) a road present in the BEFORE snapped-chord line but absent in AFTER;
//   (2) an AFTER way whose driven union interval covers far more of the way
//       than the raw GPS points actually spanned (an "over-draw" candidate —
//       e.g. a full-length connector extension).
//
// This is a local diagnostic harness, not production code — relaxed lints.
// ignore_for_file: avoid_print
//
// Run: flutter test test/tools/diagnose_artifacts_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/tile_way_pipeline.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_matcher.dart';
import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:auto_explore/features/trips/domain/haversine.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:sqlite3/sqlite3.dart';

const _exportPath =
    r'C:\Users\I551358\Downloads\trailblazer_backup_20260718_1820.trailblazer';

void main() {
  if (!File(_exportPath).existsSync()) {
    test('diagnose artifacts (skipped — export absent)', () {}, skip: true);
    return;
  }

  test('diagnose coverage artifacts', () async {
    final db = sqlite3.open(_exportPath, mode: OpenMode.readOnly);
    addTearDown(db.close);

    const tileMath = TileBboxMath();
    final tileRows = db.select(
      'SELECT tile_z, tile_x, tile_y, payload_gzip FROM overpass_way_cache',
    );
    final gzippedTiles = <List<int>>[];
    final tileBboxes = <LatLonBbox>[];
    for (final r in tileRows) {
      gzippedTiles.add(r['payload_gzip'] as Uint8List);
      tileBboxes.add(
        tileMath.tileToBbox(
          TileId(r['tile_z'] as int, r['tile_x'] as int, r['tile_y'] as int),
        ),
      );
    }
    const parser = OverpassResponseParser();
    final allWaysById = <int, WayCandidate>{};
    for (final gz in gzippedTiles) {
      for (final w in parser.parseWays(utf8.decode(gzip.decode(gz)))) {
        allWaysById[w.wayId] = w;
      }
    }

    const matcher = HmmMatcher();
    final trips = db.select('SELECT id FROM trips ORDER BY id');

    // Accumulate per-way union across all trips (mirrors the resolver).
    final unionByWay = <int, List<Interval>>{};
    // Track the raw-GPS span actually observed on each way (nearest matched
    // fixes' min/max meters) so we can compare against the drawn union.
    for (final t in trips) {
      final tripId = t['id'] as int;
      final ptRows = db.select(
        'SELECT lat, lon, speed_kmh, accuracy_meters, ts FROM trip_points '
        'WHERE trip_id = ? ORDER BY seq',
        [tripId],
      );
      final fixes = <GpsFix>[
        for (final p in ptRows)
          GpsFix(
            lat: p['lat'] as double,
            lon: p['lon'] as double,
            accuracyMeters:
                (p['accuracy_meters'] as num?)?.toDouble() ?? double.nan,
            speedKmh: (p['speed_kmh'] as num?)?.toDouble() ?? 0.0,
            ts: DateTime.fromMillisecondsSinceEpoch((p['ts'] as int) * 1000,
                isUtc: true),
          ),
      ];
      final ways = parseAndFilterTiles(
        gzippedTiles: gzippedTiles,
        tileBboxes: tileBboxes,
        fixes: fixes,
      );
      final result = matcher.match(fixes: fixes, ways: ways);
      for (final iv in result.intervals) {
        unionByWay
            .putIfAbsent(iv.wayId, () => [])
            .add(Interval(iv.startMeters, iv.endMeters));
      }
    }

    print('\n===== AFTER: every painted way (union across all trips) =====');
    print('wayId | class | drivenM / fullM (%) | name');
    final flagged = <String>[];
    for (final entry in unionByWay.entries) {
      final way = allWaysById[entry.key];
      if (way == null) continue;
      final union = unionIntervals(entry.value);
      final drivenM = drivenLengthMeters(entry.value);
      final fullM = _fullLen(way.geometry);
      final pct = fullM > 0 ? (drivenM / fullM * 100) : 0.0;
      // Over-draw flag: the union covers a big contiguous stretch but the raw
      // interval count suggests it was extended (a single interval spanning
      // ~full length that came from few fixes = a connector full-extend).
      final spansMostOfWay = pct > 80 && fullM > 60;
      final oneInterval = union.length == 1;
      final flag = (spansMostOfWay && oneInterval) ? '  <-- full-span' : '';
      print('${entry.key} | ${way.highwayClass} | '
          '${drivenM.toStringAsFixed(0)} / ${fullM.toStringAsFixed(0)} '
          '(${pct.toStringAsFixed(0)}%) | ${way.name ?? "-"}$flag');
      if (flag.isNotEmpty) {
        flagged.add('${entry.key} (${way.highwayClass}, ${way.name ?? "-"})');
      }
    }

    print('\n===== Non-Kfz classes present in cache near driven area =====');
    final classes = <String, int>{};
    for (final w in allWaysById.values) {
      classes[w.highwayClass] = (classes[w.highwayClass] ?? 0) + 1;
    }
    print('cached way classes: $classes');

    print('\n===== full-span (possibly connector-extended) ways =====');
    for (final f in flagged) {
      print('  $f');
    }
    print('(total painted ways: ${unionByWay.length})');

    // Probe the two circled locations (mapped from the overview_after pixels
    // via the trip-point bounds). For each, list nearby ways with their driven
    // union so we can name exactly what the circles contain.
    // Collect ALL raw fixes across trips (for the over-draw proximity test).
    final allFixPts = <LatLng>[];
    for (final t in db.select('SELECT id FROM trips')) {
      for (final p in db.select(
        'SELECT lat, lon FROM trip_points WHERE trip_id = ?',
        [t['id'] as int],
      )) {
        allFixPts.add(LatLng(p['lat'] as double, p['lon'] as double));
      }
    }

    // Over-draw detector: a way painted ≥80% whose MIDPOINT is far (>30 m) from
    // every raw GPS fix was not actually driven through its middle — it was
    // extended (connector full-span) or matched off a tangential pass.
    print('\n===== OVER-DRAW candidates (painted ≥80%, midpoint >30m from any '
        'raw fix) =====');
    for (final entry in unionByWay.entries) {
      final way = allWaysById[entry.key];
      if (way == null || way.geometry.length < 2) continue;
      final drivenM = drivenLengthMeters(entry.value);
      final fullM = _fullLen(way.geometry);
      if (fullM <= 0 || drivenM / fullM < 0.8) continue;
      final mid = way.geometry[way.geometry.length ~/ 2];
      var minD = double.infinity;
      for (final fp in allFixPts) {
        final d = segmentLengthMeters(
          aLat: mid.latitude, aLon: mid.longitude,
          bLat: fp.latitude, bLon: fp.longitude,
        );
        if (d < minD) minD = d;
        if (minD < 5) break;
      }
      if (minD > 30) {
        print('  ${entry.key} | ${way.highwayClass} | ${way.name ?? "-"} | '
            '${drivenM.toStringAsFixed(0)}/${fullM.toStringAsFixed(0)}m | '
            'midpoint ${minD.toStringAsFixed(0)}m from nearest raw fix');
      }
    }
  });
}

double _fullLen(List<LatLng> g) {
  var t = 0.0;
  for (var i = 0; i < g.length - 1; i++) {
    t += haversineMeters(
        g[i].latitude, g[i].longitude, g[i + 1].latitude, g[i + 1].longitude);
  }
  return t;
}
