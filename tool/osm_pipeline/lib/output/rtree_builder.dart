/// R-Tree builder for ways in the final osm.sqlite artifact.
///
/// Encapsulates the per-segment vs per-way granularity decision. Per-segment
/// (default) keeps candidate bboxes tight so Phase 5's `findWaysNear(lat, lng,
/// radius)` doesn't flood the candidate set on long autobahn segments; per-way
/// stays as a fallback if the 04-05 Berlin measurement projects the
/// per-segment rtree over 150 MB for full Germany (04-RESEARCH §8).
///
/// The builder appends one row per bbox to both `ways_rtree` (the r*tree
/// virtual table) and `ways_rtree_lookup` (the way_id + segment_idx map).
/// It assigns rtree ids sequentially — starts at 1 and increments on every
/// insert.
library;

import 'dart:io';

import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:sqlite3/sqlite3.dart';

/// Granularity of the ways R-Tree.
enum RtreeGranularity {
  /// One rtree row per two-point segment of every way. Default.
  perSegment,

  /// One rtree row per way, using the full-way bbox. Fallback when
  /// per-segment blows the SC4 osm.sqlite budget.
  perWay,
}

/// Result summary from an [RtreeBuilder].
class RtreeBuildStats {
  /// Create a stats record.
  const RtreeBuildStats({
    required this.waysProcessed,
    required this.rowsWritten,
    required this.granularity,
  });

  /// Number of ways passed to [RtreeBuilder.buildForWay].
  final int waysProcessed;

  /// Number of rows written into ways_rtree + ways_rtree_lookup.
  final int rowsWritten;

  /// Granularity used by the builder.
  final RtreeGranularity granularity;
}

/// Builds the ways_rtree virtual table row-by-row.
///
/// The builder owns prepared statements for the r*tree + lookup inserts.
/// Callers must invoke [dispose] when done (or rely on the `try/finally`
/// in `OsmSqliteWriter.write`).
class RtreeBuilder {
  /// Create a builder targeting `db` at `granularity`.
  RtreeBuilder(this._db, this.granularity) {
    _insertRtree = _db.prepare(
      'INSERT INTO ways_rtree (id, min_lat, max_lat, min_lng, max_lng) '
      'VALUES (?, ?, ?, ?, ?);',
    );
    _insertLookup = _db.prepare(
      'INSERT INTO ways_rtree_lookup (rtree_id, way_id, segment_idx) '
      'VALUES (?, ?, ?);',
    );
  }

  final Database _db;

  /// Granularity chosen by the caller.
  final RtreeGranularity granularity;

  late final PreparedStatement _insertRtree;
  late final PreparedStatement _insertLookup;

  int _nextId = 1;
  int _rowsWritten = 0;
  int _waysProcessed = 0;

  /// Reads the 04-05 measurement recommendation to decide granularity.
  ///
  /// Returns `RtreeGranularity.perWay` iff the file mentions `per-way`
  /// (case-sensitive). Missing file or no matching phrase → default
  /// `RtreeGranularity.perSegment`.
  static Future<RtreeGranularity> loadFromMeasurement(
    File measurementMd,
  ) async {
    if (!measurementMd.existsSync()) return RtreeGranularity.perSegment;
    final txt = await measurementMd.readAsString();
    if (RegExp('per-way|per_way').hasMatch(txt)) {
      return RtreeGranularity.perWay;
    }
    return RtreeGranularity.perSegment;
  }

  /// Emits R-Tree rows for [wayId] with polyline [line]. Returns the number
  /// of rows written (0 when the line is degenerate or all segments have
  /// zero length).
  int buildForWay(int wayId, List<Vec2> line) {
    _waysProcessed++;
    if (line.length < 2) return 0;
    switch (granularity) {
      case RtreeGranularity.perSegment:
        return _buildPerSegment(wayId, line);
      case RtreeGranularity.perWay:
        return _buildPerWay(wayId, line);
    }
  }

  int _buildPerSegment(int wayId, List<Vec2> line) {
    var written = 0;
    for (var i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];
      if (a.equalsCoord(b)) continue; // zero-length segment.
      final bb = _bboxOfPair(a, b);
      final id = _nextId++;
      _insertRtree.execute([id, bb.minLat, bb.maxLat, bb.minLng, bb.maxLng]);
      _insertLookup.execute([id, wayId, i]);
      written++;
      _rowsWritten++;
    }
    return written;
  }

  int _buildPerWay(int wayId, List<Vec2> line) {
    final bb = _bboxOfLine(line);
    final id = _nextId++;
    _insertRtree.execute([id, bb.minLat, bb.maxLat, bb.minLng, bb.maxLng]);
    _insertLookup.execute([id, wayId, -1]);
    _rowsWritten++;
    return 1;
  }

  /// Total rows written across all [buildForWay] calls.
  int get rowsWritten => _rowsWritten;

  /// Total ways processed.
  int get waysProcessed => _waysProcessed;

  /// Snapshot the current run's stats.
  RtreeBuildStats snapshot() => RtreeBuildStats(
        waysProcessed: _waysProcessed,
        rowsWritten: _rowsWritten,
        granularity: granularity,
      );

  /// Disposes the builder's prepared statements.
  void dispose() {
    _insertRtree.dispose();
    _insertLookup.dispose();
  }
}

class _Bbox {
  const _Bbox({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;
}

_Bbox _bboxOfPair(Vec2 a, Vec2 b) => _Bbox(
      minLat: a.lat < b.lat ? a.lat : b.lat,
      maxLat: a.lat > b.lat ? a.lat : b.lat,
      minLng: a.lng < b.lng ? a.lng : b.lng,
      maxLng: a.lng > b.lng ? a.lng : b.lng,
    );

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
  return _Bbox(
    minLat: minLat,
    maxLat: maxLat,
    minLng: minLng,
    maxLng: maxLng,
  );
}
