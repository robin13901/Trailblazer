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
/// Wave 4 (Plan 04-10-1-04) adds optional isolate parallelism via `workers`:
///
///   * `workers = 1` (default) runs the SERIAL fast-path unchanged. No
///     isolate spawn, no ReceivePort — preserves existing behavior for
///     tests and tiny fixtures.
///   * `workers > 1` spawns N worker isolates (see
///     `way_admin_join_isolate.dart`). Coordinator partitions Kfz way ids
///     round-robin, opens plain INSERT (fail-loud, NOT `OR IGNORE`) into
///     way_admin_raw under a single transaction, and drains WorkerBatch +
///     WorkerDone messages. Any worker error kills remaining peers,
///     ROLLBACKs, and throws `PipelineRuntimeError`.
///
/// See 04-05-PLAN.md Task 4 + 04-RESEARCH.md §7 for the join semantics;
/// 04-10-1-04-PLAN.md Task 2 + 04-10-1-RESEARCH.md §5 for the isolate
/// coordination contract.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:osm_pipeline/cli/errors.dart';
import 'package:osm_pipeline/cli/logger.dart';
import 'package:osm_pipeline/cli/progress_logger.dart';
import 'package:osm_pipeline/intersect/polygon_clip.dart';
import 'package:osm_pipeline/intersect/vec2.dart';
import 'package:osm_pipeline/intersect/way_admin_join_isolate.dart';
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
    required this.workers,
  });

  /// How many Kfz ways the orchestrator iterated.
  final int waysProcessed;

  /// How many way_admin_raw rows were INSERTed.
  final int rowsWritten;

  /// How many (way, admin_region) pairs passed the bbox pre-filter and were
  /// probed by the clipper. `-1` when running in parallel mode (workers > 1)
  /// where per-worker probe counts are not aggregated back to the
  /// coordinator to keep the SendPort payload minimal.
  final int candidatePairsProbed;

  /// Number of worker isolates used. `1` is the serial fast-path.
  final int workers;
}

/// Runs the segmented-intersection join over the scratch DB. Populates
/// `way_admin_raw` per the schema declared in `scratch_schema.dart`.
///
/// [workers] defaults to `1` (serial fast-path). Values > 1 spawn N worker
/// isolates that each process a partition of Kfz way ids. Values are
/// clamped to `[1, 16]`.
Future<WayAdminJoinStats> buildWayAdminJoin(
  ScratchDb scratch, {
  int workers = 1,
}) async {
  final n = workers < 1 ? 1 : (workers > 16 ? 16 : workers);
  if (n == 1) {
    return _runSerial(scratch);
  }
  return _runParallel(scratch, n);
}

// ---------------------------------------------------------------------------
// Serial fast-path (workers == 1). Preserved verbatim from pre-Wave-4 code
// except for the WayAdminJoinStats.workers field.
// ---------------------------------------------------------------------------

WayAdminJoinStats _runSerial(ScratchDb scratch) {
  final db = scratch.raw;

  final adminByLevel = <int, List<_AdminEntry>>{};
  for (final level in kAdminLevels) {
    adminByLevel[level] = _loadAdmins(db, level);
  }

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

  final totalKfz = db
      .select("SELECT COUNT(*) AS n FROM ways_raw WHERE source = 'kfz';")
      .first['n'] as int;
  final progress = ProgressLogger(
    'Stage D',
    total: totalKfz,
    unit: 'ways',
  );

  db.execute('BEGIN;');
  try {
    final wayRows = db.select(
      "SELECT id, node_ids FROM ways_raw WHERE source = 'kfz';",
    );
    for (final row in wayRows) {
      waysProcessed++;
      progress.tick();
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
  progress.finish();

  return WayAdminJoinStats(
    waysProcessed: waysProcessed,
    rowsWritten: rowsWritten,
    candidatePairsProbed: candidatePairsProbed,
    workers: 1,
  );
}

// ---------------------------------------------------------------------------
// Parallel path (workers > 1). See Plan 04-10-1-04 Task 2.
// ---------------------------------------------------------------------------

Future<WayAdminJoinStats> _runParallel(ScratchDb scratch, int workers) async {
  final db = scratch.raw;

  // 1. Deterministic partitioning input: ORDER BY id.
  final allWayIds = db
      .select("SELECT id FROM ways_raw WHERE source = 'kfz' ORDER BY id;")
      .map((r) => r['id'] as int)
      .toList(growable: false);
  final totalKfz = allWayIds.length;

  // 2. Round-robin partition. Worker i gets ids where index % N == i. This
  //    balances load if geometries cluster by contiguous id ranges.
  final partitions = List<List<int>>.generate(workers, (_) => <int>[]);
  for (var i = 0; i < allWayIds.length; i++) {
    partitions[i % workers].add(allWayIds[i]);
  }

  // 3. Coordinator receive port + progress logger (matches Wave 1 API).
  final rp = ReceivePort();
  final progress = ProgressLogger(
    'Stage D',
    total: totalKfz,
    unit: 'ways',
  );
  final swElapsed = Stopwatch()..start();

  // 4. Plain INSERT — NOT `OR IGNORE`. Partition-by-way_id guarantees no two
  //    workers touch the same way, so any PK collision indicates a real bug
  //    that MUST surface (fail-loud). See must_haves truth 5.
  final insert = db.prepare('''
INSERT INTO way_admin_raw
  (way_id, region_id, admin_level, fraction_start, fraction_end)
VALUES (?, ?, ?, ?, ?);
''');

  // 5. Spawn workers. Retain each Isolate handle so we can kill peers on
  //    any peer's failure. All three coordination messages route through the
  //    same SendPort (Dart's canonical `onError` + `onExit` semantics).
  final spawned = <Isolate>[];
  db.execute('BEGIN;');
  var rowsWritten = 0;
  var doneCount = 0;
  var exitCount = 0;
  final completedWorkers = <int>{};
  // Wave 5 crash telemetry: track per-worker batch count so we can log
  // every 100 batches on a per-worker basis and correlate the last
  // successful batch with any subsequent crash.
  final batchCountByWorker = <int, int>{};
  final completer = Completer<void>();
  // Set when the coordinator has resolved (via success or failure); the
  // message loop then only counts down onExit signals so we can drain the
  // ReceivePort until every isolate has terminated. This is what lets us
  // safely delete the scratch DB temp dir on Windows — sqlite3 FDs held
  // by workers must be released before the OS lets us unlink the file.
  final allExited = Completer<void>();

  void checkAllExited() {
    if (exitCount >= workers && !allExited.isCompleted) {
      allExited.complete();
    }
  }

  StreamSubscription<dynamic>? sub;

  Future<void> failFast(String message, [Object? cause, StackTrace? st]) async {
    // Idempotent: multiple onError messages may arrive; only the first
    // triggers rollback + throw.
    if (completer.isCompleted) return;
    // Use `beforeNextEvent` (NOT `immediate`) so peers get a chance to
    // finish their current statement + run their `finally` block (which
    // disposes the sqlite3 read-only Database handle). Immediate kills
    // leak native FDs on Windows, which then blocks the scratch temp-dir
    // teardown.
    for (final iso in spawned) {
      // beforeNextEvent (default) is used explicitly here — see doc above.
      // ignore: avoid_redundant_argument_values
      iso.kill(priority: Isolate.beforeNextEvent);
    }
    try {
      db.execute('ROLLBACK;');
    } on Object {
      // Ignore secondary errors on rollback — the primary failure is what
      // the user cares about.
    }
    completer.completeError(
      PipelineRuntimeError(message, cause: cause, stackTrace: st),
    );
  }

  sub = rp.listen((dynamic msg) {
    // onExit (null) must be counted even after the coordinator has
    // resolved — the outer try/finally awaits `allExited` to be sure
    // all worker sqlite3 FDs have been released before we let the caller
    // touch the scratch DB. Failing to count late-arriving nulls would
    // wedge the drain until its timeout expires.
    if (msg == null) {
      exitCount++;
      // Wave 5 crash telemetry: log every worker exit so we can see which
      // worker died and whether it had already signaled Done.
      final hadDone = completedWorkers.contains(exitCount - 1);
      Logger.info(
        'Stage D coord: onExit received '
        '(exitCount=$exitCount/$workers, doneCount=$doneCount, '
        'hadDoneBefore=$hadDone)',
      );
      if (exitCount > doneCount && !completer.isCompleted) {
        unawaited(
          failFast(
            'Stage D worker exited without WorkerDone signal '
            '(exits=$exitCount, dones=$doneCount)',
          ),
        );
      }
      checkAllExited();
      return;
    }
    if (completer.isCompleted) return;
    if (msg is WorkerBatch) {
      // Insert each tuple. Plain INSERT — a duplicate PK here surfaces as a
      // sqlite3 exception which cascades to failFast via the outer catch.
      // Wave 5 crash telemetry: log every N batches with running row count
      // and the last way_id we saw so we can pinpoint the crash boundary.
      batchCountByWorker[msg.workerId] =
          (batchCountByWorker[msg.workerId] ?? 0) + 1;
      final batchCount = batchCountByWorker[msg.workerId]!;
      int? lastWayIdInBatch;
      try {
        for (final t in msg.tuples) {
          lastWayIdInBatch = t.wayId;
          try {
            insert.execute([
              t.wayId,
              t.regionId,
              t.adminLevel,
              t.fractionStart,
              t.fractionEnd,
            ]);
          } on Object catch (e, st) {
            // Wave 5: log the exact way_id + region_id that triggered
            // the INSERT failure before rethrowing.
            Logger.error(
              'Stage D coord: INSERT failed for '
              'way_id=${t.wayId} region_id=${t.regionId} '
              'level=${t.adminLevel} fs=${t.fractionStart} '
              'fe=${t.fractionEnd} worker=${msg.workerId}: $e',
            );
            Logger.error('Stage D coord: INSERT stack: $st');
            rethrow;
          }
          rowsWritten++;
        }
      } on Object catch (e, st) {
        unawaited(
          failFast('INSERT into way_admin_raw failed: $e', e, st),
        );
        return;
      }
      // Every 100 batches, log worker-scoped state with running total.
      if (batchCount % 100 == 0) {
        Logger.info(
          'Stage D coord: WorkerBatch #$batchCount from worker=${msg.workerId} '
          '(rowsWritten=$rowsWritten, lastWayId=$lastWayIdInBatch, '
          'batchSize=${msg.tuples.length}, tickDelta=${msg.tickDelta})',
        );
      }
      // Forward tick delta into the progress logger. elapsedMs is
      // synthesized coordinator-side (WorkerBatch payload does not carry
      // it — Wave 1 §Task 1 truth allows this).
      progress.absorb(
        WorkerTick(msg.workerId, msg.tickDelta, swElapsed.elapsedMilliseconds),
      );
      return;
    }
    if (msg is WorkerDone) {
      // Wave 5 crash telemetry: log every WorkerDone immediately.
      Logger.info(
        'Stage D coord: WorkerDone from worker=${msg.workerId} '
        '(doneCount will become ${doneCount + 1}/$workers)',
      );
      if (completedWorkers.add(msg.workerId)) {
        doneCount++;
      }
      if (doneCount == workers) {
        Logger.info(
          'Stage D coord: all $workers workers done — issuing COMMIT '
          '(rowsWritten=$rowsWritten)',
        );
        try {
          db.execute('COMMIT;');
        } on Object catch (e, st) {
          unawaited(failFast('COMMIT failed: $e', e, st));
          return;
        }
        Logger.info('Stage D coord: COMMIT successful');
        if (!completer.isCompleted) completer.complete();
      }
      return;
    }
    if (msg is List && msg.length == 2) {
      // Dart canonical onError: [errorString, stackTraceString].
      final err = msg[0]?.toString() ?? '(unknown error)';
      final stkStr = msg[1]?.toString();
      // Wave 5 crash telemetry: log the full error + stack immediately.
      Logger.error(
        'Stage D coord: onError from worker isolate: $err',
      );
      if (stkStr != null) {
        Logger.error('Stage D coord: worker stack:\n$stkStr');
      }
      final st = stkStr == null ? null : StackTrace.fromString(stkStr);
      unawaited(
        failFast('Stage D worker crashed: $err', err, st),
      );
      return;
    }
    // Unknown message: log a warning, ignore (do not crash coordinator).
    // Wave 5 crash telemetry: log unknown message runtimeType with a small
    // preview of its toString so we can diagnose a corrupt port payload.
    final preview = msg.toString();
    final shortPreview = preview.length > 200
        ? '${preview.substring(0, 200)}...'
        : preview;
    Logger.warn(
      'Stage D coord: unknown message on port '
      '(runtimeType=${msg.runtimeType}, preview=$shortPreview)',
    );
  });

  try {
    for (var i = 0; i < workers; i++) {
      final iso = await Isolate.spawn<WorkerArgs>(
        wayAdminJoinWorkerEntry,
        WorkerArgs(
          workerId: i,
          scratchDbPath: scratch.file.path,
          wayIds: partitions[i],
          sendPort: rp.sendPort,
        ),
        // Plan truth 6: pass the full Isolate.spawn contract explicitly at
        // every spawn site (errorsAreFatal + onError + onExit routing).
        // ignore: avoid_redundant_argument_values
        errorsAreFatal: true,
        onError: rp.sendPort,
        onExit: rp.sendPort,
      );
      // errorsAreFatal defaults to true, but pass explicitly per plan
      // truth 6 (Isolate.spawn contract explicit at spawn site).
      spawned.add(iso);
    }
    try {
      await completer.future;
    } finally {
      // Drain onExit signals from all workers before we let the caller
      // touch the scratch DB again. On failure we've already sent
      // Isolate.kill; on success the workers' own return path yields
      // an onExit. Either way we must not delete the temp dir until
      // every worker's sqlite3 read-only handle has been released.
      //
      // Use a short timeout so a truly-hung isolate doesn't wedge the
      // coordinator indefinitely (this shouldn't happen — Dart guarantees
      // onExit on every isolate that has ever been alive).
      await allExited.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
    }
    progress.finish();
    return WayAdminJoinStats(
      waysProcessed: totalKfz,
      rowsWritten: rowsWritten,
      candidatePairsProbed: -1,
      workers: workers,
    );
  } finally {
    await sub.cancel();
    rp.close();
    insert.dispose();
  }
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
