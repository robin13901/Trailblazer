// Phase 5 (Plan 05-06): Long-lived matcher isolate.
//
// Lifecycle:
//   * matcherIsolateProvider creates MatcherIsolate() and calls start().
//   * start() spawns _matcherWorker via Isolate.spawn.
//   * match(tripId, fixes, ways) sends a MatchJob over the worker SendPort and
//     returns a Future<MatchResult> keyed by jobSeq.
//   * cancel(tripId) sends a _CancelMessage; the worker consults its cancel-set
//     BEFORE starting each queued job. In-flight cancellation is out of scope
//     for v1 — a job already in HmmMatcher.match() runs to completion. The
//     caller (coordinator 05-07) discards the result.
//     TODO(mid-flight-cancel): add per-frame cancel-set check inside
//     HmmMatcher if golden corpus exposes excessively long jobs.
//   * dispose() kills the isolate and closes the receive port.
//
// No Drift, no Flutter imports in this file or its worker entry function.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:auto_explore/features/matching/data/match_job.dart';
import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:auto_explore/features/matching/data/tile_way_pipeline.dart';
import 'package:auto_explore/features/matching/domain/gps_fix.dart';
import 'package:auto_explore/features/matching/domain/hmm_matcher.dart';
import 'package:auto_explore/features/matching/domain/match_result.dart';
import 'package:logging/logging.dart';

/// Long-lived isolate wrapping [HmmMatcher] for off-main-thread matching.
///
/// Usage:
/// ```dart
/// final iso = MatcherIsolate();
/// await iso.start();
/// final result = await iso.match(tripId: 1, fixes: fixes, ways: ways);
/// iso.dispose();
/// ```
///
/// Multiple `match()` calls may be in flight concurrently; each is keyed by
/// an internal sequence number and resolved independently. The worker isolate
/// processes jobs serially (single-threaded), so "concurrent" means multiple
/// pending Futures, not parallel execution.
class MatcherIsolate {
  MatcherIsolate();

  final _log = Logger('matcher_isolate');

  Isolate? _isolate;
  SendPort? _workerPort;
  final _mainPort = ReceivePort();

  /// Maps jobSeq → Completer awaiting the worker's reply.
  final _pending = <int, Completer<MatchResult>>{};

  /// Maps jobSeq → caller-supplied progress callback. Populated by [match]
  /// when `onProgress` is non-null; invoked when a [MatchJobProgress] for the
  /// job arrives; removed on completion/error/cancel (same lifecycle as
  /// [_pending]).
  final _progress = <int, void Function(int processed, int total)>{};

  int _seq = 0;
  bool _started = false;

  /// In-flight start future — single-flight guard. `_started` only flips true
  /// AFTER `await ready.future` completes, so two callers racing `start()`
  /// during that async gap would both pass the `_started` check and each call
  /// `_mainPort.listen()` — the second throws "Stream has already been listened
  /// to". Sharing one future collapses concurrent starts into one. (The
  /// provider fires start() at construction; the rematch migration also awaits
  /// start() — these two raced on cold start, 2026-07-10.)
  Future<void>? _starting;

  /// Spawn the worker isolate and wait until it is ready to accept jobs.
  ///
  /// Idempotent — calling start() when already started is a no-op, and
  /// concurrent calls share a single in-flight spawn.
  Future<void> start() {
    if (_started) return Future<void>.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final ready = Completer<SendPort>();

    _mainPort.listen((msg) {
      if (msg is SendPort) {
        // First message from the worker: its SendPort for job dispatch.
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is MatchJobProgress) {
        // In-flight progress update: forward to the caller's callback (if any).
        // Progress messages flow on the same mainPort as MatchJobReply.
        final cb = _progress[msg.jobSeq];
        cb?.call(msg.processed, msg.total);
        return;
      }
      if (msg is MatchJobReply) {
        final comp = _pending.remove(msg.jobSeq);
        _progress.remove(msg.jobSeq);
        if (comp == null) return; // stale reply after dispose
        if (msg.cancelled) {
          // The worker cancelled this job; complete with the exception.
          // Note: we pass tripId = -1 here because the worker does not echo
          // the tripId in the reply. Callers check the Future's error type,
          // not the tripId inside it. If the coordinator needs the tripId it
          // can capture it from the enclosing context.
          comp.completeError(const MatcherCancelledException(-1));
        } else if (msg.error != null) {
          comp.completeError(msg.error!);
        } else if (msg.result != null) {
          comp.complete(msg.result!);
        }
      }
    });

    _isolate = await Isolate.spawn(_matcherWorker, _mainPort.sendPort);
    _workerPort = await ready.future;
    _started = true;
    _starting = null;
    _log.info('matcher isolate started');
  }

  /// Enqueue a matching job and return a [Future] that resolves with the
  /// [MatchResult] when the worker replies.
  ///
  /// [gzippedTiles] + [tileBboxes] are the raw cached Overpass payloads for the
  /// trip's bbox; the worker gunzips + parses + dedupes + bbox-clips +
  /// corridor-filters them tile-by-tile (Plan 06-07 re-drive #3) before running
  /// the matcher, so no way decoding/parsing happens on the main isolate.
  ///
  /// Throws [StateError] if [start] has not been called.
  ///
  /// Multiple calls may be in flight concurrently; each future is
  /// independently resolved via the jobSeq correlation key.
  ///
  /// [onProgress], when non-null, is invoked on the main isolate with
  /// `(processed, total)` each time the worker emits a [MatchJobProgress] for
  /// this job (`total` is the fix count). The callback is cleaned up
  /// automatically when the job completes, errors, or is cancelled.
  Future<MatchResult> match({
    required int tripId,
    required List<GpsFix> fixes,
    required List<Uint8List> gzippedTiles,
    required List<LatLonBbox> tileBboxes,
    void Function(int processed, int total)? onProgress,
  }) {
    if (!_started) throw StateError('MatcherIsolate not started');
    final seq = ++_seq;
    final job = MatchJob(
      jobSeq: seq,
      tripId: tripId,
      fixes: fixes,
      gzippedTiles: gzippedTiles,
      tileBboxes: tileBboxes,
    );
    final comp = Completer<MatchResult>();
    _pending[seq] = comp;
    if (onProgress != null) _progress[seq] = onProgress;
    _workerPort!.send(job);
    return comp.future;
  }

  /// Request cancellation of any pending job for [tripId].
  ///
  /// v1 behaviour: the worker consults the cancel-set BEFORE popping the
  /// next job from its internal queue. A job already inside
  /// `HmmMatcher.match()` completes normally; its result is discarded by
  /// the coordinator (05-07).
  void cancel(int tripId) {
    _log.info('cancel requested for tripId=$tripId');
    _workerPort?.send(_CancelMessage(tripId));
  }

  /// Kill the worker isolate and release the receive port.
  ///
  /// After `dispose()` any pending [Future]s remain in-flight but will
  /// never resolve (the [ReceivePort] is closed). Callers must ensure they
  /// do not await those futures after disposal.
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _mainPort.close();
    _progress.clear();
    _started = false;
    _log.info('matcher isolate disposed');
  }
}

// ---------------------------------------------------------------------------
// Internal message type — worker side only
// ---------------------------------------------------------------------------

/// Sent from the main isolate to the worker to request cancellation of all
/// queued jobs for [tripId].
class _CancelMessage {
  const _CancelMessage(this.tripId);

  final int tripId;
}

// ---------------------------------------------------------------------------
// Worker entry function
//
// MUST be a top-level or static function for Isolate.spawn on all platforms.
// No Drift, no Flutter imports below this line.
// ---------------------------------------------------------------------------

void _matcherWorker(SendPort mainPort) {
  final workerPort = ReceivePort();
  // Send our own SendPort back to the main isolate so it can dispatch jobs.
  mainPort.send(workerPort.sendPort);

  const matcher = HmmMatcher();

  /// tripIds queued for cancellation (consulted before starting each job).
  final cancelled = <int>{};

  workerPort.listen((msg) {
    if (msg is _CancelMessage) {
      cancelled.add(msg.tripId);
      return;
    }
    if (msg is MatchJob) {
      if (cancelled.remove(msg.tripId)) {
        // The job was cancelled before we started processing it.
        mainPort.send(MatchJobReply(jobSeq: msg.jobSeq, cancelled: true));
        return;
      }
      try {
        // Plan 06-07 (re-drive #3): decode + parse + dedupe + bbox-clip +
        // corridor-filter the raw tiles HERE, in the worker, tile-by-tile —
        // never on the main isolate. Peak memory is one tile's ways + the
        // corridor survivors, not the full bbox way-set.
        final ways = parseAndFilterTiles(
          gzippedTiles: msg.gzippedTiles,
          tileBboxes: msg.tileBboxes,
          fixes: msg.fixes,
        );
        final result = matcher.match(
          fixes: msg.fixes,
          ways: ways,
          onProgress: (processed, total) {
            mainPort.send(
              MatchJobProgress(
                jobSeq: msg.jobSeq,
                processed: processed,
                total: total,
              ),
            );
          },
        );
        mainPort.send(MatchJobReply(jobSeq: msg.jobSeq, result: result));
      } on Object catch (e) {
        mainPort.send(MatchJobReply(jobSeq: msg.jobSeq, error: e));
      }
    }
  });
}
