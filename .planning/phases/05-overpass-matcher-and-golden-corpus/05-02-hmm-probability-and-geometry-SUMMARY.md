---
phase: 05-overpass-matcher-and-golden-corpus
plan: 02
subsystem: matching
tags: [dart, hmm, map-matching, geometry, newson-krumm, log-probability, equirectangular]

# Dependency graph
requires:
  - phase: 03-tracking-mvp
    provides: haversineMeters function for great-circle distance cross-check
  - phase: 04-osm-pipeline
    provides: WayCandidate model (way_candidate.dart) that consumers of these primitives will use
provides:
  - emissionLogProb: log-space Gaussian emission probability (Newson-Krumm 2009)
  - transitionLogProb: log-space exponential transition probability, symmetric under swap
  - adaptiveRadiusMeters: R-Tree query radius helper clamped to [25, 150] m
  - perpDistanceToSegmentMeters: equirectangular perpendicular distance, < 0.1 m error
  - projectionFractionOnSegment: clamped [0,1] fraction for start/end_meters in Viterbi
  - segmentLengthMeters: local-plane segment length
  - Named constants: kEmissionSigmaMeters=4.07, kTransitionBetaMeters=1, kBaseRadiusMeters=25, kMaxRadiusMeters=150
affects:
  - 05-04-viterbi-decoder (consumes emissionLogProb, transitionLogProb, kEmissionSigmaMeters, kTransitionBetaMeters)
  - 05-05-matcher (consumes perpDistanceToSegmentMeters, projectionFractionOnSegment, adaptiveRadiusMeters)
  - 05-08-golden-corpus (will validate/tune kTransitionBetaMeters default)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure-math top-level functions (not classes) for HMM primitives — very_good_analysis const/final compatible"
    - "Log-space probability arithmetic to avoid floating-point underflow on 3600-fix trips"
    - "Equirectangular projection at mean_lat for sub-kilometer WGS84 segments"
    - "flutter_test import in domain unit tests (not package:test) per project convention"
    - "prefer_int_literals compliance: use int literals for double params (Dart coerces in context)"

key-files:
  created:
    - lib/features/matching/domain/hmm_probability.dart
    - lib/features/matching/domain/segment_geometry.dart
    - test/features/matching/domain/hmm_probability_test.dart
    - test/features/matching/domain/segment_geometry_test.dart
  modified: []

key-decisions:
  - "Top-level functions not classes for pure math helpers — avoids unnecessary constructor boilerplate, satisfies very_good_analysis"
  - "kTransitionBetaMeters=1 exposed as const (not baked into formula) — golden corpus 05-08 will validate/tune"
  - "Equirectangular projection (not haversine) for perpendicular distance — matches Newson-Krumm 2009 §III, accurate to < 0.3% for < 200 m segments"
  - "haversineMeters imported for cross-check test only (Test 12), not used in hot path"
  - "prefer_int_literals: const double kTransitionBetaMeters = 1 (not 1.0); Dart coerces int literals to double in const/parameter contexts"
  - "metersPerDegreeLat = 111320 (not 111_320.0) per prefer_int_literals"

patterns-established:
  - "Phase 5 pure-math domain files: no Flutter imports, no I/O, no state — testable with dart test or flutter test interchangeably"
  - "Log-space all HMM primitives: emissionLogProb + transitionLogProb both return double in log-space"
  - "NaN-safe defensive branch in adaptiveRadiusMeters: double.isNaN check before arithmetic"

# Metrics
duration: 10min
completed: 2026-07-08
---

# Phase 5 Plan 02: HMM Probability and Geometry Summary

**Log-space HMM emission/transition probability primitives + equirectangular segment geometry for the Viterbi decoder (05-04) — 38 golden-value tests match Newson-Krumm 2009 formulas to 1e-6 precision**

## Performance

- **Duration:** 10 min
- **Started:** 2026-07-08T19:38:17Z
- **Completed:** 2026-07-08T19:48:52Z
- **Tasks:** 2
- **Files modified:** 4 created

## Accomplishments

- HMM emission + transition probability functions in log-space with 23 golden-value tests covering Newson-Krumm formula correctness, edge cases (sigma=0, beta=0, NaN), and monotonicity properties
- Adaptive R-Tree radius helper clamped to [25, 150] m with NaN-safe defensive branch; 4 named constants exported for downstream decoder (05-04)
- Segment geometry primitives (perpendicular distance, projection fraction, segment length) in equirectangular local-plane approximation with 15 tests at lat=49.7° (Bavaria), including haversine cross-check within ±0.5 m
- Zero Flutter imports in both `lib/` files — pure Dart, testable without Flutter binding

## Task Commits

Each task was committed atomically:

1. **Task 1: HMM emission + transition + adaptive-radius primitives** - `37044f5` (feat)
2. **Task 2: Segment geometry (perp distance, projection fraction, length)** - `d9c061e` (feat)

## Files Created/Modified

- `lib/features/matching/domain/hmm_probability.dart` — emissionLogProb, transitionLogProb, adaptiveRadiusMeters, 4 named constants
- `lib/features/matching/domain/segment_geometry.dart` — perpDistanceToSegmentMeters, projectionFractionOnSegment, segmentLengthMeters, metersPerDegreeLon
- `test/features/matching/domain/hmm_probability_test.dart` — 23 golden-value tests (4 constants + 6 emission + 6 transition + 7 adaptive-radius)
- `test/features/matching/domain/segment_geometry_test.dart` — 15 tests (2 metersPerDeg + 6 perpDist + 4 projFraction + 3 segLen + 1 haversine cross-check)

## Decisions Made

- **Top-level functions not class methods:** `emissionLogProb`, `transitionLogProb`, `adaptiveRadiusMeters` are top-level functions (not a class). `very_good_analysis` rules (`avoid_classes_with_only_static_members`) prefer top-level functions for stateless pure helpers.

- **`kTransitionBetaMeters = 1` as const (not inlined):** The beta default is exposed as a named constant per plan spec. 05-04's decoder takes it as a constructor parameter; 05-08 golden corpus will validate/tune. This is an open research question (#1 in the plan context).

- **Equirectangular, not haversine, for perpendicular distance:** The local-plane approximation (metersPerDegreeLon scaled by cos(mean_lat)) matches Newson-Krumm 2009 §III and is accurate to < 0.3% for German latitudes over sub-kilometer OSM segments. Haversine is imported only for the cross-check test (Test 12).

- **`prefer_int_literals` compliance:** Dart coerces int literals to double in parameter and const contexts. Constants use `const double kBaseRadiusMeters = 25` (not `25.0`). This is the project norm established by the `very_good_analysis` ruleset.

- **`flutter_test` not `package:test` in test files:** All existing tests in the project use `package:flutter_test/flutter_test.dart` (a direct dev_dependency); `package:test` is only a transitive dependency and would trigger `depend_on_referenced_packages`.

## Deviations from Plan

None — plan executed exactly as written. The two code files match the plan's implementation sketches verbatim; the test files cover all 15 (hmm) + 12 (geometry) plan-specified assertions plus additional extras for monotonicity/clamping edge cases.

## Issues Encountered

- **`prefer_int_literals` on numeric constants:** `const double kBaseRadiusMeters = 25.0` fires this lint; fixed by writing `25`. Same for `kMaxRadiusMeters`, `kTransitionBetaMeters`. Dart's const evaluation handles the coercion transparently.
- **`prefer_const_declarations` on local variables:** Local `final mLon = (aLon + bLon) / 2` where all operands are `const` must be declared `const`. Fixed in both test files.
- **Test import:** Initial `package:test/test.dart` import replaced with `package:flutter_test/flutter_test.dart` to satisfy `depend_on_referenced_packages` lint.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `emissionLogProb` + `transitionLogProb` + 4 named constants ready for 05-04 Viterbi decoder
- `perpDistanceToSegmentMeters` + `projectionFractionOnSegment` + `adaptiveRadiusMeters` ready for 05-05 matcher
- `segmentLengthMeters` available for any caller needing local-plane segment length
- No blockers; all functions pure (no I/O, no state, no random)
- Open research item: `kTransitionBetaMeters = 1` — value to be validated by golden corpus (05-08)

---
*Phase: 05-overpass-matcher-and-golden-corpus*
*Completed: 2026-07-08*
