// Long-lived coverage-compute isolate (2026-07-22; reworked 2026-07-25).
//
// Moves the heavy STAGE-1 attribution (tile gunzip+parse + polyline-vs-polygon
// clip against the ~20K-polygon admin index) OFF the Flutter main isolate so
// the UI stays smooth while a trip's new ways are attributed. Mirrors
// MatcherIsolate, with a TWO-PHASE startup: after the SendPort handshake, the
// main isolate reads the admin + totals asset bytes (rootBundle is unreachable
// from a spawned isolate) and ships them once via [CoverageLoadBundle]; the
// worker parses+indexes them and replies [CoverageReady] before start()
// completes. The polygon index lives ONLY inside the worker and is NEVER sent
// back — only the small [WayRegionAttributionRow] list crosses the boundary
// (this is what avoids the 2026-07-10 OOM, which was a large index copied over
// the SendPort).
//
// No Drift, no Flutter imports in this file or its worker entry function.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:auto_explore/features/admin/data/admin_bundle_parser.dart';
import 'package:auto_explore/features/admin/data/admin_region.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/regions/data/coverage_attribution.dart';
import 'package:auto_explore/features/regions/data/coverage_compute_job.dart';
import 'package:logging/logging.dart';

/// Loads the raw gzipped admin bundle bytes on the MAIN isolate (rootBundle is
/// unreachable off-isolate). Injected so tests can supply in-memory bytes.
typedef AdminBytesLoader = Future<Uint8List> Function();

/// Loads the raw gzipped region-totals bytes on the MAIN isolate, or null when
/// the deferred asset is absent. Injected so tests can supply in-memory bytes.
typedef TotalsBytesLoader = Future<Uint8List?> Function();

/// Long-lived isolate wrapping [computeCoverageAttribution] for off-main-thread
/// STAGE-1 clip.
///
/// Usage:
/// ```dart
/// final iso = CoverageComputeIsolate(
///   loadAdminBytes: loadAdminBundleBytes,
///   loadTotalsBytes: loadRegionTotalsBytes,
/// );
/// await iso.start(); // spawns, ships bundle bytes, parses index in worker
/// final rows = await iso.computeAttribution(
///   gzippedTiles: ..., tileBboxes: ..., alreadyAttributedWayIds: ...);
/// iso.dispose();
/// ```
///
/// `start()` is idempotent + single-flight. Multiple `computeAttribution` calls
/// may be in flight; each is keyed by an internal sequence number and resolved
/// independently. The worker processes jobs serially.
class CoverageComputeIsolate {
  CoverageComputeIsolate({
    required AdminBytesLoader loadAdminBytes,
    required TotalsBytesLoader loadTotalsBytes,
  })  : _loadAdminBytes = loadAdminBytes,
        _loadTotalsBytes = loadTotalsBytes;

  final AdminBytesLoader _loadAdminBytes;
  final TotalsBytesLoader _loadTotalsBytes;

  final _log = Logger('coverage_compute_isolate');

  Isolate? _isolate;

  /// Worker's SendPort — null until the startup handshake completes. Kept
  /// nullable (not `late`) so a job enqueued before `start()` fails the
  /// `_started` guard rather than throwing a LateInitializationError.
  SendPort? _workerPort;
  final _mainPort = ReceivePort();

  /// jobSeq → Completer awaiting the worker's reply.
  final _pending = <int, Completer<List<WayRegionAttributionRow>>>{};

  int _seq = 0;
  bool _started = false;

  /// In-flight start future — single-flight guard (same rationale as
  /// MatcherIsolate: `_started` only flips true AFTER the async startup gap,
  /// and `_mainPort` can be listened to exactly once).
  Future<void>? _starting;

  /// True once `_mainPort.listen` has been attached. A ReceivePort can be
  /// listened to exactly once, so a retried `_start()` (after a failed first
  /// attempt — e.g. rootBundle unavailable in a bare-container test) must NOT
  /// re-listen. The listener resolves against the instance-level completers
  /// below, which each `_start()` recreates.
  bool _listening = false;
  Completer<SendPort>? _portReady;
  Completer<void>? _ready;

  /// Spawn the worker, ship the bundle bytes, and wait until the worker has
  /// parsed its polygon index and is ready to accept jobs.
  ///
  /// Idempotent; concurrent calls share a single in-flight startup.
  Future<void> start() {
    if (_started) return Future<void>.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    try {
      final portReady = _portReady = Completer<SendPort>();
      final ready = _ready = Completer<void>();

      // Attach the listener exactly once; it resolves against whichever
      // instance-level completers the CURRENT _start() created.
      if (!_listening) {
        _listening = true;
        _mainPort.listen((msg) {
          if (msg is SendPort) {
            final c = _portReady;
            if (c != null && !c.isCompleted) c.complete(msg);
            return;
          }
          if (msg is CoverageReady) {
            final c = _ready;
            if (c != null && !c.isCompleted) c.complete();
            return;
          }
          if (msg is CoverageComputeReply) {
            final comp = _pending.remove(msg.jobSeq);
            if (comp == null) return; // stale reply after dispose
            if (msg.error != null) {
              comp.completeError(msg.error!);
            } else if (msg.rows != null) {
              comp.complete(msg.rows!);
            }
          }
        });
      }

      _isolate = await Isolate.spawn(_coverageWorker, _mainPort.sendPort);
      _workerPort = await portReady.future;

      // Read the asset bytes on the MAIN isolate and ship them once.
      final adminBytes = await _loadAdminBytes();
      final totalsBytes = await _loadTotalsBytes();
      _workerPort!.send(
        CoverageLoadBundle(adminBytes: adminBytes, totalsBytes: totalsBytes),
      );

      await ready.future; // worker finished parsing + indexing
      _started = true;
      _log.info('coverage compute isolate started');
      // Catch EVERYTHING (including the "Binding not initialized" LateError from
      // rootBundle in a bare-container unit test): start() is fired
      // fire-and-forget by the provider, so an uncaught error here would fail
      // an unrelated test / crash startup. On failure we tear the half-spawned
      // isolate down and reset so a later start() (e.g. the first recompute's
      // awaited start()) can retry cleanly.
    } catch (e, st) {
      _log.warning('coverage compute isolate start failed: $e', e, st);
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _workerPort = null;
      _started = false;
      rethrow;
    } finally {
      _starting = null;
    }
  }

  /// Enqueue a STAGE-1 attribution job; resolves with the durable
  /// [WayRegionAttributionRow]s for the NEW ways in the payload.
  ///
  /// Throws [StateError] if [start] has not completed.
  Future<List<WayRegionAttributionRow>> computeAttribution({
    required List<Uint8List> gzippedTiles,
    required List<LatLonBbox> tileBboxes,
    Set<int> alreadyAttributedWayIds = const {},
  }) {
    if (!_started) throw StateError('CoverageComputeIsolate not started');
    final seq = ++_seq;
    final job = CoverageComputeJob(
      jobSeq: seq,
      gzippedTiles: gzippedTiles,
      tileBboxes: tileBboxes,
      alreadyAttributedWayIds: alreadyAttributedWayIds,
    );
    final comp = Completer<List<WayRegionAttributionRow>>();
    _pending[seq] = comp;
    _workerPort!.send(job);
    return comp.future;
  }

  /// Kill the worker isolate and release the receive port. Pending futures
  /// remain unresolved after dispose (port closed) — callers must not await
  /// them.
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _mainPort.close();
    _started = false;
    _log.info('coverage compute isolate disposed');
  }
}

// ---------------------------------------------------------------------------
// Worker entry function
//
// MUST be top-level for Isolate.spawn on all platforms.
// No Drift, no Flutter imports below this line.
// ---------------------------------------------------------------------------

void _coverageWorker(SendPort mainPort) {
  final workerPort = ReceivePort();
  // Send our own SendPort back to the main isolate (readiness handshake #1).
  mainPort.send(workerPort.sendPort);

  // The resident polygon index — parsed ONCE from the LoadBundle message and
  // retained across all jobs. Never sent back over the port.
  Map<int, List<AdminRegion>>? regionsByLevel;

  workerPort.listen((msg) {
    if (msg is CoverageLoadBundle) {
      final regions = parseAdminBundle(msg.adminBytes);
      regionsByLevel = bucketRegionsByLevel(regions);
      // totalsBytes is intentionally ignored here — real per-region totals are
      // resolved on the MAIN isolate in STAGE 2 (RegionTotalsLookup). The field
      // is retained on the bundle only for loader-wiring symmetry.
      // Readiness handshake #2: index is live, accept jobs.
      mainPort.send(const CoverageReady());
      return;
    }
    if (msg is CoverageComputeJob) {
      try {
        final index = regionsByLevel;
        if (index == null) {
          // Job arrived before the bundle was loaded — should not happen given
          // the two-phase startup, but fail loudly rather than silently empty.
          throw StateError('CoverageComputeJob before CoverageLoadBundle');
        }
        final rows = computeCoverageAttribution(
          regionsByLevel: index,
          gzippedTiles: msg.gzippedTiles,
          tileBboxes: msg.tileBboxes,
          alreadyAttributedWayIds: msg.alreadyAttributedWayIds,
        );
        mainPort.send(
          CoverageComputeReply(jobSeq: msg.jobSeq, rows: rows),
        );
      } on Object catch (e) {
        mainPort.send(CoverageComputeReply(jobSeq: msg.jobSeq, error: e));
      }
    }
  });
}
