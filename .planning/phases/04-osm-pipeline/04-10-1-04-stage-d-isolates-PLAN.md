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
    - "Multi-worker output is BIT-IDENTICAL to serial output: same set of way_admin_raw tuples (identical (way_id, region_id, admin_level, fraction_start, fraction_end) rows), row-count parity."
    - "Workers open the scratch DB read-only inside their own isolate (sqlite3 handles are not sendable) — verified safe per research §5.2."
    - "ProgressLogger from Wave 1 receives per-worker WorkerTick messages via SendPort; the coordinator's ProgressLogger aggregates."
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
    4. For each worker index i: `Isolate.spawn(wayAdminJoinWorkerEntry, WorkerArgs(workerId: i, scratchDbPath: scratch.path, wayIds: partition[i], sendPort: rp.sendPort))`.
    5. Prepare INSERT statement + BEGIN TRANSACTION on the scratch DB (coordinator owns the writer).
    6. Drain messages from ReceivePort:
       - WorkerBatch: for each tuple, `insert.execute([...])`. Forward `tickDelta` to `progress?.absorb(WorkerTick(workerId, tickDelta, elapsedMs))`.
       - WorkerDone: mark worker complete. When all N have signalled done: `COMMIT` + break the loop.
    7. Dispose port + return WayAdminJoinStats.

    Fallback: if workers == 1, execute the original serial path unchanged. This preserves the existing behavior for tests + tiny-fixture runs.

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
  <intent>Bit-identical row set between workers=1 and workers=4 on a realistic fixture.</intent>
  <action>
    Add a test group `'multi-worker correctness'`:

    ```dart
    test('workers=4 produces same way_admin_raw as workers=1', () async {
      // Seed a scratch DB with a fixture (reuse existing fixture builder or
      // spin up one with ~50 ways spanning ~3 admin regions).
      final scratchSerial = _makeFixture();
      buildWayAdminJoin(scratchSerial, workers: 1);
      final serialRows = scratchSerial.raw.select(
        'SELECT way_id, region_id, admin_level, fraction_start, fraction_end '
        'FROM way_admin_raw ORDER BY way_id, region_id, admin_level, fraction_start;'
      ).map((r) => r.toString()).toList();

      final scratchParallel = _makeFixture();
      buildWayAdminJoin(scratchParallel, workers: 4);
      final parallelRows = scratchParallel.raw.select(
        'SELECT way_id, region_id, admin_level, fraction_start, fraction_end '
        'FROM way_admin_raw ORDER BY way_id, region_id, admin_level, fraction_start;'
      ).map((r) => r.toString()).toList();

      expect(parallelRows, equals(serialRows));
    });
    ```

    Also add:
    - `test('workers=1 still hits serial fast-path (no isolates spawned)')` — check via a spy or by asserting Isolate.current is the same before/after (subtle; may need to skip if the test framework can't observe).
    - `test('workers clamps to [1, 16]')` — pass 0 → runs as 1; pass 32 → runs as 16.

    Fixture builder: reuse whatever `way_admin_join_test.dart` currently uses.
    If none, use a tiny synthetic (5-10 ways × 3 admin regions).

    Note: on Windows CI/local, `Isolate.spawn` with entry point functions
    must be top-level or static — verify `wayAdminJoinWorkerEntry` is a
    top-level function (not a class method).
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
    Run Berlin twice:
    ```bash
    time dart run bin/osm_pipeline.dart --pbf=<berlin-pbf> --bbox=... --workers=1
    # capture: T_serial, way_admin_raw row count, osm.sqlite bytes
    time dart run bin/osm_pipeline.dart --pbf=<berlin-pbf> --bbox=... --workers=4
    # capture: T_parallel, way_admin_raw row count, osm.sqlite bytes
    ```

    Assert:
    - `way_admin_raw` row count identical between the two runs.
    - `T_parallel <= T_serial / 2` (Berlin gate — monotonicity is the real property; 2× is a hopeful floor).
    - osm.sqlite bytes identical between the two runs.

    Also observe: progress lines from Stage D interleave worker contributions
    correctly (cadence gate holds, throughput reflects aggregate).
  </action>
  <verify>
    Manual: capture times + row counts. Fail-close if row counts differ.
    Speedup < 2× is a warn (Berlin scale is too small for isolate overhead
    to amortize) but does NOT block progression to Wave 5 — the real proof is
    on Germany.
  </verify>
</task>

## Success Criteria

- `--workers=N` flag parses and forwards correctly.
- workers=1 default: existing tests unchanged, output byte-identical to pre-plan behavior.
- workers=4 correctness test: identical way_admin_raw row set to workers=1.
- Berlin verify: row counts identical; wall-clock ≤ half at N=4 (target — soft on Berlin, will re-prove on Germany).
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
