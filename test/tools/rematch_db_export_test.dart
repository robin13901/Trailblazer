// Trailblazer DEV TOOL (not a CI test): offline re-match of a real DB export.
//
// This is a local visual-diagnostic harness, not production code — relaxed lints.
// ignore_for_file: cascade_invocations, avoid_multiple_declarations_per_line
// ignore_for_file: eol_at_end_of_file, avoid_print
// ignore_for_file: unnecessary_parenthesis
//
// Reproduces the road-matching artifacts from the user's exported database and
// renders BEFORE (stored coverage_path_json — the per-fix snapped chords) vs
// AFTER (new route-aware match → clipped way-geometry) for visual confirmation
// before re-importing to the device.
//
// It reuses the REAL production pipeline (parseAndFilterTiles + HmmMatcher +
// reconstructWaySubsegment), so what it renders is exactly what will ship.
//
// GATED: skips entirely unless the export file exists at the path below, so it
// never runs in CI / on another machine. Run locally with:
//   flutter test test/tools/rematch_db_export_test.dart
//
// Output PNGs land in C:/tmp/rematch_out/ (before_*.png / after_*.png / a
// combined overview.png). Open them to compare.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_explore/features/coverage/domain/interval_union.dart';
import 'package:auto_explore/features/coverage/domain/way_subsegment.dart';
import 'package:auto_explore/features/matching/data/overpass_response_parser.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/tile_way_pipeline.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_matcher.dart';
import 'package:auto_explore/features/matching/domain/way_candidate.dart';
import 'package:flutter/material.dart' hide Interval;
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;
import 'package:sqlite3/sqlite3.dart';

const _exportPath =
    r'C:\Users\I551358\Downloads\trailblazer_backup_20260718_1820.trailblazer';
const _outDir = r'C:\tmp\rematch_out';

void main() {
  final exportFile = File(_exportPath);
  if (!exportFile.existsSync()) {
    test('rematch DB export (skipped — export file absent)', () {
      print('SKIP: $_exportPath not found.');
    }, skip: true);
    return;
  }

  test('rematch DB export → before/after PNGs', () async {
    final db = sqlite3.open(_exportPath, mode: OpenMode.readOnly);
    addTearDown(db.close);

    Directory(_outDir).createSync(recursive: true);

    // 1. Load all cached tiles once (raw gzipped payloads + their z12 bbox).
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
          TileId(
            r['tile_z'] as int,
            r['tile_x'] as int,
            r['tile_y'] as int,
          ),
        ),
      );
    }

    // Parse ALL ways once (for geometry lookup by id when clipping the AFTER
    // line). Small dataset in the export; fine to hold in memory here.
    const parser = OverpassResponseParser();
    final allWaysById = <int, WayCandidate>{};
    for (final gz in gzippedTiles) {
      final json = utf8.decode(gzip.decode(gz));
      for (final w in parser.parseWays(json)) {
        allWaysById[w.wayId] = w;
      }
    }
    print('Loaded ${gzippedTiles.length} tiles, ${allWaysById.length} ways.');

    // 2. Per trip: BEFORE = stored coverage_path_json; AFTER = re-match now.
    final trips = db.select(
      'SELECT id, coverage_path_json FROM trips ORDER BY id',
    );
    const matcher = HmmMatcher();

    final allBefore = <List<LatLng>>[];
    final allAfter = <List<LatLng>>[];

    for (final trip in trips) {
      final tripId = trip['id'] as int;

      // BEFORE: decode the stored per-fix snapped chords.
      final before = <List<LatLng>>[];
      final storedJson = trip['coverage_path_json'] as String?;
      if (storedJson != null && storedJson.isNotEmpty) {
        final decoded = jsonDecode(storedJson);
        if (decoded is List) {
          for (final seg in decoded) {
            if (seg is! List) continue;
            final pts = <LatLng>[
              for (final p in seg)
                if (p is List && p.length >= 2)
                  LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
            ];
            if (pts.length >= 2) before.add(pts);
          }
        }
      }

      // AFTER: re-run the real pipeline on this trip's fixes.
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
            accuracyMeters: (p['accuracy_meters'] as num?)?.toDouble() ??
                double.nan,
            speedKmh: (p['speed_kmh'] as num?)?.toDouble() ?? 0.0,
            ts: DateTime.fromMillisecondsSinceEpoch(
              (p['ts'] as int) * 1000,
              isUtc: true,
            ),
          ),
      ];
      final ways = parseAndFilterTiles(
        gzippedTiles: gzippedTiles,
        tileBboxes: tileBboxes,
        fixes: fixes,
      );
      final result = matcher.match(fixes: fixes, ways: ways);

      // Clip AFTER geometry per union interval (same logic as the resolver).
      final byWayId = <int, List<Interval>>{};
      for (final iv in result.intervals) {
        byWayId
            .putIfAbsent(iv.wayId, () => [])
            .add(Interval(iv.startMeters, iv.endMeters));
      }
      final after = <List<LatLng>>[];
      for (final entry in byWayId.entries) {
        final way = allWaysById[entry.key];
        if (way == null) continue;
        for (final u in unionIntervals(entry.value)) {
          final seg = reconstructWaySubsegment(
            way.geometry,
            u.startMeters,
            u.endMeters,
            snapMeters: kWaySubsegmentSnapMeters,
          );
          if (seg.length >= 2) after.add(seg);
        }
      }

      print('trip $tripId: ${fixes.length} fixes → '
          '${result.intervals.length} intervals, '
          '${result.matchedFixCount} matched / ${result.droppedFixCount} '
          'dropped; before=${before.length} segs, after=${after.length} segs');

      allBefore.addAll(before);
      allAfter.addAll(after);

      await _renderPolylines(
        '$_outDir/before_trip$tripId.png',
        before,
        const Color(0xFFFFA500),
      );
      await _renderPolylines(
        '$_outDir/after_trip$tripId.png',
        after,
        const Color(0xFFFFA500),
      );
    }

    // Combined overview across all trips.
    await _renderPolylines('$_outDir/overview_before.png', allBefore,
        const Color(0xFFFFA500));
    await _renderPolylines('$_outDir/overview_after.png', allAfter,
        const Color(0xFFFFA500));

    // Auto-locate the worst BEFORE artifacts (sharp direction reversals — the
    // triangle/fan/spur signature) and render tight before/after crops there,
    // with the surrounding road network in grey for context. This is where the
    // fix is visible: a spike in BEFORE should be a clean road-following line
    // in AFTER.
    final allRoads = allWaysById.values.toList();
    final hotspots = _findSpikes(allBefore);
    for (var i = 0; i < hotspots.length; i++) {
      final c = hotspots[i];
      await _renderWindow(
        '$_outDir/zoom${i}_before.png',
        segments: allBefore,
        roads: allRoads,
        centre: c,
        halfSpanMeters: 120,
      );
      await _renderWindow(
        '$_outDir/zoom${i}_after.png',
        segments: allAfter,
        roads: allRoads,
        centre: c,
        halfSpanMeters: 120,
      );
    }

    print('Wrote PNGs to $_outDir (${hotspots.length} zoom hotspots)');
    expect(Directory(_outDir).listSync().whereType<File>().length,
        greaterThan(0));
  });
}

/// Rasterize a set of [lat,lon] polylines to a PNG at [path] using an
/// equirectangular projection fit to the data bounds. Dark background + a thin
/// grey grid so the shape reads like the app map.
Future<void> _renderPolylines(
  String path,
  List<List<LatLng>> segments,
  Color color,
) async {
  const size = 1400.0;
  const pad = 40.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()..color = const Color(0xFF1A1A1A),
  );

  if (segments.isEmpty) {
    final pic = recorder.endRecording();
    final img = await pic.toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
    return;
  }

  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (final seg in segments) {
    for (final p in seg) {
      minLat = p.latitude < minLat ? p.latitude : minLat;
      maxLat = p.latitude > maxLat ? p.latitude : maxLat;
      minLon = p.longitude < minLon ? p.longitude : minLon;
      maxLon = p.longitude > maxLon ? p.longitude : maxLon;
    }
  }
  final latSpan = (maxLat - minLat).abs().clamp(1e-6, 90);
  final lonSpan = (maxLon - minLon).abs().clamp(1e-6, 180);
  final span = latSpan > lonSpan ? latSpan : lonSpan;

  Offset project(LatLng p) {
    final x = pad + ((p.longitude - minLon) / span) * (size - 2 * pad);
    // Flip lat so north is up.
    final y = size - (pad + ((p.latitude - minLat) / span) * (size - 2 * pad));
    return Offset(x, y);
  }

  final paint = Paint()
    ..color = color
    ..strokeWidth = 4
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  for (final seg in segments) {
    final pathObj = Path()..moveTo(project(seg.first).dx, project(seg.first).dy);
    for (var i = 1; i < seg.length; i++) {
      final o = project(seg[i]);
      pathObj.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(pathObj, paint);
  }

  final pic = recorder.endRecording();
  final img = await pic.toImage(size.toInt(), size.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
}

/// Find the sharpest direction reversals in [segments] — the geometric
/// signature of the triangle/fan/spur artifacts (a vertex where the path turns
/// back on itself). Returns up to [maxSpots] well-separated hotspot centres.
List<LatLng> _findSpikes(List<List<LatLng>> segments, {int maxSpots = 4}) {
  final scored = <(double, LatLng)>[];
  for (final seg in segments) {
    for (var i = 1; i < seg.length - 1; i++) {
      final a = seg[i - 1], b = seg[i], c = seg[i + 1];
      // Incoming/outgoing bearings in local metric space.
      final v1x = (b.longitude - a.longitude);
      final v1y = (b.latitude - a.latitude);
      final v2x = (c.longitude - b.longitude);
      final v2y = (c.latitude - b.latitude);
      final m1 = _hyp(v1x, v1y), m2 = _hyp(v2x, v2y);
      if (m1 < 1e-9 || m2 < 1e-9) continue;
      // cosθ between segments; near -1 = a near-180° reversal (a spike).
      final dot = (v1x * v2x + v1y * v2y) / (m1 * m2);
      final reversal = -dot; // 1.0 = perfect spike
      if (reversal > 0.5) scored.add((reversal, b));
    }
  }
  scored.sort((x, y) => y.$1.compareTo(x.$1));
  final out = <LatLng>[];
  for (final s in scored) {
    if (out.length >= maxSpots) break;
    // Keep hotspots spatially separated (~200 m).
    final tooClose = out.any((o) =>
        _hyp((o.longitude - s.$2.longitude) * 73000,
            (o.latitude - s.$2.latitude) * 111320) <
        200);
    if (!tooClose) out.add(s.$2);
  }
  return out;
}

double _hyp(double a, double b) => math.sqrt(a * a + b * b);

/// Render a tight geographic window centred on [centre] (±[halfSpanMeters]),
/// with driven [segments] in orange over the [roads] network in grey — so a
/// junction artifact is visible against the actual roads.
Future<void> _renderWindow(
  String path, {
  required List<List<LatLng>> segments,
  required List<WayCandidate> roads,
  required LatLng centre,
  required double halfSpanMeters,
}) async {
  const size = 900.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()..color = const Color(0xFF1A1A1A),
  );

  final dLat = halfSpanMeters / 111320.0;
  final dLon = halfSpanMeters / (111320.0 * _cosDeg(centre.latitude));
  final minLat = centre.latitude - dLat, maxLat = centre.latitude + dLat;
  final minLon = centre.longitude - dLon, maxLon = centre.longitude + dLon;

  Offset? project(LatLng p) {
    final x = ((p.longitude - minLon) / (maxLon - minLon)) * size;
    final y = size - ((p.latitude - minLat) / (maxLat - minLat)) * size;
    return Offset(x, y);
  }

  bool inWin(LatLng p) =>
      p.latitude >= minLat &&
      p.latitude <= maxLat &&
      p.longitude >= minLon &&
      p.longitude <= maxLon;

  // Roads (grey) — draw any way with a vertex in/near the window.
  final roadPaint = Paint()
    ..color = const Color(0xFF4A4A4A)
    ..strokeWidth = 6
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  for (final w in roads) {
    if (!w.geometry.any(inWin)) continue;
    final pathObj = Path();
    var started = false;
    for (final p in w.geometry) {
      final o = project(p)!;
      if (!started) {
        pathObj.moveTo(o.dx, o.dy);
        started = true;
      } else {
        pathObj.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(pathObj, roadPaint);
  }

  // Driven line (orange).
  final drivenPaint = Paint()
    ..color = const Color(0xFFFFA500)
    ..strokeWidth = 4
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  for (final seg in segments) {
    if (!seg.any(inWin)) continue;
    final pathObj = Path();
    var started = false;
    for (final p in seg) {
      final o = project(p)!;
      if (!started) {
        pathObj.moveTo(o.dx, o.dy);
        started = true;
      } else {
        pathObj.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(pathObj, drivenPaint);
  }

  final pic = recorder.endRecording();
  final img = await pic.toImage(size.toInt(), size.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
}

double _cosDeg(double deg) => math.cos(deg * math.pi / 180.0);

