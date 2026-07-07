/// Stage D worker isolate entry point.
///
/// Wave 4 (Plan 04-10-1-04) parallelises the way_admin join across N worker
/// isolates. This file defines the top-level worker function + marshalable
/// message shapes used by the coordinator in `way_admin_join.dart`.
///
/// Coordination contract (see 04-10-1-04-PLAN.md Task 2):
///
///   1. Coordinator loads Kfz way ids (ORDER BY id, deterministic) and
///      partitions them round-robin across N workers.
///   2. Each worker is spawned via
///      `Isolate.spawn(wayAdminJoinWorkerEntry, WorkerArgs(...),
///          errorsAreFatal: true,
///          onError: rp.sendPort,
///          onExit:  rp.sendPort)`.
///   3. Worker opens the scratch DB `read-only` inside its own isolate —
///      sqlite3 Database handles are NOT sendable across ports (research §5.2).
///   4. Worker streams [WorkerBatch] envelopes to the coordinator at flush
///      boundaries. Payload is a batch of [WayAdminResult] tuples ready for
///      INSERT into way_admin_raw, plus a per-worker tickDelta (ways
///      completed since last flush) that the coordinator absorbs into the
///      Wave 1 `ProgressLogger`.
///   5. Worker signals completion via [WorkerDone] as its final message
///      before returning (which then triggers the isolate's onExit → `null`
///      on the coordinator's ReceivePort).
///   6. On uncaught error, the isolate's `errorsAreFatal + onError`
///      contract causes Dart to post `[errorString, stackTraceString]`
///      (List of size 2) to the coordinator's ReceivePort. The coordinator
///      kills all remaining workers, ROLLBACKs the transaction, and throws
///      a `PipelineRuntimeError`.
///
/// The clip logic itself is unchanged from the serial path
/// (`polygon_clip.dart::clipLinestringToPolygon`) — this file only owns the
/// isolate-safe loop that feeds it.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:osm_pipeline/intersect/polygon_clip.dart';
import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:osm_pipeline/intersect/way_admin_join.dart'
    show decodeMultiPolygonWkb, kAdminLevels;
import 'package:osm_pipeline/scratch/scratch_db.dart' show decodeNodeIds;
import 'package:sqlite3/sqlite3.dart';

/// Marshalable args passed to a worker via [Isolate.spawn].
///
/// All fields must be either primitives, [String], [Uint8List], [SendPort],
/// or otherwise `dart:isolate`-copyable. `List<int>` of way ids is copyable.
class WorkerArgs {
  /// Create a worker args payload.
  const WorkerArgs({
    required this.workerId,
    required this.scratchDbPath,
    required this.wayIds,
    required this.sendPort,
    this.flushEvery = 5000,
  });

  /// Zero-based worker index (coordinator-assigned).
  final int workerId;

  /// Absolute filesystem path to the scratch SQLite DB. Worker opens it
  /// read-only inside its own isolate.
  final String scratchDbPath;

  /// Partition of way ids to process. Coordinator guarantees no two workers
  /// share a way id — plain INSERT (no OR IGNORE) into way_admin_raw is
  /// therefore safe under correct partitioning.
  final List<int> wayIds;

  /// Coordinator's ReceivePort SendPort. Worker posts [WorkerBatch] +
  /// [WorkerDone] here.
  final SendPort sendPort;

  /// Max tuples buffered before an out-of-band flush envelope is sent. Also
  /// bounds SendPort message size + coordinator INSERT batch size.
  final int flushEvery;
}

/// One row destined for `way_admin_raw`. Streamed from worker to coordinator
/// via [WorkerBatch].
class WayAdminResult {
  /// Create a result tuple.
  const WayAdminResult(
    this.wayId,
    this.regionId,
    this.adminLevel,
    this.fractionStart,
    this.fractionEnd,
  );

  /// Way id (matches `ways_raw.id`).
  final int wayId;

  /// Admin region id (matches `admin_regions_raw.region_id`).
  final int regionId;

  /// Admin level (2 / 4 / 6 / 8 / 9 / 10).
  final int adminLevel;

  /// Sub-segment fractional start along the way's polyline, in `[0, 1]`.
  final double fractionStart;

  /// Sub-segment fractional end along the way's polyline, in `[0, 1]`.
  final double fractionEnd;
}

/// Batched flush envelope: N result tuples plus a tick delta.
///
/// [tickDelta] is the number of ways this worker has completed since its
/// previous flush (or since spawn for the first envelope) — NOT cumulative.
/// The coordinator forwards this into `ProgressLogger.absorb` which
/// accumulates per-worker deltas into a single aggregate progress counter.
class WorkerBatch {
  /// Create a flush envelope.
  const WorkerBatch(this.workerId, this.tuples, this.tickDelta);

  /// Which worker produced this batch.
  final int workerId;

  /// Result tuples ready for INSERT into way_admin_raw.
  final List<WayAdminResult> tuples;

  /// Ways completed since the last envelope from this worker (delta, not
  /// cumulative).
  final int tickDelta;
}

/// Sentinel posted by a worker as its final message before returning.
///
/// Coordinator counts these; when it has received one from every worker it
/// commits the way_admin_raw transaction and closes the receive port.
class WorkerDone {
  /// Create a done sentinel.
  const WorkerDone(this.workerId);

  /// Which worker finished.
  final int workerId;
}

/// Top-level isolate entry point.
///
/// MUST remain a top-level function: Dart's `Isolate.spawn` on Windows only
/// accepts top-level or static entry points (research §5.2 pitfall). Do NOT
/// convert this to a class method or closure.
Future<void> wayAdminJoinWorkerEntry(WorkerArgs args) async {
  final db = sqlite3.open(args.scratchDbPath, mode: OpenMode.readOnly);
  try {
    // Load admin regions once per worker. Sending them across the SendPort
    // would double memory (each geometry is decoded MultiPolygon-WKB with
    // full ring vertex arrays); reading from scratch per-worker is O(N_regions)
    // per worker, cheap vs the per-way clip cost. Berlin: ~118 regions,
    // Germany: ~11 000 regions.
    final adminByLevel = <int, List<_AdminEntry>>{};
    for (final level in kAdminLevels) {
      adminByLevel[level] = _loadAdmins(db, level);
    }

    final nodeSelect =
        db.prepare('SELECT lat, lng FROM nodes_raw WHERE id = ?;');
    final wayFetch =
        db.prepare('SELECT node_ids FROM ways_raw WHERE id = ?;');
    try {
      final batch = <WayAdminResult>[];
      var tickDelta = 0;

      void flush() {
        if (batch.isEmpty && tickDelta == 0) return;
        args.sendPort.send(
          WorkerBatch(args.workerId, List<WayAdminResult>.of(batch), tickDelta),
        );
        batch.clear();
        tickDelta = 0;
      }

      for (final wayId in args.wayIds) {
        // Test-only poison sentinel (Plan 04-10-1-04 Task 3 worker-crash gate).
        // Negative sentinel way_ids never appear in real OSM data (OSM ids are
        // always positive int64). Any negative id here means a unit test is
        // exercising the coordinator's crash-escalation path.
        if (wayId < 0) {
          throw StateError(
            'poison way_id $wayId in worker ${args.workerId} '
            '(test-only crash sentinel)',
          );
        }
        final wayRows = wayFetch.select([wayId]);
        tickDelta++;
        if (wayRows.isEmpty) {
          if (batch.length >= args.flushEvery) flush();
          continue;
        }
        final nodeIds = decodeNodeIds(wayRows.first['node_ids'] as Uint8List);
        final linePoints = <Vec2>[];
        for (final nid in nodeIds) {
          final rs = nodeSelect.select([nid]);
          if (rs.isEmpty) continue;
          linePoints.add(
            Vec2(rs.first['lng'] as double, rs.first['lat'] as double),
          );
        }
        if (linePoints.length < 2) {
          if (batch.length >= args.flushEvery) flush();
          continue;
        }

        final wayBbox = _bboxOfLine(linePoints);

        for (final level in kAdminLevels) {
          final admins = adminByLevel[level]!;
          for (final admin in admins) {
            if (!_bboxOverlap(wayBbox, admin.bbox)) continue;
            final subs = clipLinestringToPolygon(linePoints, admin.geometry);
            for (final sub in subs) {
              batch.add(
                WayAdminResult(
                  wayId,
                  admin.regionId,
                  level,
                  sub.fractionStart,
                  sub.fractionEnd,
                ),
              );
            }
          }
        }
        if (batch.length >= args.flushEvery) flush();
      }

      // Final drain.
      flush();
    } finally {
      nodeSelect.dispose();
      wayFetch.dispose();
    }
  } finally {
    db.dispose();
  }
  args.sendPort.send(WorkerDone(args.workerId));
}

// ---------------------------------------------------------------------------
// Worker-private helpers — inlined per Plan 04-10-1-04 Task 1 §Note.
// Duplicated intentionally with the serial path in `way_admin_join.dart` to
// keep the private-scope hygiene simple (no shared library-private surface).
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
