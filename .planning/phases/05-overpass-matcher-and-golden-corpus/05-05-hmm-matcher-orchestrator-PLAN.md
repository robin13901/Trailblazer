---
id: 05-05
phase: 05-overpass-matcher-and-golden-corpus
plan: 05
type: execute
wave: 2
depends_on: [05-01, 05-04]
files_modified:
  - lib/features/matching/domain/hmm_matcher.dart
  - lib/features/matching/domain/match_result.dart
  - lib/features/matching/domain/driven_way_interval_draft.dart
  - test/features/matching/domain/hmm_matcher_test.dart
autonomous: true
requirements: [MMT-02, MMT-03, MMT-05, MMT-06]

must_haves:
  truths:
    - "`HmmMatcher.match({List<GpsFix>, List<WayCandidate>})` returns a `MatchResult` containing (1) the per-fix `List<MatchedStep?>` for debugging and (2) a `List<DrivenWayIntervalDraft>` ready for `DrivenWayIntervalsDao.insertBatch` after the coordinator (05-07) adds the tripId."
    - "Interval merging: consecutive MatchedSteps on the same wayId with the same direction collapse into one interval; a direction change or wayId change starts a new interval."
    - "`start_meters` / `end_meters` are computed by summing segment lengths from the way's first node up to the projection point, using `segmentLengthMeters` from 05-02."
    - "Null MatchedSteps (dropped fixes) break the current interval — the next non-null step starts a fresh interval, even if it's on the same wayId (a gap in confidence is a gap in coverage per MMT-05)."
    - "Empty fixes → empty MatchResult with empty intervals; single-fix trace with 1 candidate → 1 MatchedStep, 1 interval with start_meters == end_meters (a point)."
    - "Direction is emitted as `'forward'` or `'backward'` per MMT-06; never `'both'` (research §11.6)."
    - "Matcher is stateless: two `match()` calls with identical inputs produce identical outputs (verified in tests)."
  artifacts:
    - path: "lib/features/matching/domain/driven_way_interval_draft.dart"
      provides: "DrivenWayIntervalDraft — tripId-less companion of the DAO row; coordinator fills tripId before insertBatch."
      min_lines: 40
    - path: "lib/features/matching/domain/match_result.dart"
      provides: "MatchResult (steps + intervals + counts of matched/dropped fixes for logging)."
      min_lines: 40
    - path: "lib/features/matching/domain/hmm_matcher.dart"
      provides: "HmmMatcher: builds WaySegmentIndex from ways, runs ViterbiDecoder, collapses MatchedSteps into intervals."
      min_lines: 140
    - path: "test/features/matching/domain/hmm_matcher_test.dart"
      provides: "≥ 8 integration tests: empty/single-fix/happy-path/interval-merge/direction-flip/gap-drop/idempotence."
      min_lines: 200
  key_links:
    - from: "lib/features/matching/domain/hmm_matcher.dart"
      to: "lib/features/matching/domain/viterbi_decoder.dart"
      via: "ViterbiDecoder(beta, beamWidth).decode(fixes, index)"
      pattern: "ViterbiDecoder|decode\\("
    - from: "lib/features/matching/domain/hmm_matcher.dart"
      to: "lib/features/matching/domain/way_segment_index.dart"
      via: "WaySegmentIndex.buildFromWays(ways) at start of match()"
      pattern: "WaySegmentIndex\\.buildFromWays"
    - from: "lib/features/matching/domain/hmm_matcher.dart"
      to: "lib/features/matching/domain/segment_geometry.dart"
      via: "segmentLengthMeters for start_meters/end_meters accumulation"
      pattern: "segmentLengthMeters"
---

## Goal

Ship the orchestrator that turns `(List<GpsFix>, List<WayCandidate>) → MatchResult` — build the index, run the decoder, collapse consecutive steps into `DrivenWayIntervalDraft` rows. The coordinator (05-07) will call this and add `tripId` before writing via the DAO from 05-01.

## Context

- Inputs from Wave 1 + 05-04: `WaySegmentIndex.buildFromWays`, `ViterbiDecoder.decode`, `segmentLengthMeters`, `MatchedStep`, `GpsFix`, `DrivenWayIntervalsCompanion` (from 05-01).
- The orchestrator is thin — the algorithmic work is in 05-04. Focus here is on interval merging + start/end-meter computation.
- Draft vs. Companion: `DrivenWayIntervalDraft` is a plain Dart class (no Drift import) — the matcher lives in `lib/features/matching/domain/` and must stay Drift-free so it can run in the matcher isolate (Plan 05-06). The coordinator (05-07) converts drafts to `DrivenWayIntervalsCompanion` at the DB boundary.
- `start_meters` semantics: distance from the way's first node along the polyline to the projection point of the first matched fix on that way. `end_meters` is the same but for the last matched fix on that way in the current interval.
  - Compute via: `sum(segmentLengthMeters(geom[0..segIdx-1]))` + `projectionFraction * segmentLengthMeters(geom[segIdx])`.
- The matcher needs the way's full polyline to compute meters, so it must retain the `WayCandidate` (not just the segments). Approach: build a `Map<int, WayCandidate> waysById` at the start of `match()`; look up geometry when emitting intervals.
- **Direction detection at the interval level:**
  - When collapsing consecutive MatchedSteps into an interval, the interval's `direction` is derived from the sign of `(end_meters - start_meters)`:
    - `end_meters >= start_meters` → `'forward'`.
    - `end_meters < start_meters` → `'backward'` (and swap start/end so start ≤ end in the stored row).
- Test doubles: build hand-crafted `WayCandidate` lists inline for unit tests. No fixture files required at this layer.

## Tasks

<task type="auto">
  <name>Task 1: DrivenWayIntervalDraft + MatchResult value types</name>
  <files>
    lib/features/matching/domain/driven_way_interval_draft.dart
    lib/features/matching/domain/match_result.dart
  </files>
  <intent>Two plain value types (no Drift import) that the coordinator will translate to DAO companions.</intent>
  <action>
    **`lib/features/matching/domain/driven_way_interval_draft.dart`:**
    ```dart
    // Phase 5 (Plan 05-05): DrivenWayIntervalDraft — the matcher's output row,
    // before tripId is attached at the DB boundary. Kept Drift-free so the
    // matcher can run on the matcher isolate (Plan 05-06) without a Drift
    // handle crossing the isolate boundary.

    import 'package:meta/meta.dart';

    @immutable
    class DrivenWayIntervalDraft {
      const DrivenWayIntervalDraft({
        required this.wayId,
        required this.startMeters,
        required this.endMeters,
        required this.direction,
      });

      final int wayId;

      /// Distance along the way from its first node to the first matched fix
      /// in this interval. Always >= 0 and <= [endMeters].
      final double startMeters;

      final double endMeters;

      /// 'forward' | 'backward'.
      final String direction;

      @override
      String toString() =>
          'DrivenWayIntervalDraft(way=$wayId, $startMeters..${endMeters}m, dir=$direction)';
    }
    ```

    **`lib/features/matching/domain/match_result.dart`:**
    ```dart
    // Phase 5 (Plan 05-05): MatchResult — full output of one HmmMatcher run.

    import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
    import 'package:auto_explore/features/matching/domain/matched_step.dart';
    import 'package:meta/meta.dart';

    @immutable
    class MatchResult {
      const MatchResult({
        required this.steps,
        required this.intervals,
        required this.matchedFixCount,
        required this.droppedFixCount,
      });

      /// Per-fix decisions (same length as the input fix list); `null` for
      /// dropped fixes.
      final List<MatchedStep?> steps;

      /// Merged intervals, ready for the DAO after tripId is attached.
      final List<DrivenWayIntervalDraft> intervals;

      final int matchedFixCount;
      final int droppedFixCount;

      bool get isEmpty => steps.isEmpty;
    }
    ```
  </action>
  <verify>
    ```bash
    flutter analyze
    ```
    Analyze clean.
  </verify>
  <done>Two value types compile; no Drift/Flutter imports.</done>
</task>

<task type="auto">
  <name>Task 2: HmmMatcher orchestrator + interval merging + start/end meters</name>
  <files>
    lib/features/matching/domain/hmm_matcher.dart
    test/features/matching/domain/hmm_matcher_test.dart
  </files>
  <intent>Glue layer: build index, decode, collapse steps into intervals.</intent>
  <action>
    **`lib/features/matching/domain/hmm_matcher.dart`:**
    ```dart
    // Phase 5 (Plan 05-05): HmmMatcher — the orchestrator that turns
    // (List<GpsFix>, List<WayCandidate>) into a MatchResult.

    import 'package:auto_explore/features/matching/domain/driven_way_interval_draft.dart';
    import 'package:auto_explore/features/matching/domain/gps_fix.dart';
    import 'package:auto_explore/features/matching/domain/hmm_probability.dart';
    import 'package:auto_explore/features/matching/domain/match_result.dart';
    import 'package:auto_explore/features/matching/domain/matched_step.dart';
    import 'package:auto_explore/features/matching/domain/segment_geometry.dart';
    import 'package:auto_explore/features/matching/domain/viterbi_decoder.dart';
    import 'package:auto_explore/features/matching/domain/way_candidate.dart';
    import 'package:auto_explore/features/matching/domain/way_segment_index.dart';

    class HmmMatcher {
      const HmmMatcher({
        this.betaMeters = kTransitionBetaMeters,
        this.beamWidth = kBeamWidth,
      });

      final double betaMeters;
      final int beamWidth;

      MatchResult match({
        required List<GpsFix> fixes,
        required List<WayCandidate> ways,
      }) {
        if (fixes.isEmpty) {
          return const MatchResult(
            steps: [],
            intervals: [],
            matchedFixCount: 0,
            droppedFixCount: 0,
          );
        }

        final index = WaySegmentIndex.buildFromWays(ways);
        final waysById = <int, WayCandidate>{
          for (final w in ways) w.wayId: w,
        };

        final decoder = ViterbiDecoder(
          betaMeters: betaMeters,
          beamWidth: beamWidth,
        );
        final steps = decoder.decode(fixes, index);

        final intervals = _collapseToIntervals(steps, waysById);

        final matched = steps.where((s) => s != null).length;
        final dropped = steps.length - matched;

        return MatchResult(
          steps: steps,
          intervals: intervals,
          matchedFixCount: matched,
          droppedFixCount: dropped,
        );
      }

      List<DrivenWayIntervalDraft> _collapseToIntervals(
        List<MatchedStep?> steps,
        Map<int, WayCandidate> waysById,
      ) {
        final out = <DrivenWayIntervalDraft>[];
        int? runWayId;
        String? runDirection; // 'forward' | 'backward'
        double runStartMeters = 0;
        double runEndMeters = 0;
        MatchedStep? runFirstStep;
        MatchedStep? runLastStep;

        void flush() {
          if (runWayId == null || runFirstStep == null) return;
          final start = math.min(runStartMeters, runEndMeters);
          final end = math.max(runStartMeters, runEndMeters);
          final direction = runEndMeters >= runStartMeters
              ? 'forward'
              : 'backward';
          out.add(DrivenWayIntervalDraft(
            wayId: runWayId!,
            startMeters: start,
            endMeters: end,
            direction: direction,
          ));
          runWayId = null;
          runFirstStep = null;
          runLastStep = null;
        }

        for (final s in steps) {
          if (s == null) {
            // Confidence gap — break the run.
            flush();
            continue;
          }
          final metersFromWayStart = _metersFromWayStart(s, waysById);
          if (runWayId == null) {
            runWayId = s.wayId;
            runFirstStep = s;
            runLastStep = s;
            runStartMeters = metersFromWayStart;
            runEndMeters = metersFromWayStart;
            continue;
          }
          if (s.wayId != runWayId) {
            flush();
            runWayId = s.wayId;
            runFirstStep = s;
            runLastStep = s;
            runStartMeters = metersFromWayStart;
            runEndMeters = metersFromWayStart;
            continue;
          }
          // Same way — extend the run. Direction is derived at flush time.
          runLastStep = s;
          runEndMeters = metersFromWayStart;
        }
        flush();
        return out;
      }

      double _metersFromWayStart(
        MatchedStep step,
        Map<int, WayCandidate> waysById,
      ) {
        final way = waysById[step.wayId];
        if (way == null || way.geometry.length < 2) return 0.0;
        final geom = way.geometry;
        double acc = 0.0;
        for (var i = 0; i < step.segIdx && i + 1 < geom.length; i++) {
          acc += segmentLengthMeters(
            aLat: geom[i].latitude,
            aLon: geom[i].longitude,
            bLat: geom[i + 1].latitude,
            bLon: geom[i + 1].longitude,
          );
        }
        // Add fractional length within the current segment.
        if (step.segIdx + 1 < geom.length) {
          final segLen = segmentLengthMeters(
            aLat: geom[step.segIdx].latitude,
            aLon: geom[step.segIdx].longitude,
            bLat: geom[step.segIdx + 1].latitude,
            bLon: geom[step.segIdx + 1].longitude,
          );
          acc += step.projectionFraction * segLen;
        }
        return acc;
      }
    }
    ```
    (Import `dart:math` for `math.min` / `math.max`.)

    **Tests (`test/features/matching/domain/hmm_matcher_test.dart`)** — ≥ 8 scenarios:
    1. `Empty fixes → empty MatchResult (0 intervals, 0 matched, 0 dropped)`.
    2. `Empty ways → all fixes dropped; intervals empty; steps all null`.
    3. `Single fix on a single 3-node way → 1 step, 1 interval with start_meters == end_meters, direction='forward'`.
    4. `Straight 5-fix trace forward along one 4-node way (each fix on a different segment) → 1 interval with start < end, direction='forward'`.
    5. `Same 5-fix trace REVERSED → 1 interval with direction='backward' and start < end (start/end are min/max of the traversed range, not raw first/last)`.
    6. `10-fix trace: 5 on way A, then 5 on way B → 2 intervals, one per way`.
    7. `Confidence gap: 5 fixes all on way A but fix #3 is 500 m off any way → 2 intervals on way A separated by the drop`.
    8. `Direction flip mid-way: forward 3 fixes, then backward 3 fixes (all on same wayId, oneway=no) → 2 intervals`.
       Note: this test depends on how Viterbi treats the direction reversal on `oneway=no`. Expect the merger to detect the fraction-delta sign change and split. If the merger does NOT split direction changes intra-way (i.e. relies solely on start_meters vs end_meters at flush time), acknowledge the tradeoff and simply assert that a single interval spanning start=min(fractions) to end=max(fractions) with direction chosen by net delta is produced. Whichever behavior lands, encode it in the test.
    9. `Determinism: two match() calls with identical inputs produce structurally identical MatchResults` (compare via toString comparison of intervals list).
    10. `matchedFixCount + droppedFixCount == fixes.length`.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/domain/hmm_matcher_test.dart
    ```
    Analyze clean; all tests green.
  </verify>
  <done>End-to-end matcher works on hand-built scenarios; interval merging and meter accumulation verified.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- All Wave-2 tests (05-04 + 05-05) green together — run `flutter test test/features/matching/domain/`.
- `hmm_matcher.dart` imports NO Drift, NO Flutter, NO isolate. Verify with grep.
- `DrivenWayIntervalDraft` has no `import 'package:drift'` — confirm with grep.

## Ralph Loop

- Tight loop: `flutter analyze`.
- Behavior-sensitive: `flutter test test/features/matching/domain/` on every change to the matcher or decoder.

## Deviations

- If direction-flip test #8 exposes an ambiguity in the interval-merge algorithm (a single interval on the same wayId with a real backward-then-forward trace), lock the behavior as "single interval with direction = sign of net delta" and update the test. Do NOT try to split intra-way — that's a Phase 6 aggregation concern.
- If a floating-point instability in `_metersFromWayStart` makes tests flaky, add a `toStringAsFixed(2)` step to the assertion tolerances rather than tuning the math.

## Commit Strategy

- Task 1 commit: `feat(05-05): DrivenWayIntervalDraft + MatchResult value types`
- Task 2 commit: `feat(05-05): HmmMatcher orchestrator with interval merging`
