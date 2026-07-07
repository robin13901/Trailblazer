---
id: 04-10-1-01
phase: 04-osm-pipeline
plan: 10-1-01
type: execute
wave: 1
depends_on: []
files_modified:
  - tool/osm_pipeline/lib/cli/progress_logger.dart
  - tool/osm_pipeline/lib/filter/way_pipeline.dart
  - tool/osm_pipeline/lib/admin/admin_pipeline.dart
  - tool/osm_pipeline/lib/intersect/way_admin_join.dart
  - tool/osm_pipeline/lib/output/osm_sqlite_writer.dart
  - tool/osm_pipeline/lib/pmtiles/geojson_writer.dart
  - tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart
  - tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
  - tool/osm_pipeline/test/cli/progress_logger_test.dart
autonomous: true
requirements: [OSM-01]

must_haves:
  truths:
    - "Every long-running stage (B, C, D, E, F.1) emits at least one progress line per 5 s during a run > 5 s (Berlin smoke observation)."
    - "Log lines carry stage tag, done/total, percentage, throughput (items/s), and ETA."
    - "ProgressLogger accepts isolate SendPort tick messages so Wave 4 (Stage D isolates) can plug workers into an existing aggregator without refactoring the class."
    - "Tippecanoe stdout/stderr lines are echoed to our stderr prefixed with `[Stage F.2]` — no attempt to parse or re-emit tippecanoe's own progress format."
    - "The static `Logger` class (info/warn/error) remains untouched; ProgressLogger is a sibling stateful helper."
  artifacts:
    - path: "tool/osm_pipeline/lib/cli/progress_logger.dart"
      provides: "Stateful progress-emitter with 5s cadence, throughput/ETA math, and SendPort ingestion."
      min_lines: 80
    - path: "tool/osm_pipeline/test/cli/progress_logger_test.dart"
      provides: "Unit coverage: cadence gate, throughput math, ETA math, SendPort aggregation."
      min_lines: 80
  key_links:
    - from: "tool/osm_pipeline/lib/output/pipeline_orchestrator.dart"
      to: "tool/osm_pipeline/lib/cli/progress_logger.dart"
      via: "each stage constructs a ProgressLogger with its known total (from a scratch COUNT(*) or PBF header) and passes .tick to the stage runner"
      pattern: "ProgressLogger\\("
    - from: "tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart"
      to: "stderr"
      via: "child-process stdout/stderr lines re-emitted with `[Stage F.2]` prefix"
      pattern: "\\[Stage F\\.2\\]"
---

## Goal

Add visibility to every long-running stage of the OSM pipeline. A user watching a 30-90 min Germany run should see progress lines every ~5 s per active stage, with throughput and ETA. Design the API so Wave 4 (Stage D isolates) can post per-worker tick deltas without any refactor of this class.

## Context

- Source: `.planning/phases/04-osm-pipeline/04-10-1-RESEARCH.md` §6 (progress logging design).
- Existing state: `tool/osm_pipeline/lib/cli/logger.dart` is a 23-line stateless static class. Do NOT remove it — many call sites depend on it. This plan ADDS a sibling `ProgressLogger` class.
- STATE.md line 180 (Plan 04-03): `WayPipeline.readerFactory` is the extension point for future isolate work — do not disturb.
- STATE.md line 166 (Plan 04-02): the PBF reader is isolate-portable; keep it that way.
- Wave 4 uses this API — the SendPort-ingestion path must be present from day one.

## Tasks

<task type="auto">
  <name>Task 1: Create ProgressLogger class + unit tests</name>
  <files>
    tool/osm_pipeline/lib/cli/progress_logger.dart
    tool/osm_pipeline/test/cli/progress_logger_test.dart
  </files>
  <intent>Ship a self-contained, isolate-safe, testable progress emitter.</intent>
  <action>
    Create `lib/cli/progress_logger.dart` with:

    ```dart
    /// Stateful progress emitter. Owned by the main isolate.
    class ProgressLogger {
      ProgressLogger(this.stage, {required this.total, this.everyMs = 5000,
        this.everyPct = 5, DateTime Function() now = _defaultNow});

      final String stage;         // e.g. 'Stage D'
      final int total;            // total unit count
      final int everyMs;          // min interval between lines (default 5000)
      final int everyPct;         // OR at least every N% (default 5)
      final DateTime Function() now;

      // internals: _done, _lastEmitMs, _lastEmitPct, Stopwatch
      void tick([int n = 1]);   // caller-thread; emits when cadence gate passes
      void finish();            // final line: total items in T seconds at R/s

      /// Isolate ingestion helper — coordinator wires this to a ReceivePort.
      /// Workers post a WorkerTick(workerId, deltaTicks, elapsedMs); the
      /// coordinator's ProgressLogger.absorb(msg) accumulates into _done and
      /// applies the same cadence gate.
      void absorb(WorkerTick msg);
    }

    class WorkerTick {
      const WorkerTick(this.workerId, this.deltaTicks, this.elapsedMs);
      final int workerId;
      final int deltaTicks;
      final int elapsedMs;
    }
    ```

    Cadence gate: emit iff `(now - _lastEmit).inMilliseconds >= everyMs` OR
    `(pct - _lastEmitPct) >= everyPct` OR `_done >= total`.

    Log line format (via `Logger.info`):
    `Stage D progress: 47.3% (1,925,340 / 4,070,051 ways) — 12,340/s — ETA 3m 22s`

    Number formatting: thousands separators via a small helper (do NOT pull in
    the `intl` package for one call site — hand-roll a `_thousands(int)`).

    ETA formatter: `{h}h {m}m` for > 1h; `{m}m {s}s` for > 1m; `{s}s` otherwise;
    `--` when total is 0 or rate is 0.

    `WorkerTick.deltaTicks` accumulates into `_done`. `elapsedMs` is
    informational for future per-worker rate reporting; not required to be
    displayed in Wave 1.

    Tests in `test/cli/progress_logger_test.dart`:
    1. `emits within 5s window when everyMs elapsed` — inject a fake clock.
    2. `emits at 5% boundary before 5s elapsed` — inject a fake clock.
    3. `does NOT emit twice within cadence window` — call tick(1) 100× and
       assert only one line was captured (redirect stderr in the test via
       `IOOverrides.runZoned` OR wrap Logger in a captured sink — pick
       whichever your project convention prefers; grep test/output/ for prior
       art).
    4. `throughput math` — total=1000, tick 500 after 1000ms → rate ≈ 500/s.
    5. `ETA math` — done=500, total=1000, rate=100/s → eta≈5s → "5s" string.
    6. `absorb WorkerTick from N workers accumulates into single _done` —
       feed 4 workers × 250 ticks; assert final _done=1000 and cadence gate
       holds.
    7. `finish() always emits a final line` — even mid-cadence-window.
    8. `zero total → no divide-by-zero` — assert no crash and ETA prints `--`.

    Add package import (`package:osm_pipeline/cli/logger.dart`) — no new
    pubspec deps.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    dart test test/cli/progress_logger_test.dart
    ```
    All tests green; analyze clean.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Wire ProgressLogger into Stages B, C, D, E, F.1 + tag tippecanoe</name>
  <files>
    tool/osm_pipeline/lib/filter/way_pipeline.dart
    tool/osm_pipeline/lib/admin/admin_pipeline.dart
    tool/osm_pipeline/lib/intersect/way_admin_join.dart
    tool/osm_pipeline/lib/output/osm_sqlite_writer.dart
    tool/osm_pipeline/lib/pmtiles/geojson_writer.dart
    tool/osm_pipeline/lib/pmtiles/tippecanoe_runner.dart
    tool/osm_pipeline/lib/output/pipeline_orchestrator.dart
  </files>
  <intent>Instrument every long-running loop so a Germany run produces skimmable log output.</intent>
  <action>
    **Stage B — `way_pipeline.dart`:**
    - Pass A: total is unknown up front. Emit a ProgressLogger over BLOCKS (from `PbfReader`) OR fall back to "ways emitted so far" (total unknown). Prefer: two ProgressLoggers, one per pass, both with total = 0 sentinel meaning "print rate only, no %, no ETA". Extend ProgressLogger.tick to handle total=0 cleanly.
    - Pass B (nodes): same shape.

    **Stage C — `admin_pipeline.dart` (extractAdminRegions):**
    - Total is unknown until pass A completes. Use total=0 sentinel for pass A. For pass B (way members) and pass C (region assembly), total can be `relationsSeen` from pass A.

    **Stage D — `way_admin_join.dart` (buildWayAdminJoin):**
    - Total = `SELECT COUNT(*) FROM ways_raw WHERE source='kfz'` (executed at the start of the function — cheap).
    - `.tick(1)` per way processed inside the outer loop.
    - This is the hottest stage — cadence gate MUST prevent per-way emission
      (already handled by everyMs=5000; verify no allocation on the fast path
      when the gate is closed — a static early-return is fine).

    **Stage E — `osm_sqlite_writer.dart`:**
    - Total = ways_raw row count (excluding source='feldweg' — but Wave 1
      predates Wave 2, so total for now = COUNT(*) FROM ways_raw). Post-Wave-2
      this becomes source='kfz' automatically because the WHERE clause is
      added in Wave 2.
    - `.tick(1)` inside the `for (final row in wayRows)` loop in `_copyWays`.

    **Stage F.1 — `geojson_writer.dart`:**
    - Four independent writers: writeRoads, writeAdminBoundaries, writeWater,
      writeLabels. Wrap each in its own ProgressLogger with total from a
      COUNT(*)/estimated-count. For water/labels (PBF pass) use total=0
      sentinel.

    **Stage F.2 — `tippecanoe_runner.dart`:**
    - Do NOT wrap in ProgressLogger. Instead: prefix each line piped from
      tippecanoe's stdout/stderr with `[Stage F.2] ` before writing to
      `stderr`. If the runner already streams tippecanoe output line-by-line,
      add the prefix inline. If it buffers, break the buffer at `\n`.
    - Emit a single ProgressLogger.info() from the orchestrator ("Stage F.2
      tippecanoe subprocess starting…" / "…done in Ts").

    **Orchestrator — `pipeline_orchestrator.dart`:**
    - Replace the pre-existing `Logger.info('Stage X: ...')` banners with a
      short pre-banner + `ProgressLogger.finish()` post-banner PER stage. Keep
      the existing summary counts logged after each stage (they are the
      finish-line for the log reader).

    **Do NOT introduce new fields to public stat records** — the ProgressLogger
    is a side-effect emitter, not a return value.
  </action>
  <verify>
    ```bash
    cd tool/osm_pipeline
    dart analyze
    dart test                     # all existing tests still green
    # Behavior-sensitive smoke: run Berlin end-to-end (from tool/osm_pipeline)
    # and eyeball that each stage emits at least one [info] line during its run.
    ```

    Manual gate (in the Berlin verify at end of Wave 2 or later — this plan
    doesn't require a Berlin run, just that the wiring compiles and existing
    tests pass): confirm progress lines appear when running smoke.sh or
    smoke.ps1 against tiny.osm.pbf.
  </verify>
</task>

## Success Criteria

- `dart analyze` clean in `tool/osm_pipeline/`.
- All existing tests + the new ProgressLogger tests pass.
- Berlin baseline run (planned for Wave 2's verify) produces at least one
  `[info]` line per 5 s per active stage during the multi-minute stages
  (Stage B, C, D, E, F.1 individually). Log is NOT spammed — cadence gate
  holds.
- Tippecanoe output lines carry the `[Stage F.2]` prefix.
- Wave 4 can wire isolate workers to the coordinator's ProgressLogger via
  `absorb(WorkerTick)` without touching the class internals.

## Ralph Loop

- Tight loop: `cd tool/osm_pipeline && dart analyze`.
- Behavior-sensitive (this plan): also `dart test` after Task 1 (new tests)
  and after Task 2 (existing pipeline_orchestrator + way_admin_join tests).
- Pre-push hook: `flutter analyze --fatal-infos` + `flutter test` covers the
  repo boundary.

## Deviations

- If a stage's total is genuinely unknowable up front (Stage B pass A) and
  ProgressLogger total=0 emits ugly-looking "%: --" — that's fine; the rate
  line is the useful part on that stage. Do NOT hack up the format to avoid
  the sentinel.
- If instrumenting `geojson_writer.dart` for four sub-stages produces too much
  log noise, consolidate to ONE ProgressLogger for the whole Stage F.1 with a
  weighted total. Preferred: keep four; the cadence gate handles the noise.
- If Berlin smoke reveals that Stage D's total (COUNT(*)) query is slow (it
  shouldn't be — the ways_raw index handles it), cache the count in
  `WayAdminJoinStats` from the previous stage. Follow-up, not blocker.

## Commit Strategy

- Task 1 commit: `feat(04-10-1-01): add ProgressLogger + tests`
- Task 2 commit: `feat(04-10-1-01): wire ProgressLogger into stages B-F.1`
- Docs commit at end: none — this is a code-only plan.
