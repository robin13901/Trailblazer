---
phase: 05-overpass-matcher-and-golden-corpus
verified: 2026-07-08T21:26:06Z
status: passed
score: 5/5 must-haves verified
---

# Phase 5: Overpass-Backed Matcher + Golden Corpus - Verification Report

**Phase Goal:** The HMM matcher consumes WayCandidateSource (from Phase 4) to match a confirmed trip polyline to a correct list of driven way intervals, and a CI-runnable golden corpus verifies it.

**Verified:** 2026-07-08T21:26:06Z
**Status:** passed
**Re-verification:** No - initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Main isolate fetches WayCandidateSource.fetchWaysInBbox (cache-first), ships List<WayCandidate> to matcher isolate via MatchJob | VERIFIED | trip_match_coordinator.dart:87-93; match_job.dart:44-51; matcher_isolate.dart:108-117 |
| 2 | Offline pendingRoadData trips block matching until fetch queue drains | VERIFIED | trip_road_fetch_coordinator.dart enqueues offline (lines 127-136); matchCoordinator fires only after transitionToPending (lines 119, 151, 191) |
| 3 | Candidate lookup per GPS fix served by in-memory R-Tree; adaptive radius 25 m base expanding with HDOP; top-5 | VERIFIED | way_segment_index.dart:36-53; hmm_probability.dart:67-73 (25-150 m clamp); viterbi_decoder.dart:119-124 (queryTopK k=kBeamWidth=5) |
| 4 | CI-runnable golden corpus: harness code-complete, 1 synthetic seed committed, 4 real-drive deferred (documented) | VERIFIED | test/features/matching/golden_corpus_test.dart (112 lines); test/fixtures/golden_trips/001_synthetic_straight_east/ (4 files); README.md documents 4 deferred scenarios |
| 5 | Matcher isolate warm + long-lived off UI isolate; Viterbi beam 5; min-speed 15 km/h guard; cancellable; writes driven_way_intervals; raw GPS 30-day retention | VERIFIED | matcher_isolate.dart:88 (Isolate.spawn); kBeamWidth=5; kSpeedGuardKmh=15; cancel(); driven_way_intervals_dao.dart:24-26; trips_repository.dart:155-168 |

**Score:** 5/5 truths verified

---

## Evidence by Truth

**Truth 1 - WayCandidateSource fetch + MatchJob dispatch**

trip_match_coordinator.dart:87-93: _source.fetchWaysInBbox(throwOnError: false) called in onTripReadyForMatching
match_job.dart:27-51: MatchJob carries List<WayCandidate> ways + List<GpsFix> fixes as Sendable fields
matcher_isolate.dart:108-117: MatchJob constructed and sent over _workerPort SendPort

**Truth 2 - Offline blocking**

trip_road_fetch_coordinator.dart:127-136: offline path enqueues row in pending_road_fetches, returns without calling matchCoordinator
matchCoordinator?.onTripReadyForMatching fires only after transitionToPending succeeds (lines 119, 151, 191)
drainQueue applies exponential backoff (5 min/30 min/2 h/12 h/24 h); match triggered only on successful drain

**Truth 3 - R-Tree + adaptive radius + top-5**

way_segment_index.dart:36-53: RBushBase STR-packed bulk load; queryTopK does coarse R-Tree + exact perpendicular ranking
hmm_probability.dart:67-73: adaptiveRadiusMeters = clamp(25 + accuracy/2, 25, 150)
viterbi_decoder.dart:119-124: index.queryTopK(lat, lon, radiusMeters: radius, k: beamWidth) where beamWidth defaults to kBeamWidth=5

**Truth 4 - Golden corpus harness**

test/features/matching/golden_corpus_test.dart: 112 lines; iterates subdirs; loads FixtureWayCandidateSource from ways.json.gz; asserts wayId sequence
test/fixtures/golden_trips/001_synthetic_straight_east/: all 4 required files present; golden test passes
README.md: documents 4 deferred real-drive scenarios (002-005); Phase 5 close-out does not block on those drives

**Truth 5 - Matcher isolate + writes + retention**

matcher_isolate.dart:88: Isolate.spawn(_matcherWorker, _mainPort.sendPort)
matcherIsolateProvider: fire-and-forget start + ref.onDispose(isolate.dispose) (matching_providers.dart:127-134)
viterbi_decoder.dart:33,78: kBeamWidth=5; passed as beamWidth to ViterbiDecoder
viterbi_decoder.dart:39,153-155: kSpeedGuardKmh=15; penalty when fix.speedKmh < 15 and highway in kHighClassHighwaysForSpeedGuard
matcher_isolate.dart:126-129: cancel(tripId) sends _CancelMessage; worker checks cancelled set before each job
driven_way_intervals_dao.dart:24-26: insertBatch via Drift batch()
trips_repository.dart:155-168: sweepRawGpsRetention(retention: Duration(days: 30)) default; app.dart:42 calls on resume

---

## Required Artifacts

| Artifact | Lines | Coverage | Status |
|----------|-------|----------|--------|
| lib/features/matching/domain/hmm_matcher.dart | 222 | 47/47 = 100% | VERIFIED |
| lib/features/matching/domain/viterbi_decoder.dart | 408 | 109/113 = 96.5% | VERIFIED |
| lib/features/matching/domain/hmm_probability.dart | 73 | 13/13 = 100% | VERIFIED |
| lib/features/matching/domain/way_segment_index.dart | 132 | 44/44 = 100% | VERIFIED |
| lib/features/matching/domain/segment_geometry.dart | - | 48/48 = 100% | VERIFIED |
| lib/features/matching/data/match_job.dart | 77 | 3/5 = 60% | VERIFIED |
| lib/features/matching/data/matcher_isolate.dart | 192 | 44/48 = 91.7% | VERIFIED |
| lib/features/matching/data/trip_match_coordinator.dart | 183 | 62/66 = 93.9% | VERIFIED |
| lib/core/db/daos/driven_way_intervals_dao.dart | 40 | 12/12 = 100% | VERIFIED |
| lib/core/db/tables/driven_intervals_table.dart | 15 | - | VERIFIED |
| lib/features/matching/data/matching_providers.dart | 134 | providers wired | VERIFIED |
| lib/app.dart | 56 | lifecycle hooks wired | VERIFIED |
| test/features/matching/golden_corpus_test.dart | 112 | harness | VERIFIED |
| test/fixtures/golden_trips/001_synthetic_straight_east/ | 4 files | seed fixture | VERIFIED |
| tool/check_matcher_coverage.dart | 79 | gate in ci.yml | VERIFIED |

---

## Key Link Verification

| From | To | Via | Status |
|------|----|-----|--------|
| TripRoadFetchCoordinator.onTripStopped | TripMatchCoordinator.onTripReadyForMatching | _matchCoordinator?.onTripReadyForMatching | WIRED (lines 119, 151) |
| TripRoadFetchCoordinator.drainQueue | TripMatchCoordinator.onTripReadyForMatching | _matchCoordinator?.onTripReadyForMatching | WIRED (line 191) |
| TripMatchCoordinator | WayCandidateSource.fetchWaysInBbox | _source.fetchWaysInBbox(...) | WIRED (lines 87-93) |
| TripMatchCoordinator | MatcherIsolate.match | _isolate.match(tripId, fixes, ways) | WIRED (lines 124-128) |
| TripMatchCoordinator._writeIntervals | DrivenWayIntervalsDao.insertBatch | _intervalsDao.insertBatch(companions) | WIRED (lines 145-162) |
| MatcherIsolate._matcherWorker | HmmMatcher.match | matcher.match(fixes: msg.fixes, ways: msg.ways) | WIRED (line 185) |
| HmmMatcher.match | WaySegmentIndex.buildFromWays | WaySegmentIndex.buildFromWays(ways) | WIRED (hmm_matcher.dart:70) |
| ViterbiDecoder.decode | WaySegmentIndex.queryTopK | index.queryTopK(lat, lon, radiusMeters, k) | WIRED (viterbi_decoder.dart:119-124) |
| matcherIsolateProvider | MatcherIsolate | Riverpod Provider with dispose hook | WIRED (matching_providers.dart:127-134) |
| tripMatchCoordinatorProvider | wayCandidateSourceProvider | ref.watch(wayCandidateSourceProvider) | WIRED (matching_providers.dart:110) |
| app.dart resume | tripMatchCoordinatorProvider.processPending | ref.read(...).processPending() | WIRED (app.dart:40) |
| app.dart resume | tripsRepositoryProvider.sweepRawGpsRetention | ref.read(...).sweepRawGpsRetention() | WIRED (app.dart:42) |
| golden_corpus_test.dart | HmmMatcher.match | direct call with FixtureWayCandidateSource | WIRED (golden_corpus_test.dart:56) |
| CI ci.yml | tool/check_matcher_coverage.dart | dart run tool/check_matcher_coverage.dart | WIRED (ci.yml:70-71) |

---

## Requirements Coverage

| Requirement | Status | Evidence |
|-------------|--------|----------|
| MMT-01: WayCandidateSource.fetchWaysInBbox consumed by coordinator | SATISFIED | trip_match_coordinator.dart:87-93 |
| MMT-02: List<WayCandidate> in MatchJob sent to matcher isolate | SATISFIED | match_job.dart:44-51; matcher_isolate.dart:108-117 |
| MMT-03: Offline pendingRoadData trips block matching until fetch drains | SATISFIED | Enqueue path (lines 127-136) holds trips; match fires only after transitionToPending |
| MMT-04: R-Tree candidate lookup; adaptive radius 25 m base; top-5 | SATISFIED | way_segment_index.dart (RBushBase); hmm_probability.dart:67-73; kBeamWidth=5 |
| MMT-05: Unmatched fixes dropped, never force-snapped | SATISFIED | viterbi_decoder.dart returns null for below-threshold fixes; null step flushes interval |
| MMT-06: Matcher off UI isolate in long-lived warm MatcherIsolate | SATISFIED | matcher_isolate.dart:88 (Isolate.spawn) |
| MMT-07: Min-speed 15 km/h guard for motorway/trunk | SATISFIED | viterbi_decoder.dart:39, 153-155 |
| MMT-08: Viterbi lookahead beam >= 5 | SATISFIED | kBeamWidth=5 (viterbi_decoder.dart:33) |
| MMT-09: 1 synthetic seed committed; 4 real-drive deferred to drive-batch | SATISFIED | 001_synthetic_straight_east passes; README.md documents 4 deferred scenarios |
| MMT-10: Raw GPS retained 30 days; sweep on app resume | SATISFIED | trips_repository.dart:155-168; app.dart:42 |
| QUA-02: Core matcher >= 90% line coverage; golden-trip regression in CI | SATISFIED | Domain+DAO coverage 316/337 = 93.8%; tool in ci.yml; corpus passes |

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| lib/features/matching/data/matcher_isolate.dart | 12-13 | TODO(mid-flight-cancel) | Info | Design note for Phase 6; v1 pre-job-start cancellation is complete. Not a stub. |

No blockers or warnings.

---

## Test Results

flutter analyze: No issues found (6.8s)
flutter test test/features/matching/: 161 tests, all passed
flutter test (full suite): 383 tests, all passed
golden_corpus_test.dart: 1 test (001_synthetic_straight_east), passed
Domain + DAO line coverage: 316/337 = 93.8% (QUA-02 threshold 90%)

### Coverage Gate Platform Note

tool/check_matcher_coverage.dart uses forward-slash path patterns and runs correctly on ubuntu-latest (CI). On Windows dev machines the local lcov.info uses backslash separators so the script exits code 2. This is a local-only cosmetic issue; CI gating is unaffected.

Coverage per direct lcov.info inspection: hmm_matcher.dart 47/47=100%; viterbi_decoder.dart 109/113=96.5%; hmm_probability.dart 13/13=100%; way_segment_index.dart 44/44=100%; segment_geometry.dart 48/48=100%; matched_step.dart 6/6=100%; driven_way_interval_draft.dart 6/6=100%; driven_way_intervals_dao.dart 12/12=100%.

---

_Verified: 2026-07-08T21:26:06Z_
_Verifier: Claude (gsd-verifier)_
