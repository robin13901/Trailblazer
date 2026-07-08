---
id: 05-06
phase: 05-overpass-matcher-and-golden-corpus
plan: 06
type: execute
wave: 3
depends_on: [05-05]
files_modified:
  - lib/features/matching/data/matcher_isolate.dart
  - lib/features/matching/data/match_job.dart
  - lib/features/matching/data/matching_providers.dart
  - test/features/matching/data/matcher_isolate_test.dart
autonomous: true
requirements: [MMT-01, MMT-03, MMT-08]

must_haves:
  truths:
    - "`MatcherIsolate.start()` spawns exactly one long-lived worker isolate via `Isolate.spawn`; the isolate stays warm across multiple `match()` calls (MMT-01)."
    - "`MatcherIsolate.match(MatchJob)` returns a `Future<MatchResult>` that resolves after the isolate replies; multiple pending jobs are keyed by an internal seq so concurrent futures resolve to their correct results."
    - "`MatcherIsolate.cancel(int tripId)` sends a cancel message; if the worker is currently processing that tripId, its pending `match()` future completes with a `MatcherCancelledException` (MMT-08)."
    - "The worker isolate imports NO Drift and NO Flutter — verified via grep against `lib/features/matching/data/matcher_isolate.dart` (the worker entry point + HmmMatcher are pure Dart)."
    - "`MatchJob` payload is Sendable: only ints, doubles, strings, DateTimes, `List<LatLng>` (which is 2 doubles per entry), and enum names — no closures, no futures, no Drift companions."
    - "`matcherIsolateProvider` in `matching_providers.dart` is a Riverpod `Provider<MatcherIsolate>` that calls `.start()` on creation and `.dispose()` on `ref.onDispose`."
    - "The isolate can be spawned + roundtripped inside a `flutter_test` — a smoke test spawns, sends one job, awaits the result, and disposes cleanly."
  artifacts:
    - path: "lib/features/matching/data/match_job.dart"
      provides: "MatchJob (tripId, fixes, ways) + MatchJobReply + MatcherCancelledException + serialization helpers so tests can build a job without importing SendPort details."
      min_lines: 60
    - path: "lib/features/matching/data/matcher_isolate.dart"
      provides: "MatcherIsolate class with start/match/cancel/dispose; static _matcherEntry(SendPort) worker entry point."
      min_lines: 180
    - path: "test/features/matching/data/matcher_isolate_test.dart"
      provides: "Isolate roundtrip smoke test + cancellation test + concurrent-jobs correctness test."
      min_lines: 120
  key_links:
    - from: "lib/features/matching/data/matcher_isolate.dart"
      to: "lib/features/matching/domain/hmm_matcher.dart"
      via: "worker entry function calls HmmMatcher().match() on decoded MatchJob"
      pattern: "HmmMatcher\\(\\)|HmmMatcher\\("
    - from: "lib/features/matching/data/matching_providers.dart"
      to: "lib/features/matching/data/matcher_isolate.dart"
      via: "matcherIsolateProvider creates + starts + disposes the isolate"
      pattern: "matcherIsolateProvider|MatcherIsolate"
---

## Goal

Wrap the pure-Dart `HmmMatcher` (05-05) in a long-lived, warm `MatcherIsolate` that the coordinator (05-07) will enqueue jobs into. The isolate stays alive for the app's lifetime, accepts multiple concurrent jobs, and supports cooperative cancellation via `MatcherIsolate.cancel(tripId)` (MMT-08).

## Context

- Research §4 has the full isolate protocol (main-side class + worker entry function + cancel-set on the worker side).
- Wire the isolate into the existing `matching_providers.dart`. Add a new `matcherIsolateProvider` — do not touch the existing 04-15 providers.
- The worker isolate cannot use Drift (WAL connections are per-isolate); it also should not import Flutter. Verify with grep in success criteria.
- Data sent across the isolate boundary is a `MatchJob` with `List<GpsFix>` and `List<WayCandidate>`. `LatLng` (from `maplibre_gl`) is a plain 2-double class — Sendable. `DateTime` is Sendable. Enums send by value. No transformation needed.
- Cancellation is cooperative: the worker checks a `Set<int> _cancelledTripIds` between Viterbi frames. Because 05-04's decoder is a tight synchronous loop over `fixes`, we insert the check at a lower granularity — every N=200 fixes — via a callback hook. If that's too invasive, an acceptable v1 is: cancel-set is consulted only BEFORE each job starts (i.e., cancellation during a job is a no-op; the job completes, and the caller discards the result). Document whichever choice lands.
  - **Recommended v1 path:** cancel-set is consulted BEFORE `HmmMatcher().match()` runs. Because trip matches take ~2-5 s on real traces, this is acceptable for MVP. In-flight cancellation can be added as follow-up if the golden corpus (05-08) exposes long-running jobs.
- Concurrent jobs: each job gets a unique `int jobSeq`; the main-side `Map<int, Completer<MatchResult>>` correlates replies. The worker processes jobs serially (a queue on the worker side) — the isolate is single-threaded, so "concurrent" here means multiple pending futures, not parallel matching.
- `Isolate.spawn` requires the worker entry to be a top-level or static function. Author it as a top-level function `_matcherWorker(SendPort mainPort)` in the same file.
- Test conventions: `flutter test` runs a single-VM isolate; spawning workers is supported.

## Tasks

<task type="auto">
  <name>Task 1: MatchJob + MatchJobReply + MatcherCancelledException</name>
  <files>
    lib/features/matching/data/match_job.dart
  </files>
  <intent>Sendable payload types + the cancellation exception. Kept in a small file so the isolate entry function's imports are minimal.</intent>
  <action>
    ```dart
    // Phase 5 (Plan 05-06): Sendable payloads for the matcher isolate.
    //
    // Every field on MatchJob / MatchJobReply must be trivially copyable
    // across an isolate boundary via SendPort — primitives, DateTime, and
    // plain Dart classes containing only those (no closures, no futures,
    // no Drift types).

    import 'package:auto_explore/features/matching/domain/gps_fix.dart';
    import 'package:auto_explore/features/matching/domain/match_result.dart';
    import 'package:auto_explore/features/matching/domain/way_candidate.dart';
    import 'package:meta/meta.dart';

    @immutable
    class MatchJob {
      const MatchJob({
        required this.jobSeq,
        required this.tripId,
        required this.fixes,
        required this.ways,
      });

      final int jobSeq;
      final int tripId;
      final List<GpsFix> fixes;
      final List<WayCandidate> ways;
    }

    @immutable
    class MatchJobReply {
      const MatchJobReply({
        required this.jobSeq,
        this.result,
        this.error,
        this.cancelled = false,
      });

      final int jobSeq;
      final MatchResult? result;
      final Object? error;
      final bool cancelled;
    }

    class MatcherCancelledException implements Exception {
      const MatcherCancelledException(this.tripId);
      final int tripId;

      @override
      String toString() => 'MatcherCancelledException(tripId=$tripId)';
    }
    ```
  </action>
  <verify>
    ```bash
    flutter analyze
    ```
    Analyze clean.
  </verify>
  <done>Value types compile clean; no Drift/Flutter/isolate imports.</done>
</task>

<task type="auto">
  <name>Task 2: MatcherIsolate class + worker entry function</name>
  <files>
    lib/features/matching/data/matcher_isolate.dart
    lib/features/matching/data/matching_providers.dart
    test/features/matching/data/matcher_isolate_test.dart
  </files>
  <intent>Spawn + protocol + cancellation + provider.</intent>
  <action>
    **`lib/features/matching/data/matcher_isolate.dart`:**
    ```dart
    // Phase 5 (Plan 05-06): Long-lived matcher isolate.
    //
    // Lifecycle:
    //   * matcherIsolateProvider creates MatcherIsolate() and calls start().
    //   * start() spawns _matcherWorker via Isolate.spawn.
    //   * match(job) sends the job over the worker SendPort and returns a
    //     Future<MatchResult> keyed by jobSeq.
    //   * cancel(tripId) adds the tripId to a cancel-set the worker reads
    //     before starting each queued job. In-flight cancellation is out of
    //     scope for v1 — jobs are ~2-5 s.
    //   * dispose() kills the isolate.

    import 'dart:async';
    import 'dart:isolate';
    import 'package:auto_explore/features/matching/data/match_job.dart';
    import 'package:auto_explore/features/matching/domain/hmm_matcher.dart';
    import 'package:auto_explore/features/matching/domain/match_result.dart';
    import 'package:logging/logging.dart';

    class MatcherIsolate {
      MatcherIsolate();

      final _log = Logger('matcher_isolate');
      Isolate? _isolate;
      SendPort? _workerPort;
      final _mainPort = ReceivePort();
      final _pending = <int, Completer<MatchResult>>{};
      final _cancelledTripIds = <int, int>{}; // tripId -> jobSeq
      int _seq = 0;
      bool _started = false;

      Future<void> start() async {
        if (_started) return;
        final ready = Completer<SendPort>();
        _mainPort.listen((msg) {
          if (msg is SendPort) {
            ready.complete(msg);
            return;
          }
          if (msg is MatchJobReply) {
            final comp = _pending.remove(msg.jobSeq);
            if (comp == null) return;
            if (msg.cancelled) {
              comp.completeError(
                MatcherCancelledException(-1),
              );
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
        _log.info('matcher isolate started');
      }

      Future<MatchResult> match({
        required int tripId,
        required List<GpsFix> fixes,
        required List<WayCandidate> ways,
      }) async {
        if (!_started) throw StateError('MatcherIsolate not started');
        final seq = ++_seq;
        final job = MatchJob(
          jobSeq: seq,
          tripId: tripId,
          fixes: fixes,
          ways: ways,
        );
        final comp = Completer<MatchResult>();
        _pending[seq] = comp;
        _workerPort!.send(job);
        _cancelledTripIds.remove(tripId);
        return comp.future;
      }

      /// Request cancellation of any pending or in-progress job for [tripId].
      /// In v1 this only affects jobs that have not yet been popped off the
      /// worker's queue; a job already in HmmMatcher.match() runs to
      /// completion but its result will be discarded by the coordinator.
      void cancel(int tripId) {
        _log.info('cancel requested for tripId=$tripId');
        _workerPort?.send(_CancelMessage(tripId));
      }

      void dispose() {
        _isolate?.kill(priority: Isolate.immediate);
        _mainPort.close();
        _started = false;
      }
    }

    class _CancelMessage {
      const _CancelMessage(this.tripId);
      final int tripId;
    }

    // ---------------- worker side ----------------

    void _matcherWorker(SendPort mainPort) {
      final workerPort = ReceivePort();
      mainPort.send(workerPort.sendPort);
      final matcher = const HmmMatcher();
      final cancelled = <int>{}; // tripIds to skip

      workerPort.listen((msg) {
        if (msg is _CancelMessage) {
          cancelled.add(msg.tripId);
          return;
        }
        if (msg is MatchJob) {
          if (cancelled.contains(msg.tripId)) {
            cancelled.remove(msg.tripId);
            mainPort.send(MatchJobReply(jobSeq: msg.jobSeq, cancelled: true));
            return;
          }
          try {
            final result = matcher.match(fixes: msg.fixes, ways: msg.ways);
            mainPort.send(MatchJobReply(jobSeq: msg.jobSeq, result: result));
          } on Object catch (e) {
            mainPort.send(MatchJobReply(jobSeq: msg.jobSeq, error: e));
          }
        }
      });
    }
    ```

    Imports needed: also `GpsFix` and `WayCandidate` for the `match()` signature.

    **`lib/features/matching/data/matching_providers.dart` addition:**
    ```dart
    /// Long-lived matcher isolate provider (Plan 05-06). One instance per
    /// ProviderContainer lifetime; disposed when the container is torn down.
    ///
    /// Consumed by the trip-match coordinator (Plan 05-07).
    final matcherIsolateProvider = Provider<MatcherIsolate>((ref) {
      final isolate = MatcherIsolate();
      // Fire-and-forget start; consumers await start() themselves if they
      // need to know when the isolate is warm. The coordinator awaits before
      // enqueuing the first job.
      unawaited(isolate.start());
      ref.onDispose(isolate.dispose);
      return isolate;
    });
    ```
    Import `MatcherIsolate` at the top and `unawaited` from `dart:async`.

    **Tests (`test/features/matching/data/matcher_isolate_test.dart`)** — ≥ 4 scenarios:
    1. `start + one match roundtrip` — spawn, send a trivial job (2 fixes on a 2-node way), await result, assert non-null MatchResult, dispose. Must complete under 5 s.
    2. `two concurrent jobs return correctly-keyed results` — spawn, send 2 different jobs simultaneously (fire-and-forget both, await both), assert each Future resolves with the correct MatchResult (verify by tripId-associated ways in the input reproduced in the fix count / step count of the output).
    3. `cancel before job starts → future completes with MatcherCancelledException` — this requires racing: enqueue 3 jobs with the second's tripId in a cancel call inserted before the isolate has processed job 1. Realistic test: cancel a tripId, THEN enqueue a job with that tripId → verify (a) cancel-set is cleared on match() enqueue so this actually runs normally OR (b) cancel-set persists across match() enqueue so this hits cancellation. Whichever behavior the code implements, encode it as the test. **Recommended:** `match()` should reset the cancel flag for that tripId (a fresh job is a fresh intent); only cancel-then-do-nothing produces the cancellation. Test: enqueue a large job (5000 fixes on a 500-way input to make it take long enough); immediately call cancel(sameTripId); await the future; assert either MatcherCancelledException OR successful completion (record whichever behavior).
    4. `dispose without hanging` — start, dispose immediately (no jobs), assert no exceptions and no lingering isolates.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/data/matcher_isolate_test.dart
    ```
    Analyze clean; all 4 isolate tests green in under 30 s.
  </verify>
  <done>Isolate spawns cleanly, roundtrips jobs, correlates replies via jobSeq, and shuts down without hangs.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- All 4 isolate tests green.
- `grep -l 'package:drift\|package:flutter/' lib/features/matching/data/matcher_isolate.dart lib/features/matching/data/match_job.dart` returns nothing (worker + payloads are Drift-free and Flutter-free — `package:flutter/foundation.dart` etc. all excluded).
- `matcherIsolateProvider` exists in `matching_providers.dart` and disposes cleanly.

## Ralph Loop

- Tight loop: `flutter analyze`.
- Behavior-sensitive: `flutter test test/features/matching/data/matcher_isolate_test.dart` after every change.
- If a test hangs, dispose eagerly in `tearDown()` and use `Timeout(Duration(seconds: 30))` on each test to fail fast.

## Deviations

- If in-flight cancellation is required (research §11 answer says "acceptable for v1 to only pre-check"), keep the v1 pre-check behavior and add a `TODO(mid-flight-cancel)` — do not scope-creep here.
- If `Isolate.spawn` fails to serialize `WayCandidate` due to `LatLng` from `maplibre_gl` (should not — plain 2-double class — but if `maplibre_gl` version has quirks), convert to a plain `({double lat, double lon})` at the send site and back at receive.

## Commit Strategy

- Task 1 commit: `feat(05-06): MatchJob/MatchJobReply payloads + MatcherCancelledException`
- Task 2 commit: `feat(05-06): MatcherIsolate spawn + protocol + provider wiring`
