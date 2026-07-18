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
// ignore_for_file: avoid_print, unnecessary_parenthesis
// ignore_for_file: avoid_multiple_declarations_per_line, prefer_int_literals
//
// Run: flutter test test/tools/diagnose_artifacts_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:auto_explore/features/coverage/data/driven_way_geometry_resolver.dart';
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

    // ========================================================================
    // RENDER-TIME NODE-GRAPH FEASIBILITY PROBE (2026-07-18)
    // ========================================================================
    // Mirrors what _clipCoverageIsolate has available: the DRIVEN wayId set and
    // the WayCandidates parsed from raw tiles (with nodeIds). We answer:
    //  (1) do the driven ways carry nodeIds (length == geometry.length)?
    //  (2) per driven way, which endpoint nodes are shared with ANOTHER driven
    //      way (bridging) vs shared with none (dangling leaf)?
    //  (3) confirm start node = 0m, end node = fullLength.
    print('\n===== NODE-GRAPH FEASIBILITY: driven-way nodeId availability =====');
    final drivenWayIds = unionByWay.keys.toSet();
    var withIds = 0;
    var withoutIds = 0;
    var idLenMismatch = 0;
    for (final wid in drivenWayIds) {
      final w = allWaysById[wid];
      if (w == null) continue;
      if (w.nodeIds.isEmpty) {
        withoutIds++;
      } else if (w.nodeIds.length != w.geometry.length) {
        idLenMismatch++;
      } else {
        withIds++;
      }
    }
    print('driven ways: ${drivenWayIds.length} | with nodeIds(len==geom): '
        '$withIds | empty nodeIds: $withoutIds | len-mismatch: $idLenMismatch');

    // Build node -> set of DRIVEN wayIds that list that node (endpoints ONLY,
    // i.e. first & last node id — that is all the resolver needs to stitch).
    final endpointNodeToDrivenWays = <int, Set<int>>{};
    // Also build ALL-node -> driven ways, to detect mid-way T-junctions (an
    // endpoint of way X touching the MIDDLE of driven way Y).
    final anyNodeToDrivenWays = <int, Set<int>>{};
    for (final wid in drivenWayIds) {
      final w = allWaysById[wid];
      if (w == null || w.nodeIds.length != w.geometry.length) continue;
      final ids = w.nodeIds;
      endpointNodeToDrivenWays.putIfAbsent(ids.first, () => {}).add(wid);
      endpointNodeToDrivenWays.putIfAbsent(ids.last, () => {}).add(wid);
      for (final id in ids) {
        anyNodeToDrivenWays.putIfAbsent(id, () => {}).add(wid);
      }
    }

    print('\n===== NODE-GRAPH FEASIBILITY: per-driven-way endpoint topology ===');
    print('wayId | name | startNode shared? | endNode shared? '
        '| fullM | classification');
    var bridging = 0;
    var danglingBoth = 0;
    var danglingOne = 0;
    for (final wid in drivenWayIds) {
      final w = allWaysById[wid];
      if (w == null || w.nodeIds.length != w.geometry.length) continue;
      final ids = w.nodeIds;
      final startId = ids.first;
      final endId = ids.last;
      // Shared with ANOTHER driven way at the endpoint node (endpoint-endpoint),
      // OR the endpoint node lies mid-way on another driven way (endpoint->mid).
      final startEndpointShared =
          (endpointNodeToDrivenWays[startId]?.difference({wid}).isNotEmpty) ??
              false;
      final startMidShared =
          (anyNodeToDrivenWays[startId]?.difference({wid}).isNotEmpty) ?? false;
      final endEndpointShared =
          (endpointNodeToDrivenWays[endId]?.difference({wid}).isNotEmpty) ??
              false;
      final endMidShared =
          (anyNodeToDrivenWays[endId]?.difference({wid}).isNotEmpty) ?? false;
      final startShared = startEndpointShared || startMidShared;
      final endShared = endEndpointShared || endMidShared;
      final fullM = _fullLen(w.geometry);
      final String cls;
      if (startShared && endShared) {
        cls = 'BRIDGING(both ends stitched)';
        bridging++;
      } else if (!startShared && !endShared) {
        cls = 'ISOLATED(dangling both)';
        danglingBoth++;
      } else {
        cls = 'LEAF(one end dangling)';
        danglingOne++;
      }
      print('$wid | ${w.name ?? "-"} | start=$startShared | end=$endShared '
          '| ${fullM.toStringAsFixed(0)}m | $cls');
    }
    print('summary: bridging=$bridging leaf-one-dangling=$danglingOne '
        'isolated=$danglingBoth');

    // (3) Confirm the endpoint-meter mapping the resolver relies on: a way's
    //     FIRST node id corresponds to 0m and its LAST node id to fullLength.
    //     _metersFromWayStart accumulates from geometry[0]; interval start/end
    //     are meters from geometry[0]. So start node = 0, end node = full.
    print('\n===== NODE-GRAPH FEASIBILITY: endpoint-meter sanity (first 5) ====');
    var shown = 0;
    for (final wid in drivenWayIds) {
      final w = allWaysById[wid];
      if (w == null || w.geometry.length < 2) continue;
      final fullM = _fullLen(w.geometry);
      print('$wid: firstNode=${w.nodeIds.isNotEmpty ? w.nodeIds.first : "-"}'
          ' -> 0.0m | lastNode=${w.nodeIds.isNotEmpty ? w.nodeIds.last : "-"}'
          ' -> ${fullM.toStringAsFixed(1)}m (geom pts=${w.geometry.length})');
      if (++shown >= 5) break;
    }

    // THORN diagnosis: for each driven way, does its union interval touch an
    // endpoint (0m or fullM within snap 20m)? A "thorn" is a tiny painted stub
    // at the START of a way whose union covers only a few metres near an
    // endpoint. Count driven ways whose TOTAL drawn length < 25m.
    print('\n===== THORN candidates: driven union < 25m total =====');
    for (final entry in unionByWay.entries) {
      final w = allWaysById[entry.key];
      if (w == null) continue;
      final drivenM = drivenLengthMeters(entry.value);
      if (drivenM >= 25) continue;
      final union = unionIntervals(entry.value);
      final fullM = _fullLen(w.geometry);
      print('  ${entry.key} | ${w.highwayClass} | ${w.name ?? "-"} | '
          'drivenM=${drivenM.toStringAsFixed(1)} fullM=${fullM.toStringAsFixed(0)} '
          '| intervals=${union.map((i) => "[${i.startMeters.toStringAsFixed(0)}"
              "..${i.endMeters.toStringAsFixed(0)}]").join(",")}');
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

    // -----------------------------------------------------------------------
    // THORN detector: painted ways whose driven union is TINY (< 25m / < 10m).
    // With no floor in the resolver, any such union renders as a short orange
    // stub. Report count + name a few, and locate the union vs the way ENDS
    // (junctions) — a thorn is a short interval hugging start or end of a way.
    // -----------------------------------------------------------------------
    print('\n===== THORNS: painted ways with tiny driven union =====');
    var under25 = 0;
    var under10 = 0;
    final thornRows = <String>[];
    for (final entry in unionByWay.entries) {
      final way = allWaysById[entry.key];
      if (way == null || way.geometry.length < 2) continue;
      final union = unionIntervals(entry.value);
      final drivenM = drivenLengthMeters(entry.value);
      final fullM = _fullLen(way.geometry);
      if (drivenM >= 25) continue;
      under25++;
      if (drivenM < 10) under10++;
      // How close is the driven union to a way END (junction)?
      final unionStart = union.first.startMeters;
      final unionEnd = union.last.endMeters;
      final distToStart = unionStart; // metres from way's first node
      final distToEnd = (fullM - unionEnd).clamp(0.0, fullM);
      final nearEnd = math.min(distToStart, distToEnd);
      final atWhichEnd = distToStart <= distToEnd ? 'START' : 'END';
      thornRows.add(
        '${entry.key} | ${way.highwayClass} | '
        'driven ${drivenM.toStringAsFixed(1)}m / full ${fullM.toStringAsFixed(0)}m | '
        'union [${unionStart.toStringAsFixed(1)}..${unionEnd.toStringAsFixed(1)}] | '
        'nearest way-end ${nearEnd.toStringAsFixed(1)}m ($atWhichEnd) | '
        '${way.name ?? "-"}',
      );
    }
    // Sort ascending by driven length so the smallest thorns lead.
    thornRows.sort((a, b) {
      double d(String s) =>
          double.parse(RegExp(r'driven ([\d.]+)m').firstMatch(s)!.group(1)!);
      return d(a).compareTo(d(b));
    });
    print('painted ways with driven union < 25m: $under25');
    print('painted ways with driven union < 10m: $under10');
    print('(of ${unionByWay.length} total painted ways)');
    print('--- thorn detail (smallest first) ---');
    for (final r in thornRows) {
      print('  $r');
    }

    // ======================================================================
    // ROUNDABOUT PROBE (Am Hundsrück, Kleinheubach) — GAP FOCUS.
    // Snap the seed to the nearest raw fix, take a radius around it, dump every
    // cached local way (painted?, union vs full, endpoint node ids, reach at
    // each end, nearest-fix). Then run adjacency: painted neighbours sharing an
    // endpoint node whose intervals fall SHORT of it = the (a) stitch-gap.
    // ======================================================================
    const seedLat = 49.719, seedLon = 9.206;
    var probeLat = seedLat, probeLon = seedLon, dSeed = double.infinity;
    // Prefer centering on the "Am Hundsrück" way (25062484) if present — that is
    // literally the road the user named; the roundabout segments cluster around
    // it. Fall back to the seed lat/lon snapped to the nearest fix.
    const kAmHundsruckWayId = 25062484;
    final amHund = allWaysById[kAmHundsruckWayId];
    if (amHund != null && amHund.geometry.isNotEmpty) {
      final mid = amHund.geometry[amHund.geometry.length ~/ 2];
      probeLat = mid.latitude;
      probeLon = mid.longitude;
      dSeed = 0;
    } else {
      for (final fp in allFixPts) {
        final d = segmentLengthMeters(
            aLat: seedLat, aLon: seedLon,
            bLat: fp.latitude, bLon: fp.longitude);
        if (d < dSeed) {
          dSeed = d;
          probeLat = fp.latitude;
          probeLon = fp.longitude;
        }
      }
    }
    const probeRadiusM = 200.0;
    print('\n===== ROUNDABOUT PROBE @ ($probeLat,$probeLon) '
        '(centered on Am Hundsrück way $kAmHundsruckWayId), '
        'radius ${probeRadiusM.toStringAsFixed(0)}m =====');

    double nearestFixTo(LatLng p) {
      var m = double.infinity;
      for (final fp in allFixPts) {
        final d = segmentLengthMeters(
            aLat: p.latitude, aLon: p.longitude,
            bLat: fp.latitude, bLon: fp.longitude);
        if (d < m) m = d;
      }
      return m;
    }

    final localWayIds = <int>[];
    for (final w in allWaysById.values) {
      final near = w.geometry.any((p) =>
          segmentLengthMeters(
              aLat: p.latitude, aLon: p.longitude,
              bLat: probeLat, bLon: probeLon) <=
          probeRadiusM);
      if (near) localWayIds.add(w.wayId);
    }
    localWayIds.sort();

    // Per-way endpoint node ids + interval reach (gap from each way end).
    final startNodeOf = <int, int>{};
    final endNodeOf = <int, int>{};
    final startGapOf = <int, double>{}; // metres from way-start to first iv
    final endGapOf = <int, double>{}; // metres from last iv to way-end
    print('wayId | painted | class | oneway | drivenM/fullM(%) | intervals | '
        'startGap endGap | nearestFix(s/m/e) | isRoundabout | name');
    for (final id in localWayIds) {
      final way = allWaysById[id]!;
      final geom = way.geometry;
      final fullM = _fullLen(geom);
      final painted = unionByWay.containsKey(id);
      final union = painted ? unionIntervals(unionByWay[id]!) : <Interval>[];
      final drivenM = painted ? drivenLengthMeters(unionByWay[id]!) : 0.0;
      final pct = fullM > 0 ? drivenM / fullM * 100 : 0.0;
      final startGap = union.isEmpty ? double.nan : union.first.startMeters;
      final endGap =
          union.isEmpty ? double.nan : (fullM - union.last.endMeters);
      final hasIds = way.nodeIds.length == geom.length && geom.length >= 2;
      if (hasIds) {
        startNodeOf[id] = way.nodeIds.first;
        endNodeOf[id] = way.nodeIds.last;
      }
      if (painted) {
        startGapOf[id] = startGap;
        endGapOf[id] = endGap;
      }
      // Roundabout heuristic: first node id == last node id (closed loop), OR
      // a short way whose two ends are physically close.
      final closed = hasIds && way.nodeIds.first == way.nodeIds.last;
      final ivStr = union.isEmpty
          ? '-'
          : union
              .map((iv) => '[${iv.startMeters.toStringAsFixed(0)}..'
                  '${iv.endMeters.toStringAsFixed(0)}]')
              .join(',');
      print('$id | ${painted ? "YES" : "no "} | ${way.highwayClass} | '
          '${way.oneway.name} | ${drivenM.toStringAsFixed(0)}/'
          '${fullM.toStringAsFixed(0)}(${pct.toStringAsFixed(0)}%) | $ivStr | '
          '${startGap.isNaN ? "-" : startGap.toStringAsFixed(0)} '
          '${endGap.isNaN ? "-" : endGap.toStringAsFixed(0)} | '
          '${nearestFixTo(geom.first).toStringAsFixed(0)}/'
          '${nearestFixTo(geom[geom.length ~/ 2]).toStringAsFixed(0)}/'
          '${nearestFixTo(geom.last).toStringAsFixed(0)} | '
          '${closed ? "LOOP" : "-"} | ${way.name ?? "-"}');
    }

    // (b) local ways with a raw fix <=20m but NOT painted (dropped by matcher).
    print('\n----- (b) local ways driven-near (fix<=20m) but NOT painted -----');
    var droppedNear = 0;
    for (final id in localWayIds) {
      if (unionByWay.containsKey(id)) continue;
      final way = allWaysById[id]!;
      var minD = double.infinity;
      for (final v in way.geometry) {
        final d = nearestFixTo(v);
        if (d < minD) minD = d;
      }
      if (minD <= 20) {
        droppedNear++;
        print('  DROPPED $id | ${way.highwayClass} | ${way.oneway.name} | '
            'fullM ${_fullLen(way.geometry).toStringAsFixed(0)} | '
            'nearestFix ${minD.toStringAsFixed(0)}m | ${way.name ?? "-"}');
      }
    }
    print('  (dropped-near count: $droppedNear)');

    // (a) painted neighbours sharing a node id, with the gap at the shared node.
    print('\n----- (a) painted neighbours sharing an ENDPOINT node id; gap at '
        'that node (own-way 20m snap cannot stitch across two ways) -----');
    final paintedLocal = localWayIds.where(unionByWay.containsKey).toList();
    var stitchGaps = 0;
    for (var i = 0; i < paintedLocal.length; i++) {
      for (var j = i + 1; j < paintedLocal.length; j++) {
        final a = paintedLocal[i], b = paintedLocal[j];
        final aS = startNodeOf[a], aE = endNodeOf[a];
        final bS = startNodeOf[b], bE = endNodeOf[b];
        void consider(String lbl, int? an, double ag, int? bn, double bg) {
          if (an == null || bn == null || an != bn) return;
          final worst =
              [ag, bg].where((x) => !x.isNaN).fold(0.0, math.max);
          final flag = worst > 20 ? '  <-- GAP >20m (snap CANNOT close)' : '';
          if (worst > 20) stitchGaps++;
          print('  node $an ($a.$lbl): gapA '
              '${ag.isNaN ? "-" : ag.toStringAsFixed(0)}m gapB '
              '${bg.isNaN ? "-" : bg.toStringAsFixed(0)}m$flag');
        }

        final aSG = startGapOf[a] ?? double.nan;
        final aEG = endGapOf[a] ?? double.nan;
        final bSG = startGapOf[b] ?? double.nan;
        final bEG = endGapOf[b] ?? double.nan;
        consider('start=$b.start', aS, aSG, bS, bSG);
        consider('start=$b.end', aS, aSG, bE, bEG);
        consider('end=$b.start', aE, aEG, bS, bSG);
        consider('end=$b.end', aE, aEG, bE, bEG);
      }
    }
    print('  (shared-node stitch gaps >20m: $stitchGaps)');

    // (c) resolver clip on local painted ways: does it drop segments?
    print('\n----- (c) resolver clip (20m snap) output vs union, local ways ---');
    var clipDrops = 0;
    for (final id in paintedLocal) {
      final way = allWaysById[id]!;
      for (final iv in unionIntervals(unionByWay[id]!)) {
        final seg = _clip(way.geometry, iv.startMeters, iv.endMeters, 20);
        final drop = seg.length < 2;
        if (drop) clipDrops++;
        print('  $id iv[${iv.startMeters.toStringAsFixed(0)}..'
            '${iv.endMeters.toStringAsFixed(0)}] -> ${seg.length}pts, '
            '${_fullLen(seg).toStringAsFixed(0)}m'
            '${drop ? "  <-- DROPPED (<2pts)" : ""}');
      }
    }
    print('  (clip drops: $clipDrops)');

    // ========================================================================
    // VALIDATE THE FIX: run the real clipDrivenWays over the DB and assert the
    // workflow's checks (thorns dropped, roundabout connector bridged+drawn).
    // ========================================================================
    print('\n===== VALIDATE clipDrivenWays (production render fn) =====');
    final unionTuples = <int, List<(double, double)>>{
      for (final e in unionByWay.entries)
        e.key: [for (final iv in e.value) (iv.startMeters, iv.endMeters)],
    };
    final geomById = <int, List<LatLng>>{};
    final nodesById = <int, List<int>>{};
    for (final wid in unionByWay.keys) {
      final w = allWaysById[wid];
      if (w == null) continue;
      geomById[wid] = w.geometry;
      nodesById[wid] = w.nodeIds;
    }
    final rendered = clipDrivenWays(
      unionByWayId: unionTuples,
      geomByWayId: geomById,
      nodesByWayId: nodesById,
    );
    final renderedWayIds = rendered.map((c) => c.wayId).toSet();

    const namedThorns = [
      948405611, 23216865, 25157794, 194941556, 109061179, 194941543,
    ];
    final survivingThorns =
        namedThorns.where(renderedWayIds.contains).toList();
    print('named thorns still rendered: $survivingThorns (want [])');

    // Recompute the bridge classification to tell legit short bridging
    // connectors (kept on purpose) from any short NON-bridging leftover.
    final endpointNodes = <int, Set<int>>{};
    for (final wid in unionByWay.keys) {
      final w = allWaysById[wid];
      if (w == null || w.nodeIds.length != w.geometry.length || w.nodeIds.isEmpty) {
        continue;
      }
      endpointNodes.putIfAbsent(w.nodeIds.first, () => {}).add(wid);
      endpointNodes.putIfAbsent(w.nodeIds.last, () => {}).add(wid);
    }
    bool bridgesNet(int wid) {
      final w = allWaysById[wid];
      if (w == null || w.nodeIds.length != w.geometry.length || w.nodeIds.isEmpty) {
        return false;
      }
      final a = endpointNodes[w.nodeIds.first]?.difference({wid}).isNotEmpty ?? false;
      final b = endpointNodes[w.nodeIds.last]?.difference({wid}).isNotEmpty ?? false;
      return a && b;
    }

    var shortBridge = 0;
    var shortNonBridge = 0;
    final shortNonBridgeIds = <int>{};
    for (final c in rendered) {
      if (_fullLen(c.geometry) < 25) {
        if (bridgesNet(c.wayId)) {
          shortBridge++;
        } else {
          shortNonBridge++;
          shortNonBridgeIds.add(c.wayId);
        }
      }
    }
    print('rendered segments <25m: bridging(kept, legit)=$shortBridge | '
        'NON-bridging(potential thorns)=$shortNonBridge ids=$shortNonBridgeIds');

    // Roundabout connector 868553172 (73m tertiary_link): must bridge + draw.
    const connector = 868553172;
    final connGeom = geomById[connector];
    if (connGeom != null) {
      final connRendered =
          rendered.where((c) => c.wayId == connector).toList();
      final drawnLen = connRendered.fold<double>(
          0, (a, c) => a + _fullLen(c.geometry));
      print('connector $connector: rendered=${connRendered.isNotEmpty} '
          'drawnLen=${drawnLen.toStringAsFixed(0)}m / '
          'full=${_fullLen(connGeom).toStringAsFixed(0)}m');
    } else {
      print('connector $connector: not in driven set this run');
    }
    print('total rendered segments: ${rendered.length} '
        '(distinct ways: ${renderedWayIds.length})');
  });
}

/// Local copy of reconstructWaySubsegment's clip so the diagnostic can measure
/// the isolate output without importing render deps.
List<LatLng> _clip(
    List<LatLng> geometry, double startMeters, double endMeters, double snap) {
  if (geometry.length < 2) return const [];
  var lo = math.min(startMeters, endMeters);
  var hi = math.max(startMeters, endMeters);
  if (snap > 0) {
    final total = _fullLen(geometry);
    if (lo <= snap) lo = 0;
    if (hi >= total - snap) hi = total;
  }
  final result = <LatLng>[];
  var cumulative = 0.0;
  for (var i = 0; i < geometry.length - 1; i++) {
    final a = geometry[i], b = geometry[i + 1];
    final segLen =
        haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude);
    final segStart = cumulative, segEnd = cumulative + segLen;
    if (segLen > 0 && segEnd >= lo && segStart <= hi) {
      final tStart = ((lo - segStart) / segLen).clamp(0.0, 1.0);
      final tEnd = ((hi - segStart) / segLen).clamp(0.0, 1.0);
      if (result.isEmpty) {
        result.add(LatLng(a.latitude + (b.latitude - a.latitude) * tStart,
            a.longitude + (b.longitude - a.longitude) * tStart));
      }
      result.add(LatLng(a.latitude + (b.latitude - a.latitude) * tEnd,
          a.longitude + (b.longitude - a.longitude) * tEnd));
    }
    cumulative = segEnd;
  }
  return result;
}

double _fullLen(List<LatLng> g) {
  var t = 0.0;
  for (var i = 0; i < g.length - 1; i++) {
    t += haversineMeters(
        g[i].latitude, g[i].longitude, g[i + 1].latitude, g[i + 1].longitude);
  }
  return t;
}
