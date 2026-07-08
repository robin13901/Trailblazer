---
phase: 05-overpass-matcher-and-golden-corpus
plan: 08
subsystem: testing
tags: [flutter, dart, hmm, golden-corpus, coverage, lcov, overpass, gzip, ci]

requires:
  - phase: 05-05
    provides: HmmMatcher.match(fixes, ways) → MatchResult + DrivenWayIntervalDraft
  - phase: 04-15
    provides: FixtureWayCandidateSource.fromGzippedOverpassJson (test helper)

provides:
  - Golden corpus regression harness (golden_corpus_test.dart discovers + runs all fixtures)
  - First seed fixture 001_synthetic_straight_east (synthetic 5-fix east-bound trace on 1 way)
  - save_trip_fixture CLI (dart run tool/osm_pipeline/bin/save_trip_fixture.dart --trace <path>)
  - check_matcher_coverage script (lcov parser, 90% gate on matcher domain + driven_way_intervals_dao)
  - CI coverage-gate step (Enforce matcher coverage >= 90% in .github/workflows/ci.yml)
  - Deferral record for 4 real-drive fixtures (README.md + STATE.md Pending Todos)

affects:
  - Phase 5 close-out drives (real-drive corpus batch 002..005)
  - Phase 6+ (corpus expansion to ≥ 20 fixtures per roadmap SC3)
  - All future algorithm-tuning PRs (must update expected_ways.json when changing matcher behavior)

tech-stack:
  added: []
  patterns:
    - "Golden corpus pattern: each fixture is NNN_slug/ with gps_trace.json + ways.json.gz + expected_ways.json + metadata.json"
    - "Coverage gate via dart run tool/check_matcher_coverage.dart (post remove_from_coverage)"
    - "Fixture generator CLI in tool/osm_pipeline/bin/ (invoked as dart run tool/osm_pipeline/bin/save_trip_fixture.dart)"

key-files:
  created:
    - test/fixtures/golden_trips/README.md
    - test/fixtures/golden_trips/001_synthetic_straight_east/gps_trace.json
    - test/fixtures/golden_trips/001_synthetic_straight_east/ways.json.gz
    - test/fixtures/golden_trips/001_synthetic_straight_east/expected_ways.json
    - test/fixtures/golden_trips/001_synthetic_straight_east/metadata.json
    - test/features/matching/golden_corpus_test.dart
    - tool/osm_pipeline/bin/save_trip_fixture.dart
    - tool/check_matcher_coverage.dart
  modified:
    - .github/workflows/ci.yml
    - .planning/STATE.md

key-decisions:
  - "Autonomous execution (overnight flip): real-drive fixtures deferred to post-phase drive-batch so plan runs unattended; same pattern as Phase 3/Phase 4 close-out deferral"
  - "Seed fixture uses way-id=1 with 3 nodes along lat=49.7 (lon 8.999..9.002) tagged highway=residential — trivially matchable by HmmMatcher, no tuning ambiguity"
  - "Coverage gate scope: lib/features/matching/domain/** + lib/core/db/daos/driven_way_intervals_dao.dart at 90%; isolate/coordinator files excluded (hard-to-cover error branches)"
  - "CI step placement: AFTER remove_from_coverage BEFORE codecov upload — aligns with plan spec"
  - "Corpus test skips when fixture directory is empty (green on fresh checkout) but any committed fixture that fails = CI failure"

patterns-established:
  - "Golden corpus skip pattern: test body-less test with skip:true when fixture dir absent or empty"
  - "Fixture gzip: gzip.encode(utf8.encode(overpassJsonString)) — same as OverpassWayCandidateSource cache format"
  - "Coverage gate exit codes: 0=pass, 1=fail(<90%), 2=error(no lcov or no matcher files found)"

duration: 45min
completed: 2026-07-08
---

# Phase 5 Plan 08: Golden Corpus and Coverage Gate Summary

**Golden corpus harness + synthetic seed fixture + CI 90%-coverage gate for the HMM matcher domain, with 4 real-drive fixtures deferred to a documented out-of-band drive-batch**

## Performance

- **Duration:** ~45 min
- **Started:** 2026-07-08T00:00:00Z (overnight batch)
- **Completed:** 2026-07-08
- **Tasks:** 4
- **Files created:** 10 (README, 4 fixture files, golden_corpus_test.dart, save_trip_fixture.dart, check_matcher_coverage.dart, ci.yml modification, STATE.md update)

## Accomplishments

- Golden corpus regression harness (`golden_corpus_test.dart`) discovers subdirectory fixtures, loads gps_trace.json + ways.json.gz + expected_ways.json, runs `HmmMatcher.match()`, asserts wayId sequence equality; skips gracefully on empty corpus
- Seed fixture `001_synthetic_straight_east/` — synthetic 5-fix east-bound trace along a single `highway=residential` way (way-id=1); harness passes on first run
- `tool/check_matcher_coverage.dart` — lcov parser that computes line coverage for `lib/features/matching/domain/**` + `driven_way_intervals_dao.dart`; exits 0 when ≥ 90%, exits 1 on failure, exits 2 on error (no file / no matcher files found)
- `tool/osm_pipeline/bin/save_trip_fixture.dart` — CLI that reads `gps_trace.json`, pads bbox by 0.001°, queries Overpass, writes `ways.json.gz` next to the trace
- CI step `Enforce matcher coverage >= 90% (QUA-02)` wired between `Strip generated files from coverage` and `Upload coverage to Codecov`
- Deferral record for 4 real-drive scenarios (002_autobahn_forward, 003_kreisel_entry_exit, 004_city_grid, 005_bundesstrasse_mixed) documented in README.md + STATE.md Pending Todos

## Task Commits

1. **Task 1: Fixture layout README + first synthetic seed + corpus-runner test** - `8a966d8` (feat)
2. **Task 2: save_trip_fixture CLI + check_matcher_coverage script** - `0d0af68` (feat)
3. **Task 3: CI coverage-gate step wiring** - `fb0dde7` (ci)
4. **Task 4: Record deferred-drive-batch follow-up in README + STATE.md** - `03a2f18` (docs)

## Files Created/Modified

- `test/fixtures/golden_trips/README.md` - Fixture layout spec + field format + Adding a new fixture workflow + Required scenarios table (20 MMT-09 scenarios) + deferred drive-batch section
- `test/fixtures/golden_trips/001_synthetic_straight_east/gps_trace.json` - 5-fix east-bound trace at lat=49.7
- `test/fixtures/golden_trips/001_synthetic_straight_east/ways.json.gz` - Minimal Overpass response (1 residential way, 3 nodes)
- `test/fixtures/golden_trips/001_synthetic_straight_east/expected_ways.json` - `[{"wayId": 1, "direction": "forward"}]`
- `test/fixtures/golden_trips/001_synthetic_straight_east/metadata.json` - Scenario metadata
- `test/features/matching/golden_corpus_test.dart` - Corpus runner: directory discovery, fixture loading, matcher call, wayId sequence assertion
- `tool/osm_pipeline/bin/save_trip_fixture.dart` - Fixture generator CLI (--trace flag, Overpass fetch, gzip write)
- `tool/check_matcher_coverage.dart` - lcov parser + 90% gate (exits 0/1/2)
- `.github/workflows/ci.yml` - Added `Enforce matcher coverage >= 90% (QUA-02)` step
- `.planning/STATE.md` - Updated Current Position, Pending Todos (deferred drive-batch), Session Continuity

## Decisions Made

- **Overnight autonomous execution:** The plan's original `type="checkpoint:human-action"` for real drives was flipped to `autonomous=true`. Task 4 records the deferral in README + STATE.md — the physical drives happen post-phase and land as a follow-up PR. Same pattern as Phase 3 close-out + Phase 4 Kleinheubach batch.
- **Synthetic seed geometry:** way-id=1, 3 nodes at lat=49.7 from lon=8.999 to lon=9.002; trace of 5 fixes from lon=9.0000 to lon=9.0010. Trace is entirely within the way's bbox, making the match trivially deterministic.
- **Coverage gate scope:** `lib/features/matching/domain/` prefix-match + exact `driven_way_intervals_dao.dart` path. Isolate + coordinator files excluded — they include hard-to-cover error branches (isolate spawn failure, port close).
- **kMinCoveragePct = 90 (int not double):** `prefer_int_literals` lint requires int literal; Dart coerces to double in comparison context.
- **Tool placement:** `save_trip_fixture.dart` lives in `tool/osm_pipeline/bin/` (alongside other osm_pipeline CLI tools). `check_matcher_coverage.dart` lives in repo root `tool/` (app-layer tool, not a pipeline tool).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed `avoid_multiple_declarations_per_line` lint in golden_corpus_test.dart**
- **Found during:** Task 1 (lint check)
- **Issue:** `var minLat = 90.0, minLon = 180.0, maxLat = -90.0, maxLon = -180.0;` on one line
- **Fix:** Split into 4 separate `var` declarations
- **Files modified:** test/features/matching/golden_corpus_test.dart
- **Committed in:** `8a966d8` (Task 1 commit)

**2. [Rule 1 - Bug] Fixed `prefer_int_literals` + `unnecessary_brace_in_string_interps` in check_matcher_coverage.dart**
- **Found during:** Task 2 (lint check)
- **Issue:** `const double kMinCoveragePct = 90.0` + `${kMinCoveragePct}` braces in interpolation
- **Fix:** Changed to `const kMinCoveragePct = 90` (int), removed braces
- **Files modified:** tool/check_matcher_coverage.dart
- **Committed in:** `0d0af68` (Task 2 commit)

**3. [Rule 1 - Bug] Fixed `unnecessary_brace_in_string_interps` in save_trip_fixture.dart**
- **Found during:** Task 2 (lint check)
- **Issue:** `'(way[highway](${minLat},${minLon},${maxLat},${maxLon});)'` — braces unnecessary for simple variables
- **Fix:** Removed braces: `'(way[highway]($minLat,$minLon,$maxLat,$maxLon);)'`
- **Files modified:** tool/osm_pipeline/bin/save_trip_fixture.dart
- **Committed in:** `0d0af68` (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (all Rule 1 lint-clean fixes)
**Impact on plan:** All lint fixes necessary for clean `flutter analyze`. No scope creep.

## Issues Encountered

- The parallel 05-06 agent (Wave 4) was executing concurrently and committed `matching_providers.dart` + `matcher_isolate.dart` + related test files. Per the plan's parallel-wave coordination rules, all of 05-08's task commits staged ONLY the files declared in the plan's `files_modified` frontmatter. No cross-contamination observed in final git log.

## Next Phase Readiness

- Golden corpus harness is ready to receive real-drive fixtures via the documented workflow in `test/fixtures/golden_trips/README.md`
- CI coverage gate is active — any PR that drops matcher domain coverage below 90% will fail CI
- 4 real-drive fixtures are documented as a pending drive-batch (batch with Phase 4 Kleinheubach close-out drive)
- Phase 6 planning is unblocked — matcher + corpus harness are both complete

---
*Phase: 05-overpass-matcher-and-golden-corpus*
*Completed: 2026-07-08*
