/// way_admin_join — Stage D orchestrator.
///
/// Reads `ways_raw` (Kfz source) and `admin_regions_raw` from the scratch DB,
/// runs the segmented-intersection clipper (see `polygon_clip.dart`) per
/// (way, region) candidate pair filtered by bbox overlap, and writes one row
/// per inside-sub-segment into `way_admin_raw`.
///
/// The wholly-contained-way roll-up onto denormalized `ways` columns is
/// deferred to Plan 04-06 — that plan reads the strategy recommendation from
/// `04-05-BERLIN-MEASUREMENT.md` before deciding the final osm.sqlite shape.
///
/// See 04-05-PLAN.md Task 4 + 04-RESEARCH.md §7.
library;

import 'dart:typed_data';

import 'package:osm_pipeline/intersect/polygon_clip.dart';
import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:osm_pipeline/scratch/scratch_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// Admin levels 04-05 populates way_admin_raw at.
const List<int> kAdminLevels = [2, 4, 6, 8, 9, 10];

/// Stats produced by a [buildWayAdminJoin] run.
class WayAdminJoinStats {
  /// Create a stats record.
  const WayAdminJoinStats({
    required this.waysProcessed,
    required this.rowsWritten,
    required this.candidatePairsProbed,
  });

  /// How many Kfz ways the orchestrator iterated.
  final int waysProcessed;

  /// How many way_admin_raw rows were INSERTed.
  final int rowsWritten;

  /// How many (way, admin_region) pairs passed the bbox pre-filter and were
  /// probed by the clipper. Useful for perf tuning.
  final int candidatePairsProbed;
}

/// Runs the segmented-intersection join over the scratch DB. Populates
/// `way_admin_raw` per the schema declared in `scratch_schema.dart`.
WayAdminJoinStats buildWayAdminJoin(ScratchDb scratch) {
  final db = scratch.raw;

  // 1. Load all admin regions once, indexed by admin_level. Berlin has ~130
  //    regions total; Germany has ~11 000 across L2..L10. For Berlin-scale
  //    fixtures a linear scan is fine; for Germany, the loader falls back to
  //    a bucketed lat/lng grid (see [_AdminGrid] below).
  final adminByLevel = <int, List<_AdminEntry>>{};
  for (final level in kAdminLevels) {
    adminByLevel[level] = _loadAdmins(db, level);
  }

  // 2. Prepare the join insert. WITHOUT ROWID + PK(way_id, region_id, level,
  //    fraction_start) means the insert throws on collision — we use
  //    OR IGNORE so a way that enters/exits/re-enters at the same
  //    fraction_start is still tolerated (shouldn't happen in practice).
  final insert = db.prepare('''
INSERT OR IGNORE INTO way_admin_raw
  (way_id, region_id, admin_level, fraction_start, fraction_end)
VALUES (?, ?, ?, ?, ?);
''');

  final nodeSelect = db.prepare(
    'SELECT lat, lng FROM nodes_raw WHERE id = ?;',
  );

  var waysProcessed = 0;
  var rowsWritten = 0;
  var candidatePairsProbed = 0;

  db.execute('BEGIN;');
  try {
    final wayRows = db.select(
      "SELECT id, node_ids FROM ways_raw WHERE source = 'kfz';",
    );
    for (final row in wayRows) {
      waysProcessed++;
      final wayId = row['id'] as int;
      final nodeIds = decodeNodeIds(row['node_ids'] as Uint8List);
      final linePoints = <Vec2>[];
      for (final nid in nodeIds) {
        final rs = nodeSelect.select([nid]);
        if (rs.isEmpty) continue;
        linePoints.add(
          Vec2(rs.first['lng'] as double, rs.first['lat'] as double),
        );
      }
      if (linePoints.length < 2) continue;

      final wayBbox = _bboxOfLine(linePoints);

      for (final level in kAdminLevels) {
        final admins = adminByLevel[level]!;
        for (final admin in admins) {
          if (!_bboxOverlap(wayBbox, admin.bbox)) continue;
          candidatePairsProbed++;
          final subs = clipLinestringToPolygon(linePoints, admin.geometry);
          for (final sub in subs) {
            insert.execute([
              wayId,
              admin.regionId,
              level,
              sub.fractionStart,
              sub.fractionEnd,
            ]);
            rowsWritten++;
          }
        }
      }
    }
    db.execute('COMMIT;');
  } catch (e) {
    db.execute('ROLLBACK;');
    rethrow;
  } finally {
    insert.dispose();
    nodeSelect.dispose();
  }

  return WayAdminJoinStats(
    waysProcessed: waysProcessed,
    rowsWritten: rowsWritten,
    candidatePairsProbed: candidatePairsProbed,
  );
}

// ---------------------------------------------------------------------------
// Admin loader + bbox helpers.
// ---------------------------------------------------------------------------

class _Bbox {
  const _Bbox(this.minLat, this.maxLat, this.minLng, this.maxLng);
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;
}

class _AdminEntry {
  const _AdminEntry({
    required this.regionId,
    required this.bbox,
    required this.geometry,
  });
  final int regionId;
  final _Bbox bbox;
  final ClipMultiPolygon geometry;
}

List<_AdminEntry> _loadAdmins(Database db, int level) {
  final rows = db.select(
    'SELECT region_id, geometry_wkb, bbox_minlat, bbox_maxlat, '
    'bbox_minlng, bbox_maxlng FROM admin_regions_raw '
    'WHERE admin_level = ?;',
    [level],
  );
  final out = <_AdminEntry>[];
  for (final row in rows) {
    final blob = row['geometry_wkb'] as Uint8List;
    final geom = decodeMultiPolygonWkb(blob);
    out.add(
      _AdminEntry(
        regionId: row['region_id'] as int,
        bbox: _Bbox(
          row['bbox_minlat'] as double,
          row['bbox_maxlat'] as double,
          row['bbox_minlng'] as double,
          row['bbox_maxlng'] as double,
        ),
        geometry: geom,
      ),
    );
  }
  return out;
}

_Bbox _bboxOfLine(List<Vec2> line) {
  var minLat = double.infinity;
  var maxLat = double.negativeInfinity;
  var minLng = double.infinity;
  var maxLng = double.negativeInfinity;
  for (final p in line) {
    if (p.lat < minLat) minLat = p.lat;
    if (p.lat > maxLat) maxLat = p.lat;
    if (p.lng < minLng) minLng = p.lng;
    if (p.lng > maxLng) maxLng = p.lng;
  }
  return _Bbox(minLat, maxLat, minLng, maxLng);
}

bool _bboxOverlap(_Bbox a, _Bbox b) =>
    a.minLat <= b.maxLat &&
    a.maxLat >= b.minLat &&
    a.minLng <= b.maxLng &&
    a.maxLng >= b.minLng;

// ---------------------------------------------------------------------------
// WKB decoder. Inverse of `wkb_writer.dart::encodeMultiPolygon`.
// ---------------------------------------------------------------------------

/// Decode an OGC WKB MultiPolygon blob into a [ClipMultiPolygon]. Handles the
/// exact byte layout the pipeline's own encoder emits (little-endian NDR,
/// type=MultiPolygon(6), rings closed with first==last).
ClipMultiPolygon decodeMultiPolygonWkb(Uint8List blob) {
  final buf = ByteData.sublistView(blob);
  var offset = 0;
  final byteOrder = buf.getUint8(offset);
  offset += 1;
  final endian = byteOrder == 1 ? Endian.little : Endian.big;
  final type = buf.getUint32(offset, endian);
  offset += 4;
  if (type != 6) {
    throw ArgumentError('Not a MultiPolygon WKB (type=$type)');
  }
  final polyCount = buf.getUint32(offset, endian);
  offset += 4;
  final polys = <ClipPolygon>[];
  for (var i = 0; i < polyCount; i++) {
    final pOrder = buf.getUint8(offset);
    offset += 1;
    final pEndian = pOrder == 1 ? Endian.little : Endian.big;
    final pType = buf.getUint32(offset, pEndian);
    offset += 4;
    if (pType != 3) {
      throw ArgumentError(
        'Not a Polygon WKB inside MultiPolygon (type=$pType)',
      );
    }
    final ringCount = buf.getUint32(offset, pEndian);
    offset += 4;
    List<Vec2>? outer;
    final holes = <List<Vec2>>[];
    for (var r = 0; r < ringCount; r++) {
      final pointCount = buf.getUint32(offset, pEndian);
      offset += 4;
      final ring = <Vec2>[];
      for (var pp = 0; pp < pointCount; pp++) {
        final lng = buf.getFloat64(offset, pEndian);
        offset += 8;
        final lat = buf.getFloat64(offset, pEndian);
        offset += 8;
        ring.add(Vec2(lng, lat));
      }
      if (r == 0) {
        outer = ring;
      } else {
        holes.add(ring);
      }
    }
    polys.add(ClipPolygon(outer: outer!, holes: holes));
  }
  return ClipMultiPolygon(polys);
}
