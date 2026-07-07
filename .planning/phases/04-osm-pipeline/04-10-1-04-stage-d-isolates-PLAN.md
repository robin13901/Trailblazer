---
id: 04-10-1-04
phase: 04-osm-pipeline
plan: 10-1-04
type: execute
wave: 4
depends_on: [04-10-1-03]
files_modified:
  - tool/osm_pipeline/lib/intersect/way_admin_join.dart
  - tool/osm_pipeline/lib/intersect/way_admin_join_isolate.dart
  - tool/osm_pipeline/lib/cli/args.dart
  - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
  - tool/osm_pipeline/bin/osm_pipeline.dart
  - tool/osm_pipeline/test/intersect/way_admin_join_test.dart
  - tool/osm_pipeline/test/cli/args_test.dart
autonomous: true
requirements: [OSM-04, OSM-01]

must_haves:
  truths:
    - "Stage D (way_admin join) runs across N worker isolates. Coordinator loads admin_regions once, partitions Kfz way_ids N-ways, spawns workers, receives result tuples, writes way_admin_raw serially."
    - "New CLI flag `--workers=N` (default: `Platform.numberOfProcessors - 2`, clamped to [1, 16]). N=1 keeps the current serial code-path (safe fallback)."
    - "Multi-worker output is CONTENT-IDENTICAL to serial output: `sqlite3 osm.sqlite '.dump {table}' | sha256sum` matches between --workers=1 and --workers=6 for each of ways, ways_rtree, ways_rtree_lookup, way_admin, admin_regions. (SQLite file bytes may differ due to page-allocation ordering; logical dump hashes must match.) COUNT(*) parity per table asserted explicitly to catch any silently-swallowed duplicate INSERTs."
    - "Workers open the scratch DB read-only inside their own isolate (sqlite3 handles are not sendable) — verified safe per research §5.2."
    - "Coordinator INSERTs into way_admin_raw use PLAIN INSERT (fail-loud on constraint violation) — never `OR IGNORE`. Partition-by-way_id makes duplicate rows impossible under correct partitioning; masking them would hide bugs."
    - "Workers propagate errors via `Isolate.spawn(..., onError: sendPort, errorsAreFatal: true, onExit: sendPort)`. Coordinator's message loop matches WorkerBatch, WorkerDone, and IsolateExit/IsolateError variants and Rule-4-escalates on any error: kill remaining workers, close the DB, exit with code 2 + actionable message. A worker crash MUST NOT deadlock the coordinator on a bare ReceivePort.wait."
    - "ProgressLogger from Wave 1 receives per-worker WorkerTick messages via SendPort; the coordinator's ProgressLogger aggregates. Coordinator synthesises WorkerTick.elapsedMs from a coordinator-local Stopwatch since WorkerBatch payload omits it — documented in Task 2."
    - "Berlin gate: Stage D wall-clock drops by ≥ 2× with --workers=4 vs --workers=1 (isolate overhead dominates at Berlin scale but the invariant is monotonicity)."
  artifacts:
    - path: "tool/osm_pipeline/lib/intersect/way_admin_join_isolate.dart"
      provides: "Worker isolate entry point: opens scratch read-only, processes way_id partition, streams result tuples via SendPort."
      min_lines: 100
    - path: "tool/osm_pipeline/lib/intersect/way_admin_join.dart"
      provides: "Coordinator mode + preserved serial path (N=1)."
    - path: "tool/osm_pipeline/lib/cli/args.dart"
      provides: "--workers=N option"
  key_links:
    - from: "tool/osm_pipeline/lib/intersect/way_admin_join.dart"
      to: "tool/osm_pipeline/lib/intersect/way_admin_join_isolate.dart"
      via: "Isolate.spawn(wayAdminJoinWorkerEntry, WorkerArgs(...)) with worker id, scratch path, way_id partition, admin_regions payload (or read from scratch)"
      pattern: "Isolate\\.spawn"
    - from: "tool/osm_pipeline/lib/intersect/way_admin_join_isolate.dart"
      to: "tool/osm_pipeline/lib/cli/progress_logger.dart"
      via: "worker posts WorkerTick(workerId, delta, elapsed) via SendPort at flush boundaries; coordinator forwards to ProgressLogger.absorb"
      pattern: "WorkerTick"
---

## Goal

Parallelize Stage D across N worker isolates to drop the full-Germany Stage D wall-clock from ~14h to ~2h (research §5.4 Amdahl projection). Preserve exact-output correctness — multi-worker output must equal serial output row-for-row. Wire per-worker progress ticks through the Wave 1 ProgressLogger.

## Context

- Source: `.planning/phases/04-osm-pipeline/04-10-1-RESEARCH.md` §5 (isolate feasibility) and §5.3 (coordinator pattern).
- STATE.md line 180: `WayPipeline.readerFactory` is an existing extension point — this plan doesn't touch Stage B, only Stage D.
- STATE.md line 209: Berlin baseline Stage D wall-clock is short (~130 s of the full ~2m19s run). Berlin gate is monotonicity (workers=4 must be faster than workers=1) and correctness (identical rows).
- sqlite3 package: Database handles are isolate-local (research §5.2). Each worker MUST call `sqlite3.open(scratchPath, mode: OpenMode.readOnly)` inside its own isolate. NEVER send a Database across SendPort.
- scratch DB pragma is `journal_mode=OFF` (Plan 04-03). Multiple readers on OFF journal are safe as long as no writer is concurrent — the coordinator ensures Stage D is READ-ONLY for the whole duration (way_admin_raw writes happen post-worker, serially in the coordinator).
- Do NOT touch app-code `lib/` — this is a `tool/osm_pipeline/` sub-package plan only.

## Tasks

<task type="auto">
  <name>Task 1: Extract worker entry point + WorkerArgs / WorkerResult payloads</name>
  <files>
    tool/osm_pipeline/lib/intersect/way_admin_join_isolate.dart
  </files>
  <intent>Isolate-safe worker function. Copy-paste-refactor the inner loop from way_admin_join.dart; no shared mutable state.</intent>
  <action>
    Create `way_admin_join_isolate.dart` with:

    ```dart
    /// Args sent to a worker via Isolate.spawn.
    class WorkerArgs {
      const WorkerArgs({
        required this.workerId,
        required this.scratchDbPath,
        required this.wayIds,          // partition of way ids to process
        required this.sendPort,        // to coordinator
      });
      final int workerId;
      final String scratchDbPath;
      final List<int> wayIds;
      final SendPort sendPort;
    }

    /// Tuple streamed back to coordinator for INSERT into way_admin_raw.
    class WayAdminResult {
      const WayAdminResult(this.wayId, this.regionId, this.adminLevel,
        this.fractionStart, this.fractionEnd);
      final int wayId;
      final int regionId;
      final int adminLevel;
      final double fractionStart;
      final double fractionEnd;
    }

    /// Batched flush envelope from worker → coordinator.
    class WorkerBatch {
      const WorkerBatch(this.workerId, this.tuples, this.tickDelta);
      final int workerId;
      final List<WayAdminResult> tuples;
      final int tickDelta;             // ways completed since last flush
    }

    /// Sentinel: worker done, no more messages.
    class WorkerDone { const WorkerDone(this.workerId); final int workerId; }

    /// Isolate entry point.
    Future<void> wayAdminJoinWorkerEntry(WorkerArgs args) async {
      final db = sqlite3.open(args.scratchDbPath, mode: OpenMode.readOnly);
      try {
        // Load admin_regions once per worker (identical across workers —
        // sending them through the SendPort would double memory; reading
        // from scratch is O(30K regions) per worker but still fast vs the
        // per-way clip cost).
        final adminByLevel = _loadAdmins(db);
        final nodeSelect = db.prepare('SELECT lat, lng FROM nodes_raw WHERE id = ?;');
        final wayFetch = db.prepare('SELECT node_ids FROM ways_raw WHERE id = ?;');

        final batch = <WayAdminResult>[];
        var doneSinceFlush = 0;
        const flushEvery = 5000;   // tune later
        try {
          for (final wayId in args.wayIds) {
            // ... build linePoints, iterate levels, clip, append to batch
            doneSinceFlush++;
            if (batch.length >= flushEvery) {
              args.sendPort.send(WorkerBatch(args.workerId,
                List.of(batch), doneSinceFlush));
              batch.clear();
              doneSinceFlush = 0;
            }
          }
          if (batch.isNotEmpty || doneSinceFlush > 0) {
            args.sendPort.send(WorkerBatch(args.workerId,
              List.of(batch), doneSinceFlush));
            batch.clear();
          }
        } finally {
          nodeSelect.dispose();
          wayFetch.dispose();
        }
      } finally {
        db.dispose();
      }
      args.sendPort.send(WorkerDone(args.workerId));
    }
    ```

    Refactor: hoist the current per-way loop from `way_admin_join.dart` into
    this file's worker function. Keep the geometry logic identical (call
    `polygon_clip.dart` the same way). The coordinator will call the worker
    directly for N=1 (in-isolate) OR spawn N isolates for N>1.

    Note: `_loadAdmins` currently lives in `way_admin_join.dart` as a private
    helper. Either promote it to a shared library-private helper (move to a
    third file or `part`) OR inline it in the worker. Keep private-scope
    hygiene; do not export `_loadAdmins` publicly.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    ```
    Clean. No test yet — Task 3 covers.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Coordinator mode in buildWayAdminJoin + --workers CLI</name>
  <files>
    tool/osm_pipeline/lib/intersect/way_admin_join.dart
    tool/osm_pipeline/lib/cli/args.dart
    tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
    tool/osm_pipeline/bin/osm_pipeline.dart
  </files>
  <intent>Coordinator: partition way_ids, spawn N workers, drain messages, INSERT serially.</intent>
  <action>
    **`way_admin_join.dart::buildWayAdminJoin`:** add optional `int workers = 1` parameter (keep existing signature backward-compatible; add a second signature `buildWayAdminJoinParallel(ScratchDb, {required int workers, ProgressLogger? progress})` if separating avoids destabilizing the existing tests). Preferred: single entry point with optional workers.

    Coordinator flow (for workers > 1):
    1. Read all Kfz way ids: `SELECT id FROM ways_raw WHERE source='kfz' ORDER BY id;` — this partitioning input must be deterministic.
    2. Partition round-robin: worker `i` gets `ids where index % N == i`. Round-robin balances load if geometries cluster by id.
    3. Open a ReceivePort on the coordinator.
    4. For each worker index i: `Isolate.spawn(wayAdminJoinWorkerEntry, WorkerArgs(workerId: i, scratchDbPath: scratch.path, wayIds: partition[i], sendPort: rp.sendPort), onError: rp.sendPort, errorsAreFatal: true, onExit: rp.sendPort)`. Retain each `Isolate` handle in a `List<Isolate> spawned` so the coordinator can kill survivors on any peer's failure.
    5. Prepare INSERT statement on the scratch DB using **plain `INSERT INTO way_admin_raw(...) VALUES(?,...)` — NOT `INSERT OR IGNORE`.** A partitioning bug that produces duplicate (way_id, region_id, admin_level, fraction_start) tuples MUST blow up loud on the PK/unique constraint, not be silently swallowed. Also BEGIN TRANSACTION on the coordinator (coordinator owns the writer).
    6. Start a coordinator-local Stopwatch `swElapsed` at spawn-time. Drain messages from ReceivePort:
       - **WorkerBatch** (well-typed payload): for each tuple, `insert.execute([...])`. Compute `elapsedMs = swElapsed.elapsedMilliseconds` and forward `tickDelta` to `progress?.absorb(WorkerTick(workerId, tickDelta, elapsedMs))`. (`WorkerBatch` payload does not carry elapsedMs — coordinator synthesizes it from its own Stopwatch. Wave 1 Task 1 truth explicitly allows this.)
       - **WorkerDone**: mark worker complete. When all N have signalled done: `COMMIT` + break the loop.
       - **`List<Object?>` of size 2** (i.e. `[errorString, stackTraceString]` — this is Dart's canonical `onError` message shape): a worker threw. Kill remaining live workers via `for (final iso in spawned) iso.kill(priority: Isolate.immediate);`. `ROLLBACK` the coordinator transaction. Close the DB. Throw a `PipelineError` with the worker's error + stack. This becomes CLI exit code 2 via the standard `run()` handler in `bin/osm_pipeline.dart`. **A worker error MUST NOT let the coordinator wait indefinitely on the ReceivePort.**
       - **`null`** (this is Dart's canonical `onExit` message shape): a worker exited. If it hadn't yet sent WorkerDone → treat as an unclean exit (kill peers, ROLLBACK, throw `PipelineError('Worker $i exited without WorkerDone signal')`). If it had already signalled WorkerDone, ignore this message (clean shutdown).
       - **Unknown message type**: log a warning, ignore. Do not crash the coordinator on unexpected but non-fatal messages.
    7. Dispose port + return WayAdminJoinStats.

    Fallback: if workers == 1, execute the original serial path unchanged (no isolate spawn, no ReceivePort). This preserves the existing behavior for tests + tiny-fixture runs.

    **`args.dart`:** add `--workers` option:
    - Default value: `null` (orchestrator decides).
    - Parse: allow integer or string. On parse failure → PipelineArgsError.
    - Add `final int? workers;` field to `ParsedArgs`.

    **`pipeline_orchestrator.dart::runPipeline`:** add optional `int? workers` parameter. Selection:
    - If explicit: use it, clamped to `[1, 16]`.
    - Else: `min(Platform.numberOfProcessors - 2, 16)`, clamped to `>= 1`.
    - Log the chosen value via `Logger.info('Stage D: N=$N workers')` before calling buildWayAdminJoin.

    **`bin/osm_pipeline.dart`:** forward `parsed.workers` into runPipeline.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    dart test test/intersect/way_admin_join_test.dart      # workers=1 default still passes
    dart test test/cli/args_test.dart                       # --workers parsing
    ```
    All green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Correctness test — 4-worker output ≡ serial output</name>
  <files>
    tool/osm_pipeline/test/intersect/way_admin_join_test.dart
  </files>
  <intent>Content-identical way_admin_raw between workers=1 and workers=6, plus COUNT(*) parity to catch silently-swallowed inserts.</intent>
  <action>
    Add a test group `'multi-worker correctness'`:

    ```dart
    test('workers=6 produces same way_admin_raw as workers=1', () async {
      // Seed a scratch DB with a fixture (reuse existing fixture builder or
      // spin up one with ~50 ways spanning ~3 admin regions).
      final scratchSerial = _makeFixture();
      buildWayAdminJoin(scratchSerial, workers: 1);
      final serialRows = scratchSerial.raw.select(
        'SELECT way_id, region_id, admin_level, fraction_start, fraction_end '
        'FROM way_admin_raw ORDER BY way_id, region_id, admin_level, fraction_start;'
      ).map((r) => r.toString()).toList();
      final serialCount = scratchSerial.raw
          .select('SELECT COUNT(*) AS c FROM way_admin_raw;')
          .first['c'] as int;

      final scratchParallel = _makeFixture();
      buildWayAdminJoin(scratchParallel, workers: 6);
      final parallelRows = scratchParallel.raw.select(
        'SELECT way_id, region_id, admin_level, fraction_start, fraction_end '
        'FROM way_admin_raw ORDER BY way_id, region_id, admin_level, fraction_start;'
      ).map((r) => r.toString()).toList();
      final parallelCount = scratchParallel.raw
          .select('SELECT COUNT(*) AS c FROM way_admin_raw;')
          .first['c'] as int;

      // Order-independent equality via sorted-list comparison PLUS explicit
      // COUNT parity — if a worker's INSERT ever silently drops a row (e.g.
      // future code accidentally uses OR IGNORE), row-set equality alone can
      // still pass while count differs. Test both.
      expect(parallelRows, equals(serialRows), reason: 'row set differs');
      expect(parallelCount, equals(serialCount), reason: 'COUNT(*) differs');
    });
    ```

    Also add:
    - `test('workers=1 still hits serial fast-path (no isolates spawned)')` — check via a spy or by asserting Isolate.current is the same before/after (subtle; may need to skip if the test framework can't observe).
    - `test('workers clamps to [1, 16]')` — pass 0 → runs as 1; pass 32 → runs as 16.
    - `test('worker crash escalates as PipelineError, not deadlock')` — inject a poison way_id that makes the worker throw; assert coordinator throws PipelineError (or exits with code 2 in the CLI harness) within ≤5s rather than hanging indefinitely.

    Fixture builder: reuse whatever `way_admin_join_test.dart` currently uses.
    If none, use a tiny synthetic (5-10 ways × 3 admin regions).

    Note: on Windows CI/local, `Isolate.spawn` with entry point functions
    must be top-level or static — verify `wayAdminJoinWorkerEntry` is a
    top-level function (not a class method).

    Note on the byte-identical invariant: `sqlite3` file bytes are NOT
    deterministic across write orderings (page-allocation order varies).
    Comparing `sha256sum osm.sqlite` between two runs will fail even on
    logically-identical content. The correct invariant is CONTENT-identical
    via canonical dump hashes per table — the `ORDER BY` in the SELECT above
    achieves this at the row-set level for way_admin_raw. Wave 4 Task 4 (Berlin
    verify) applies the same principle at the full-osm.sqlite level via:
    `sqlite3 osm.sqlite '.dump {table}' | sha256sum` for each of ways,
    ways_rtree, ways_rtree_lookup, way_admin, admin_regions — hashes must
    match between --workers=1 and --workers=6 runs.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart test test/intersect/way_admin_join_test.dart
    ```
    All green including the new multi-worker correctness test.
  </verify>
</task>

<task type="auto">
  <name>Task 4: Berlin verify — wall-clock speedup + row count parity</name>
  <files>
    (none — measurement only)
  </files>
  <intent>Prove the isolate machinery pays off on real Berlin data and remains correct.</intent>
  <action>
    Run Berlin twice, into distinct output directories so we can diff:
    ```bash
    OUT_S=out/berlin-workers1
    OUT_P=out/berlin-workers6
    time dart run bin/osm_pipeline.dart --pbf=<berlin-pbf> --bbox=... --workers=1 --out-dir=$OUT_S
    # capture: T_serial, way_admin_raw row count, osm.sqlite bytes
    time dart run bin/osm_pipeline.dart --pbf=<berlin-pbf> --bbox=... --workers=6 --out-dir=$OUT_P
    # capture: T_parallel, way_admin_raw row count, osm.sqlite bytes
    ```

    Content-identical assertion (SQLite file bytes may differ due to page-allocation ordering — that's expected):
    ```bash
    for T in ways ways_rtree ways_rtree_lookup way_admin admin_regions; do
      SHA_S=$(sqlite3 $OUT_S/osm.sqlite ".dump $T" | sha256sum | cut -d' ' -f1)
      SHA_P=$(sqlite3 $OUT_P/osm.sqlite ".dump $T" | sha256sum | cut -d' ' -f1)
      [ "$SHA_S" = "$SHA_P" ] || { echo "MISMATCH on table $T"; exit 1; }
      COUNT_S=$(sqlite3 $OUT_S/osm.sqlite "SELECT COUNT(*) FROM $T;")
      COUNT_P=$(sqlite3 $OUT_P/osm.sqlite "SELECT COUNT(*) FROM $T;")
      [ "$COUNT_S" = "$COUNT_P" ] || { echo "COUNT mismatch on $T: $COUNT_S vs $COUNT_P"; exit 1; }
    done
    echo "All 5 tables content-identical between --workers=1 and --workers=6."
    ```

    Additional assertions:
    - `T_parallel <= T_serial / 2` (Berlin gate — monotonicity is the real property; 2× is a hopeful floor).
    - Progress lines from Stage D interleave worker contributions correctly (cadence gate holds, throughput reflects aggregate).
  </action>
  <verify>
    Manual: capture times + row counts + per-table SHA256 pairs. Fail-close if ANY table's dump-SHA differs OR any COUNT(*) differs — those indicate a real correctness bug in the isolate coordination.

    Speedup < 2× is a warn (Berlin scale is too small for isolate overhead to amortize) but does NOT block progression to Wave 5 — the real proof is on Germany.

    File-byte differences between the two osm.sqlite files are EXPECTED and MUST NOT trigger failure. SQLite page allocation is not deterministic across write orderings; only logical content is.
  </verify>
</task>

## Success Criteria

- `--workers=N` flag parses and forwards correctly.
- workers=1 default: existing tests unchanged, output content-identical (per-table `.dump` SHA256) to pre-plan behavior.
- workers=6 correctness test: identical way_admin_raw row set AND identical COUNT(*) to workers=1 (dual assertion catches silent duplicate-swallow).
- Worker-crash test: coordinator escalates to `PipelineError` within ≤5s of poison-way-id injection, does not deadlock.
- Berlin verify: per-table `.dump | sha256sum` identical between --workers=1 and --workers=6 for all 5 tables (ways, ways_rtree, ways_rtree_lookup, way_admin, admin_regions); wall-clock ≤ half at N=6 (target — soft on Berlin, will re-prove on Germany).
- `dart analyze` clean; all tests green.

## Ralph Loop

- Tight loop: `cd tool/osm_pipeline && dart analyze`.
- Behavior-sensitive (Tasks 1-3): `dart test test/intersect/ test/cli/` after each edit. Multi-worker code is the definition of behavior-sensitive.
- Pre-push: `flutter analyze --fatal-infos` + `flutter test`.

## Deviations

- If worker startup cost > work (Berlin fixture too small): fall back to `workers=1` in the test suite path automatically (i.e., orchestrator default heuristic still picks perProcessor default at CLI level, but the unit tests explicitly set workers=1 and workers=4). Do NOT special-case Berlin — the CLI heuristic applies uniformly.
- If SendPort throughput becomes a bottleneck (research §9.1 flags this as a mitigation-required corner): switch to the per-worker-writes-own-file / ATTACH DATABASE merge pattern (research §5.3 alternative). This is a Task 2 refactor if performance data warrants it; do NOT preemptively implement.
- If `Isolate.spawn` with a class-method entry point fails on Windows (it will — Dart isolate spawn requires top-level or static entry points): ensure `wayAdminJoinWorkerEntry` is a top-level function.
- If the `_loadAdmins` promotion (Task 1) breaks other tests that reach into the private helper: prefer inlining inside the worker file over public exposure.

## Commit Strategy

- Task 1: `feat(04-10-1-04): extract way_admin_join worker isolate entry`
- Task 2: `feat(04-10-1-04): coordinator + --workers=N CLI flag`
- Task 3: `test(04-10-1-04): multi-worker correctness ≡ serial output`
- Task 4: no commit — measurement only; capture times in SUMMARY.
