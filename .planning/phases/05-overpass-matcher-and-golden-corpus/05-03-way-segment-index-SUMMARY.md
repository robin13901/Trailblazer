---
phase: 05-overpass-matcher-and-golden-corpus
plan: 03
subsystem: matching
tags: [rbush, r-tree, spatial-index, way-segment, flutter, dart, equirectangular]

# Dependency graph
requires:
  - phase: 05-02
    provides: segment_geometry.dart (perpDistanceToSegmentMeters, metersPerDegreeLon, metersPerDegreeLat)
  - phase: 04-13
    provides: WayCandidate domain model + OnewayDirection enum
provides:
  - WaySegment immutable value type with (wayId, segIdx) structural equality
  - WaySegmentIndex backed by rbush RBushBase<WaySegment> with bulk STR load
  - queryWithinRadius: coarse R-Tree bbox filter with metric radius
  - queryTopK: exact perp-distance ranking with deterministic tie-breaking
affects:
  - 05-04 (ViterbiDecoder will call queryTopK to get candidate segments per fix)
  - 05-05 (HMM matcher orchestrator uses WaySegmentIndex per trip)
  - 05-06 (matcher isolate builds WaySegmentIndex.buildFromWays in isolate spawn)

# Tech tracking
tech-stack:
  added:
    - rbush ^1.1.1 (R-Tree spatial index, STR bulk load)
  patterns:
    - RBushBase<WaySegment> with custom toBBox/getMinX/getMinY extractors
    - Two-phase query: coarse R-Tree bbox hit → exact perpendicular distance rerank
    - Structural equality by identity slot (wayId, segIdx) not coordinates

key-files:
  created:
    - lib/features/matching/domain/way_segment.dart
    - lib/features/matching/domain/way_segment_index.dart
    - test/features/matching/domain/way_segment_test.dart
    - test/features/matching/domain/way_segment_index_test.dart
  modified:
    - pubspec.yaml (rbush added, alphabetized between permission_handler and riverpod_annotation)
    - pubspec.lock

key-decisions:
  - "rbush 1.1.1 added (research §11 open question #7 resolved — latest on pub.dev at execution time)"
  - "WaySegment equality by (wayId, segIdx) only — coordinate changes on re-densified geometry do not break identity"
  - "queryWithinRadius uses metersPerDegreeLon(lat) for correct lon-axis scaling at German latitudes"
  - "queryTopK sorts by (distance, wayId, segIdx) for deterministic output — essential for Viterbi reproducibility"
  - "Benchmark smoke test: 15k segments built in 6ms (well under 500ms advisory, 2s hard limit)"

patterns-established:
  - "R-Tree segments not ways: ways can be 100s of meters long; per-segment bbox avoids false-positive hits"
  - "STR bulk load via rbush load() — not per-item insert — for large fixture builds"

# Metrics
duration: 11min
completed: 2026-07-08
---

# Phase 5 Plan 03: Way Segment Index Summary

**rbush-backed per-segment R-Tree (WaySegment + WaySegmentIndex) with coarse bbox filter and exact perpendicular-distance top-K query, built in < 10ms for 15k segments**

## Performance

- **Duration:** 11 min
- **Started:** 2026-07-08T19:43:36Z
- **Completed:** 2026-07-08T19:54:12Z
- **Tasks:** 2
- **Files modified:** 6 (2 lib, 2 test, pubspec.yaml, pubspec.lock)

## Accomplishments
- `WaySegment` immutable value type with `(wayId, segIdx)` structural equality and AABB helpers for R-Tree indexing
- `WaySegmentIndex.buildFromWays` explodes ways to segments and bulk-loads into `RBushBase<WaySegment>` via STR pack
- `queryWithinRadius` uses `metersPerDegreeLon(lat)` scaling for correct metric radius on the longitude axis
- `queryTopK` reranks coarse R-Tree hits by `perpDistanceToSegmentMeters`, ties by `(wayId, segIdx)` for determinism
- 24 tests green (12 WaySegment + 12 WaySegmentIndex); benchmark: 15k segments in 6ms

## Task Commits

Each task was committed atomically:

1. **Task 1: WaySegment value type + fromWay factory** - `8c3e333` (feat)
2. **Task 2: WaySegmentIndex (rbush) with radius + top-K queries** - `5d4c6a3` (feat)

**Plan metadata:** (follows in next commit)

## Files Created/Modified
- `lib/features/matching/domain/way_segment.dart` - WaySegment @immutable value type, fromWay factory, AABB helpers
- `lib/features/matching/domain/way_segment_index.dart` - WaySegmentIndex wrapping RBushBase<WaySegment>, build/queryRadius/queryTopK
- `test/features/matching/domain/way_segment_test.dart` - 12 tests: decomposition, bbox correctness, equality/hashCode/Set
- `test/features/matching/domain/way_segment_index_test.dart` - 12 tests: build, radius queries, top-K ordering, ties, exclusion, fixture integration, benchmark
- `pubspec.yaml` - Added `rbush: ^1.1.1` (alphabetized)
- `pubspec.lock` - Updated with rbush 1.1.1 resolved entry

## Decisions Made
- **rbush 1.1.1** — Research §11 open question #7 resolved; `dart pub add rbush` resolved to 1.1.1 (latest on pub.dev 2026-07-08). Pinned at ^1.1.1.
- **Per-segment indexing** — Ways can be hundreds of meters long; indexing whole-way bboxes would cause false-positive hits far from the actual road geometry. Each consecutive node pair becomes a WaySegment.
- **`queryTopK` radius at 80m in the ordering test** — The plan's suggested 25m radius was too tight for the 6-segment test fixture (segments at 0.0001° ≈ 11m step; segment 5 is ~55m away). Adjusted to 80m to cover 6 segments while still testing the k=5 cap.
- **Benchmark pass** — 15k segments (5000 ways × 4 nodes) built in 6ms on the dev box. Well under the 500ms advisory and 2s hard limit.

## Deviations from Plan

### Auto-fixed Issues

None - plan executed exactly as written with one test parameter adjustment.

**1. Test adjustment — queryTopK radius changed 25m → 80m for the ordering test**
- **Found during:** Task 2 (way_segment_index_test.dart test run)
- **Issue:** Plan specified `queryTopK(k=5, radius=25m)` with 6 parallel segments at 0.0001° (~11m) steps; only 3 segments fall within 25m, test expected 5
- **Fix:** Used radius=80m (covers all 6 segments ~11m apart up to ~55m); k=5 cap still tested correctly
- **Verification:** Test #6 passes: `expect(results.length, 5)` with ascending wayId order confirmed
- **Not a deviation rule trigger** — Pure test geometry correction, no production behavior change

---

**Total deviations:** 0 auto-fixes (1 minor test geometry adjustment, not a code deviation)
**Impact on plan:** No scope changes. The test logic and assertions are faithful to the plan's intent.

## Issues Encountered
- `segment_geometry.dart` (05-02 dependency) was already present on disk from the parallel 05-02 agent; no blocking dependency issue materialized.
- `flutter test test/features/matching/domain/` failed with a sqlite3.dll file-lock error; ran individual test files instead — both green.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `WaySegmentIndex` ready for 05-04 (ViterbiDecoder) — call `queryTopK(lat, lon, radiusMeters, k)` per GPS fix to get candidate segments
- `WaySegment.fromWay` exposed for 05-05 (HMM matcher orchestrator) — use `WaySegmentIndex.buildFromWays(ways)` from `WayCandidateSource`
- `allSegments` accessor enables 05-06 isolate spawn to verify index size before processing
- rbush 1.1.1 locked in pubspec.yaml; no further dep changes needed for the segment-index subsystem

---
*Phase: 05-overpass-matcher-and-golden-corpus*
*Completed: 2026-07-08*
