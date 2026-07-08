---
id: 05-02
phase: 05-overpass-matcher-and-golden-corpus
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/features/matching/domain/hmm_probability.dart
  - lib/features/matching/domain/segment_geometry.dart
  - test/features/matching/domain/hmm_probability_test.dart
  - test/features/matching/domain/segment_geometry_test.dart
autonomous: true
requirements: [MMT-02, MMT-04, MMT-07]

must_haves:
  truths:
    - "Emission log-probability is a pure function of perpendicular distance (m) and sigma (m); returns a `double` in log-space; matches the Newson-Krumm Gaussian to 6 decimal places against hand-computed reference values."
    - "Transition log-probability is a pure function of route distance (m), great-circle distance (m), and beta (m); returns a `double` in log-space; symmetric under swap of the two endpoints."
    - "`adaptiveRadiusMeters(horizontalAccuracy)` returns 25 m for accuracy ≤ 0 and grows as `25 + acc/2`, clamped to [25, 150]."
    - "`perpDistanceToSegmentMeters(pointLat, pointLon, aLat, aLon, bLat, bLon)` returns the perpendicular metric distance from the point to the segment ab in WGS84, using local-tangent-plane projection (equirectangular scaled by cos(mean lat)); matches known references to ≤ 0.1 m."
    - "`projectionFractionOnSegment(...)` returns the clamped fraction (0..1) along segment ab where the point projects; used later by the matcher to compute start_meters / end_meters."
    - "All functions are pure (no I/O, no state, no random); all tests run in `dart test` without Flutter binding."
  artifacts:
    - path: "lib/features/matching/domain/hmm_probability.dart"
      provides: "emissionLogProb, transitionLogProb, adaptiveRadiusMeters + named constants for defaults (kEmissionSigmaMeters=4.07, kTransitionBetaMeters=1.0, kBaseRadiusMeters=25, kMaxRadiusMeters=150)."
      min_lines: 60
    - path: "lib/features/matching/domain/segment_geometry.dart"
      provides: "perpDistanceToSegmentMeters, projectionFractionOnSegment, segmentLengthMeters, metersPerDegreeLat, metersPerDegreeLon."
      min_lines: 80
    - path: "test/features/matching/domain/hmm_probability_test.dart"
      provides: "≥ 12 hand-computed golden-value tests for emission/transition/adaptive-radius."
      min_lines: 100
    - path: "test/features/matching/domain/segment_geometry_test.dart"
      provides: "≥ 10 tests covering perpendicular distance, projection fraction (clamped at endpoints), segment length, and equirectangular scaling at multiple latitudes."
      min_lines: 100
  key_links:
    - from: "lib/features/matching/domain/segment_geometry.dart"
      to: "lib/features/trips/domain/haversine.dart"
      via: "reuse `haversineMeters` for great-circle distance where the projected-plane approximation is not acceptable"
      pattern: "haversineMeters|import.*haversine"
---

## Goal

Ship the pure-math foundations the Viterbi decoder (05-04) and matcher (05-05) will consume: HMM emission + transition log-probabilities, adaptive-radius helper, and segment-geometry primitives (perpendicular distance, projection fraction, segment length). No I/O, no Flutter binding, no isolate — every function testable by `dart test`.

Locks in research §11 open questions:
- **#1 (β default):** Expose as `kTransitionBetaMeters = 1.0` compile-time constant AND as a required constructor param on the future decoder (05-04). Golden corpus (05-08) will validate/tune.
- **σ_z default:** `kEmissionSigmaMeters = 4.07` (Newson-Krumm 2009). Runtime adaptive sigma is `max(4.07, horizontalAccuracy/2)` — computed at call site by 05-04, not baked in here.

## Context

- Research §2 has the exact log-space formulas for emission + transition and rationale for β / σ_z defaults.
- Great-circle distance already exists: `lib/features/trips/domain/haversine.dart` — reuse `haversineMeters(lat1, lon1, lat2, lon2)`. Do NOT add `latlong2` or any new distance package (research §8 explicitly rules it out).
- Perpendicular distance in WGS84: research §2 + §3 recommend equirectangular projection scaled by `cos(mean_lat)` for the small distances involved (< 200 m). For a point p and segment ab:
  1. Convert lat/lon to local meters using `metersPerDegreeLat ≈ 111320` and `metersPerDegreeLon ≈ 111320 * cos(latRad)`.
  2. Vector projection of ap onto ab; clamp fraction to [0, 1]; measure distance from p to the clamped point.
- No new dependencies. Uses only `dart:math`.
- File layout convention: matcher domain lives under `lib/features/matching/domain/` (already exists: `way_candidate.dart`). Keep files small and single-purpose.
- Test conventions: `flutter test` picks up `test/**/*_test.dart`. Domain-only tests can also run under `dart test` if we avoid Flutter imports — do so.
- `very_good_analysis` will flag any missing `const` constructors, missing final fields, etc. Author top-level functions (not a class) for these pure helpers.

## Tasks

<task type="auto">
  <name>Task 1: HMM probability functions + adaptive radius + defaults</name>
  <files>
    lib/features/matching/domain/hmm_probability.dart
    test/features/matching/domain/hmm_probability_test.dart
  </files>
  <intent>Log-space emission + transition probabilities; adaptive knn radius. Pure math.</intent>
  <action>
    **`lib/features/matching/domain/hmm_probability.dart`:**
    ```dart
    // Phase 5 (Plan 05-02): HMM probability primitives.
    //
    // Newson & Krumm (2009), "Hidden Markov Map Matching Through Noise and
    // Sparseness." All functions return LOG-space probabilities to avoid
    // floating-point underflow on 3600-fix trips.
    //
    // No I/O, no state — these are pure functions. Testable with `dart test`.

    import 'dart:math' as math;

    /// Default emission sigma (Newson-Krumm 2009 empirical value, meters).
    /// Runtime adaptive sigma is `max(kEmissionSigmaMeters, hDop/2)` —
    /// computed at call site in the decoder, not here.
    const double kEmissionSigmaMeters = 4.07;

    /// Default transition beta (meters). Scale factor on the exponential
    /// penalty for |route_dist - great_circle_dist|. Larger β = more
    /// forgiving of route-vs-crow-fly discrepancies. Golden corpus (05-08)
    /// will validate — expose as constructor param on the decoder.
    const double kTransitionBetaMeters = 1.0;

    /// Base R-Tree query radius (meters) — MMT-04.
    const double kBaseRadiusMeters = 25.0;

    /// Upper clamp on adaptive radius (meters).
    const double kMaxRadiusMeters = 150.0;

    /// Emission log-probability: log p(z | c) for GPS fix `z` observed at a
    /// candidate whose perpendicular distance to the way segment is
    /// [perpDistMeters]. Assumes zero-mean Gaussian error with std [sigmaM].
    ///
    /// Returns `-infinity` if sigmaM <= 0.
    double emissionLogProb({
      required double perpDistMeters,
      required double sigmaM,
    }) {
      if (sigmaM <= 0) return double.negativeInfinity;
      // log(1 / (sqrt(2pi) * sigma)) - d^2 / (2 * sigma^2)
      final logNormalizer = -0.5 * math.log(2 * math.pi * sigmaM * sigmaM);
      final exponent = -(perpDistMeters * perpDistMeters) /
          (2 * sigmaM * sigmaM);
      return logNormalizer + exponent;
    }

    /// Transition log-probability: log p(c_j | c_i). Newson-Krumm
    /// exponential on |route_dist - great_circle|. [betaMeters] scales the
    /// penalty — see [kTransitionBetaMeters].
    ///
    /// Returns `-infinity` if betaMeters <= 0.
    double transitionLogProb({
      required double routeDistMeters,
      required double greatCircleMeters,
      required double betaMeters,
    }) {
      if (betaMeters <= 0) return double.negativeInfinity;
      final diff = (routeDistMeters - greatCircleMeters).abs();
      // log(1/beta) - diff/beta
      return -math.log(betaMeters) - diff / betaMeters;
    }

    /// Adaptive R-Tree radius (meters) — MMT-04. 25 m base; grows with
    /// GPS horizontal accuracy; clamped to [25, 150].
    ///
    /// A non-positive or NaN [horizontalAccuracyMeters] yields the base
    /// radius (25 m) — defensive against `double.nan` from some Android
    /// providers.
    double adaptiveRadiusMeters(double horizontalAccuracyMeters) {
      if (horizontalAccuracyMeters.isNaN || horizontalAccuracyMeters <= 0) {
        return kBaseRadiusMeters;
      }
      final r = kBaseRadiusMeters + horizontalAccuracyMeters / 2.0;
      return r.clamp(kBaseRadiusMeters, kMaxRadiusMeters);
    }
    ```

    **Tests (`test/features/matching/domain/hmm_probability_test.dart`)** — ≥ 12 golden-value assertions:
    1. `emissionLogProb(perpDist=0, sigma=4.07)` = `-log(sqrt(2π) * 4.07)` ≈ `-2.3226`. Assert ±1e-6.
    2. `emissionLogProb(perpDist=4.07, sigma=4.07)` = `-log(sqrt(2π)*4.07) - 0.5` ≈ `-2.8226`. Assert ±1e-6.
    3. `emissionLogProb` decreases monotonically as `perpDist` grows.
    4. `emissionLogProb(sigma=0)` = `-infinity` (defensive).
    5. `emissionLogProb(sigma<0)` = `-infinity`.
    6. `transitionLogProb(routeDist=100, gc=100, beta=1)` = `-log(1) - 0 = 0`. (Perfect match.)
    7. `transitionLogProb(routeDist=105, gc=100, beta=1)` = `-log(1) - 5 = -5`.
    8. `transitionLogProb` is symmetric under swap of routeDist/gc.
    9. `transitionLogProb` monotonically decreases as `|route-gc|` grows.
    10. `transitionLogProb(beta=0)` = `-infinity`.
    11. `adaptiveRadius(-5)` = 25 (defensive on non-positive).
    12. `adaptiveRadius(double.nan)` = 25 (defensive on NaN).
    13. `adaptiveRadius(0)` = 25 (base).
    14. `adaptiveRadius(50)` = 50 (25 + 25).
    15. `adaptiveRadius(1000)` = 150 (upper clamp).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/domain/hmm_probability_test.dart
    ```
    Analyze clean; all 15 probability tests green.
  </verify>
  <done>All log-space functions match hand-computed reference values to ±1e-6; adaptive radius honors both clamps and NaN.</done>
</task>

<task type="auto">
  <name>Task 2: Segment geometry primitives (perpendicular distance + projection fraction)</name>
  <files>
    lib/features/matching/domain/segment_geometry.dart
    test/features/matching/domain/segment_geometry_test.dart
  </files>
  <intent>Local-tangent-plane geometry: distance from point to segment + fractional projection.</intent>
  <action>
    **`lib/features/matching/domain/segment_geometry.dart`:**
    ```dart
    // Phase 5 (Plan 05-02): Segment geometry primitives.
    //
    // Uses equirectangular projection scaled by cos(mean_lat) — accurate to
    // < 0.3 % for German latitudes over sub-kilometer segments (Newson-Krumm
    // 2009 §III uses the same approximation). For anything larger than a
    // single OSM segment (~100 m), use haversineMeters from
    // `lib/features/trips/domain/haversine.dart` instead.

    import 'dart:math' as math;

    /// Meters per degree of latitude at any latitude (roughly constant on WGS84).
    const double metersPerDegreeLat = 111320.0;

    /// Meters per degree of longitude at latitude [latDeg].
    double metersPerDegreeLon(double latDeg) =>
        metersPerDegreeLat * math.cos(latDeg * math.pi / 180.0);

    /// Perpendicular distance in meters from point p to segment ab, measured
    /// via projection to a local equirectangular plane centered at the mean
    /// latitude of a and b. If p projects outside [a, b], the distance to the
    /// nearer endpoint is returned.
    double perpDistanceToSegmentMeters({
      required double pLat,
      required double pLon,
      required double aLat,
      required double aLon,
      required double bLat,
      required double bLon,
    }) {
      final meanLat = (aLat + bLat) / 2.0;
      final mLon = metersPerDegreeLon(meanLat);
      const mLat = metersPerDegreeLat;

      final ax = aLon * mLon;
      final ay = aLat * mLat;
      final bx = bLon * mLon;
      final by = bLat * mLat;
      final px = pLon * mLon;
      final py = pLat * mLat;

      final dx = bx - ax;
      final dy = by - ay;
      final lenSq = dx * dx + dy * dy;
      if (lenSq == 0) {
        // Degenerate segment; distance to point a.
        final ex = px - ax;
        final ey = py - ay;
        return math.sqrt(ex * ex + ey * ey);
      }

      // Vector projection fraction, clamped so distance-to-endpoint is used
      // when the point projects beyond the segment.
      var t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
      if (t < 0) t = 0;
      if (t > 1) t = 1;

      final cx = ax + t * dx;
      final cy = ay + t * dy;
      final ex = px - cx;
      final ey = py - cy;
      return math.sqrt(ex * ex + ey * ey);
    }

    /// Projection fraction of point p onto segment ab, clamped to [0, 1].
    /// 0.0 = point projects onto a; 1.0 = onto b; values in between = along
    /// the segment.
    double projectionFractionOnSegment({
      required double pLat,
      required double pLon,
      required double aLat,
      required double aLon,
      required double bLat,
      required double bLon,
    }) {
      final meanLat = (aLat + bLat) / 2.0;
      final mLon = metersPerDegreeLon(meanLat);
      const mLat = metersPerDegreeLat;

      final ax = aLon * mLon;
      final ay = aLat * mLat;
      final bx = bLon * mLon;
      final by = bLat * mLat;
      final px = pLon * mLon;
      final py = pLat * mLat;

      final dx = bx - ax;
      final dy = by - ay;
      final lenSq = dx * dx + dy * dy;
      if (lenSq == 0) return 0.0;

      var t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      return t;
    }

    /// Length of the segment ab in meters (local plane).
    double segmentLengthMeters({
      required double aLat,
      required double aLon,
      required double bLat,
      required double bLon,
    }) {
      final meanLat = (aLat + bLat) / 2.0;
      final mLon = metersPerDegreeLon(meanLat);
      const mLat = metersPerDegreeLat;
      final dx = (bLon - aLon) * mLon;
      final dy = (bLat - aLat) * mLat;
      return math.sqrt(dx * dx + dy * dy);
    }
    ```

    **Tests (`test/features/matching/domain/segment_geometry_test.dart`)** — ≥ 10 assertions:
    1. `metersPerDegreeLon(0)` ≈ 111320 (equator).
    2. `metersPerDegreeLon(49.7)` ≈ 71920 (Bavaria) within ±100 m.
    3. `perpDistance` on a point exactly on the segment ≈ 0 (< 0.01 m).
    4. `perpDistance` on a point 10 m perpendicular offset ≈ 10 m within ±0.1 m — use `(aLat=49.7, aLon=9.0, bLat=49.7, bLon=9.001)` (a ~72 m east-west segment) and pLat = 49.7 + 10 / 111320.
    5. `perpDistance` for point beyond segment endpoint = distance to that endpoint.
    6. `perpDistance` with degenerate segment (a == b) = point-to-a distance.
    7. `projectionFraction` at midpoint of segment = 0.5 ± 1e-3.
    8. `projectionFraction` clamped to 0 when point projects before a.
    9. `projectionFraction` clamped to 1 when point projects past b.
    10. `segmentLength` of a 100-m east-west segment ≈ 100 ± 0.5 m.
    11. `segmentLength` of a 100-m north-south segment ≈ 100 ± 0.5 m.
    12. `perpDistance` cross-check against haversine: a point 15 m north of a horizontal segment gives `perpDistance ≈ haversineMeters(p, closest_on_segment)` within ±0.5 m.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/domain/segment_geometry_test.dart
    ```
    Analyze clean; all 12 geometry tests green.
  </verify>
  <done>Perpendicular distance + projection fraction + segment length verified at three latitudes with hand-computed references.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- 27+ pure-math tests green across the two files.
- No Flutter imports in either `lib/` file — verify: `grep -l 'package:flutter' lib/features/matching/domain/hmm_probability.dart lib/features/matching/domain/segment_geometry.dart` returns nothing.
- Named constants (`kEmissionSigmaMeters`, `kTransitionBetaMeters`, `kBaseRadiusMeters`, `kMaxRadiusMeters`) are exported for the decoder in 05-04.

## Ralph Loop

- Tight loop: `flutter analyze`.
- Behavior-sensitive (all math is testable): `flutter test test/features/matching/domain/` after each task.

## Commit Strategy

- Task 1 commit: `feat(05-02): HMM emission + transition + adaptive-radius primitives`
- Task 2 commit: `feat(05-02): segment geometry (perp distance, projection fraction, length)`
