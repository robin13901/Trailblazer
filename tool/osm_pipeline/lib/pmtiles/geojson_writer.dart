/// GeoJSONSeq writer — Stage D.1 of the pmtiles pipeline (04-07).
///
/// Streams one Feature per line to disk (no wrapping FeatureCollection —
/// tippecanoe's preferred input format). Four layer writers produce
/// `roads`, `admin_boundaries`, `water`, `labels`.
///
/// Roads + admin_boundaries read from the SCRATCH DB (produced by 04-03/04).
/// Water + labels do an additional PBF pass — this stage is the first
/// consumer of `natural=water` / `waterway=*` / `place=*` data (04-CONTEXT
/// road-graph focus meant those tags were dropped by 04-03's Kfz/Feldweg
/// filter).
///
/// Feature JSON layout (single line, terminated by `\n`):
///
///   ```json
///   {"type":"Feature","geometry":{...},"properties":{...}}
///   ```
///
/// Empty layers still produce a valid (empty) file — the tippecanoe runner
/// tolerates zero-feature layers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/progress_logger.dart';
import 'package:osm_pipeline/intersect/way_admin_join.dart'
    show decodeMultiPolygonWkb;
import 'package:osm_pipeline/pbf/entities.dart';
import 'package:osm_pipeline/pbf/pbf_reader.dart';
import 'package:osm_pipeline/pmtiles/layer_schema.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// The set of `place=*` node values that become labels-layer features.
const Set<String> kLabelPlaceValues = {
  'country',
  'state',
  'city',
  'town',
  'village',
  'suburb',
};

/// Which highway kinds emit road-shield labels (must have a non-empty `ref`).
const Set<String> kLabelShieldHighways = {'motorway', 'trunk', 'primary'};

/// Which `waterway=*` values become LineString features.
const Set<String> kWaterwayLineKinds = {'river', 'stream', 'canal'};

/// Streams the four vector layers to `IOSink` targets.
///
/// The class is a pure namespace — all methods are static.
abstract final class GeoJsonSeqWriter {
  // ---------------------------------------------------------------------
  // Roads layer.
  // ---------------------------------------------------------------------

  /// Emits roads-layer features from `ways_raw` + `nodes_raw`.
  ///
  /// One Feature per way. Feldweg rows carry `kind = collapseHighwayKind(hw)`
  /// too (usually `track` or `path`). LineString-empty ways (< 2 nodes) are
  /// skipped silently — they wouldn't render anyway.
  static Future<int> writeRoads(ScratchDb scratch, IOSink out) async {
    final db = scratch.raw;
    final total = db
        .select('SELECT COUNT(*) AS n FROM ways_raw;')
        .first['n'] as int;
    final progress = ProgressLogger(
      'Stage F.1 roads',
      total: total,
      unit: 'ways',
    );
    final nodeSelect = db.prepare(
      'SELECT lat, lng FROM nodes_raw WHERE id = ?;',
    );
    // v2 (2026-07-07 · Plan 04-10-1-02): Feldweg is INCLUDED here on purpose.
    // osm.sqlite drops Feldweg (Kfz-only after 04-10-1-02) but the pmtiles
    // roads layer must retain both — REN-02's visual base geometry (dashed
    // blue Feldweg tracks) reads from the pmtiles, not osm.sqlite.
    final wayRows = db.select(
      'SELECT id, highway, name, ref, is_directional, node_ids FROM ways_raw;',
    );
    var written = 0;
    try {
      for (final row in wayRows) {
        progress.tick();
        final nodeIds = decodeNodeIds(row['node_ids'] as Uint8List);
        final coords = <List<double>>[];
        for (final nid in nodeIds) {
          final rs = nodeSelect.select([nid]);
          if (rs.isEmpty) continue;
          final lat = rs.first['lat'] as double;
          final lng = rs.first['lng'] as double;
          coords.add([lng, lat]);
        }
        if (coords.length < 2) continue;

        final hw = row['highway'] as String;
        final kind = collapseHighwayKind(hw);
        final properties = <String, Object?>{
          'kind': kind,
          if (row['name'] != null) 'name': row['name'] as String,
          if (row['ref'] != null) 'ref': row['ref'] as String,
          'oneway': (row['is_directional'] as int) == 1,
        };
        out.writeln(_feature('LineString', coords, properties));
        written++;
      }
    } finally {
      nodeSelect.dispose();
    }
    progress.finish();
    return written;
  }

  // ---------------------------------------------------------------------
  // Admin boundaries layer.
  // ---------------------------------------------------------------------

  /// Emits admin_boundaries features from `admin_regions_raw`.
  ///
  /// Emits TWO features per region: the Polygon fill and the LineString
  /// outline (concatenated rings — outer first, then inners in ring-order).
  /// This lets 04-08's style paint fills + outlines independently.
  static Future<int> writeAdminBoundaries(ScratchDb scratch, IOSink out) async {
    final db = scratch.raw;
    // 04-05/06 write the admin_regions_raw table; guard against a scratch
    // DB that never applied the admin schema (tests may skip it).
    if (!_hasTable(db, 'admin_regions_raw')) return 0;

    final rows = db.select(
      'SELECT region_id, admin_level, name, geometry_wkb '
      'FROM admin_regions_raw;',
    );
    final progress = ProgressLogger(
      'Stage F.1 admin_boundaries',
      total: rows.length,
      unit: 'regions',
    );
    var written = 0;
    for (final row in rows) {
      progress.tick();
      final level = row['admin_level'] as int;
      final name = row['name'] as String;
      final mp = decodeMultiPolygonWkb(row['geometry_wkb'] as Uint8List);
      if (mp.polygons.isEmpty) continue;

      // Polygon fill — MultiPolygon coords: [ [outer, inner1, ...], ... ].
      final polyCoords = <List<List<List<double>>>>[];
      for (final poly in mp.polygons) {
        final ringSet = <List<List<double>>>[
          [
            for (final v in poly.outer) [v.lng, v.lat],
          ],
        ];
        for (final hole in poly.holes) {
          ringSet.add([
            for (final v in hole) [v.lng, v.lat],
          ]);
        }
        polyCoords.add(ringSet);
      }
      final baseProps = <String, Object?>{
        'admin_level': level,
        'kind': adminKindForLevel(level),
        'name': name,
      };
      out.writeln(
        _feature(
          'MultiPolygon',
          polyCoords,
          <String, Object?>{...baseProps, 'shape': 'fill'},
        ),
      );

      // LineString outlines — one MultiLineString per region concatenating
      // all outer + inner rings.
      final lines = <List<List<double>>>[];
      for (final poly in mp.polygons) {
        lines.add([
          for (final v in poly.outer) [v.lng, v.lat],
        ]);
        for (final hole in poly.holes) {
          lines.add([
            for (final v in hole) [v.lng, v.lat],
          ]);
        }
      }
      out.writeln(
        _feature(
          'MultiLineString',
          lines,
          <String, Object?>{...baseProps, 'shape': 'outline'},
        ),
      );

      written += 2;
    }
    progress.finish();
    return written;
  }

  // ---------------------------------------------------------------------
  // Water layer.
  // ---------------------------------------------------------------------

  /// Emits water-layer features. Requires a PBF pass since 04-03/04 dropped
  /// non-highway/non-admin data. Skips sea polygons (04-RESEARCH §12
  /// pitfall #3 — coastline reconstruction is out of scope for v1).
  ///
  /// The pass:
  ///   * A: collect way ids and node ids referenced by water relations +
  ///     ways with `natural=water` or `waterway=river|stream|canal`.
  ///   * B: resolve node coordinates.
  ///   * C: emit features.
  static Future<int> writeWater(File pbf, ScratchDb scratch, IOSink out) async {
    // Pass A: identify water ways + their nodes.
    final waterProgress = ProgressLogger(
      'Stage F.1 water',
      total: 0,
      unit: 'ways',
    );
    final waterWays = <int, _WaterWay>{};
    final wantedNodes = <int>{};
    await for (final e in PbfReader().stream(pbf)) {
      if (e is! OsmWay) continue;
      final kind = _classifyWaterWay(e);
      if (kind == null) continue;
      waterWays[e.id] = _WaterWay(
        way: e,
        kind: kind,
        isArea: e.tags['natural'] == 'water' ||
            e.tags['waterway'] == 'riverbank',
      );
      wantedNodes.addAll(e.nodeRefs);
      waterProgress.tick();
    }

    if (waterWays.isEmpty) {
      waterProgress.finish();
      return 0;
    }

    // Pass B: resolve nodes.
    final nodes = <int, ({double lat, double lng})>{};
    await for (final e in PbfReader().stream(pbf)) {
      if (e is OsmNode && wantedNodes.contains(e.id)) {
        nodes[e.id] = (lat: e.lat, lng: e.lng);
      }
    }

    // Pass C: emit features.
    var written = 0;
    for (final w in waterWays.values) {
      final coords = <List<double>>[];
      for (final nid in w.way.nodeRefs) {
        final n = nodes[nid];
        if (n == null) continue;
        coords.add([n.lng, n.lat]);
      }
      if (coords.length < 2) continue;

      final name = w.way.tags['name'];
      final properties = <String, Object?>{
        'kind': w.kind,
        if (name != null && name.isNotEmpty) 'name': name,
      };

      if (w.isArea) {
        // Emit as Polygon with a single closed outer ring. If the way is
        // not closed, close it defensively for tippecanoe.
        final ring = coords.length >= 3
            ? (coords.first[0] == coords.last[0] &&
                    coords.first[1] == coords.last[1]
                ? coords
                : [...coords, coords.first])
            : null;
        if (ring == null) continue;
        out.writeln(
          _feature('Polygon', [ring], properties),
        );
      } else {
        out.writeln(_feature('LineString', coords, properties));
      }
      written++;
    }
    waterProgress.finish();
    return written;
  }

  // ---------------------------------------------------------------------
  // Labels layer.
  // ---------------------------------------------------------------------

  /// Emits labels-layer features from an additional PBF pass:
  ///   * place=country|state|city|town|village|suburb nodes → Point.
  ///   * motorway/trunk/primary ways with a non-empty `ref` → Point at
  ///     midpoint of the way, `kind='road_shield'`.
  static Future<int> writeLabels(
    File pbf,
    ScratchDb scratch,
    IOSink out,
  ) async {
    // Pass A: collect place nodes AND shield-way ids.
    final progress = ProgressLogger(
      'Stage F.1 labels',
      total: 0,
      unit: 'candidates',
    );
    final placeNodes = <_LabelPlaceNode>[];
    final shieldWays = <int, ({String ref, List<int> nodeRefs})>{};
    final shieldNodeIds = <int>{};
    await for (final e in PbfReader().stream(pbf)) {
      if (e is OsmNode) {
        final place = e.tags['place'];
        if (place != null && kLabelPlaceValues.contains(place)) {
          final name = e.tags['name'];
          if (name == null || name.isEmpty) continue;
          final pop = int.tryParse(e.tags['population'] ?? '');
          placeNodes.add(
            _LabelPlaceNode(
              lat: e.lat,
              lng: e.lng,
              kind: 'place_$place',
              name: name,
              population: pop,
            ),
          );
          progress.tick();
        }
      } else if (e is OsmWay) {
        final hw = e.tags['highway'];
        if (hw == null) continue;
        final collapsed = collapseHighwayKind(hw);
        if (!kLabelShieldHighways.contains(collapsed)) continue;
        final ref = e.tags['ref'];
        if (ref == null || ref.isEmpty) continue;
        shieldWays[e.id] = (ref: ref, nodeRefs: e.nodeRefs);
        shieldNodeIds.addAll(e.nodeRefs);
        progress.tick();
      }
    }

    // Pass B: resolve shield-way node coords for midpoint calculation.
    final nodeCoords = <int, ({double lat, double lng})>{};
    if (shieldNodeIds.isNotEmpty) {
      await for (final e in PbfReader().stream(pbf)) {
        if (e is OsmNode && shieldNodeIds.contains(e.id)) {
          nodeCoords[e.id] = (lat: e.lat, lng: e.lng);
        }
      }
    }

    // Pass C: emit place-node features.
    var written = 0;
    for (final p in placeNodes) {
      final properties = <String, Object?>{
        'kind': p.kind,
        'name': p.name,
        if (p.population != null) 'population': p.population,
      };
      out.writeln(_feature('Point', [p.lng, p.lat], properties));
      written++;
    }

    // Pass D: emit shield features at midpoint of each way.
    for (final entry in shieldWays.entries) {
      final way = entry.value;
      final resolved = <({double lat, double lng})>[];
      for (final nid in way.nodeRefs) {
        final n = nodeCoords[nid];
        if (n != null) resolved.add(n);
      }
      if (resolved.isEmpty) continue;
      final mid = resolved[resolved.length ~/ 2];
      out.writeln(
        _feature(
          'Point',
          [mid.lng, mid.lat],
          <String, Object?>{'kind': 'road_shield', 'ref': way.ref},
        ),
      );
      written++;
    }

    progress.finish();
    return written;
  }
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

String _feature(
  String geomType,
  Object coordinates,
  Map<String, Object?> properties,
) {
  return jsonEncode(<String, Object?>{
    'type': 'Feature',
    'geometry': {'type': geomType, 'coordinates': coordinates},
    'properties': properties,
  });
}

bool _hasTable(Database db, String name) {
  final rs = db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;",
    [name],
  );
  return rs.isNotEmpty;
}

String? _classifyWaterWay(OsmWay w) {
  final natural = w.tags['natural'];
  if (natural == 'water') {
    // Reject sea explicitly per 04-RESEARCH §12 pitfall #3.
    final water = w.tags['water'];
    if (water == 'sea') return null;
    return 'lake';
  }
  final waterway = w.tags['waterway'];
  if (waterway != null && kWaterwayLineKinds.contains(waterway)) {
    return waterway;
  }
  return null;
}

class _WaterWay {
  const _WaterWay({
    required this.way,
    required this.kind,
    required this.isArea,
  });
  final OsmWay way;
  final String kind;
  final bool isArea;
}

class _LabelPlaceNode {
  const _LabelPlaceNode({
    required this.lat,
    required this.lng,
    required this.kind,
    required this.name,
    required this.population,
  });
  final double lat;
  final double lng;
  final String kind;
  final String name;
  final int? population;
}
