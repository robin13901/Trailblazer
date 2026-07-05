---
id: 03-02
phase: 03-tracking-mvp
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/features/trips/domain/haversine.dart
  - lib/features/trips/domain/trip_fix_input.dart
  - lib/features/trips/domain/trip_fix_ingestor.dart
  - lib/features/trips/domain/trip_fix_batcher.dart
  - lib/features/trips/domain/tracking_state.dart
  - test/features/trips/domain/haversine_test.dart
  - test/features/trips/domain/trip_fix_ingestor_test.dart
  - test/features/trips/domain/trip_fix_batcher_test.dart
  - test/features/trips/domain/fixtures/trip_fixtures.dart
autonomous: true
requirements_addressed: [TRK-05, TRK-08]

must_haves:
  truths:
    - "Ingestor drops any fix with horizontalAccuracy > 25 m and rejects it with reason='accuracy'"
    - "Ingestor enforces 1 Hz cadence — a fix arriving < 900 ms after the last accepted one is rejected with reason='rate_limit'"
    - "A gap of > 5 min AND recovered fix > 500 m from lastKnown emits SplitRequired; a gap of > 5 min but < 500 m emits GapObserved (trip continues)"
    - "finalize() returns TripSummary with passesKeeperThreshold=false when duration<60s OR distance<100m OR bbox-diagonal<50m — dropped micro-trips never reach the repository"
    - "Haversine matches known-fixture distance (Frankfurt→Grebenhain) within 0.5% tolerance"
    - "TripFixBatcher flushes exactly when pending reaches batchSize (default 20) and on explicit flush()"
    - "sealed TrackingState is available with TrackingIdle + TrackingRecording variants (both const-constructable)"
  artifacts:
    - path: "lib/features/trips/domain/trip_fix_ingestor.dart"
      provides: "Pure-Dart TripFixIngestor + IngestorOutcome sealed class"
      contains: "class TripFixIngestor"
    - path: "lib/features/trips/domain/haversine.dart"
      provides: "Great-circle distance function"
      contains: "double haversineMeters"
    - path: "lib/features/trips/domain/trip_fix_batcher.dart"
      provides: "20-fix accumulator with flush()"
      contains: "class TripFixBatcher"
    - path: "lib/features/trips/domain/tracking_state.dart"
      provides: "Sealed TrackingState + Idle/Recording variants"
      contains: "sealed class TrackingState"
    - path: "test/features/trips/domain/trip_fix_ingestor_test.dart"
      provides: "Golden-fixture-backed ingestor test suite"
  key_links:
    - from: "lib/features/trips/domain/trip_fix_ingestor.dart"
      to: "lib/features/trips/domain/haversine.dart"
      via: "top-level import — no `geolocator` dependency"
      pattern: "haversineMeters"
    - from: "test/features/trips/domain/fixtures/trip_fixtures.dart"
      to: "trip_fix_ingestor_test.dart"
      via: "shared golden FixInput lists exercised by all cases"
      pattern: "goldenSuburbanDrive|goldenWithGap|goldenSplitCandidate|goldenParkingLotShuffle"
---

<objective>
Ship the pure-Dart fix pipeline: accuracy filter, 1 Hz rate limit, gap/split detection, keeper-threshold check, Haversine distance, 20-fix batcher, and the sealed TrackingState. All unit-tested, zero FGB dependency, zero native touch.

Purpose: TRK-05 (metadata capture) and TRK-08 (battery-conscious state machine, batched every ~20 fixes) both need this logic to be small, deterministic, and fully covered before Wave 2 wires the FGB event stream to it. The pure-Dart split lets Wave 2 use a `FakeBackgroundGeolocationFacade` in tests.

Output: Six library files + four test files under `lib/features/trips/domain/` and `test/features/trips/domain/`. Zero changes to pubspec, zero changes to native.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/03-tracking-mvp/03-CONTEXT.md
@.planning/phases/03-tracking-mvp/03-RESEARCH.md

# Phase 1 patterns
@lib/core/errors/domain_error.dart
@lib/core/errors/result.dart

# Package name is `auto_explore` — use `package:auto_explore/…` in all imports.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Haversine + FixInput + TrackingState (foundation types)</name>
  <files>
    - lib/features/trips/domain/haversine.dart
    - lib/features/trips/domain/trip_fix_input.dart
    - lib/features/trips/domain/tracking_state.dart
    - test/features/trips/domain/haversine_test.dart
    - test/features/trips/domain/fixtures/trip_fixtures.dart
  </files>
  <action>
    1. `lib/features/trips/domain/haversine.dart`:
       ```dart
       import 'dart:math' as math;

       /// Great-circle distance in meters between two WGS84 points.
       double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
         const earthRadiusMeters = 6371000.0;
         final dLat = _deg2rad(lat2 - lat1);
         final dLon = _deg2rad(lon2 - lon1);
         final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
             math.cos(_deg2rad(lat1)) *
                 math.cos(_deg2rad(lat2)) *
                 math.sin(dLon / 2) *
                 math.sin(dLon / 2);
         final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
         return earthRadiusMeters * c;
       }

       double _deg2rad(double deg) => deg * (math.pi / 180.0);
       ```

    2. `lib/features/trips/domain/trip_fix_input.dart` — the FGB-agnostic fix DTO:
       ```dart
       import 'package:meta/meta.dart';

       @immutable
       class FixInput {
         const FixInput({
           required this.ts,
           required this.lat,
           required this.lon,
           required this.accuracyMeters,
           this.speedMps,
           this.altitudeMeters,
           this.activityType,
           this.uuid,
         });
         final DateTime ts;
         final double lat;
         final double lon;
         final double accuracyMeters;
         final double? speedMps;
         final double? altitudeMeters;
         final String? activityType;
         final String? uuid; // FGB per-fix UUID, for de-duplication
       }
       ```

    3. `lib/features/trips/domain/tracking_state.dart`:
       ```dart
       import 'package:meta/meta.dart';

       @immutable
       sealed class TrackingState {
         const TrackingState();
       }

       final class TrackingIdle extends TrackingState {
         const TrackingIdle();
       }

       final class TrackingRecording extends TrackingState {
         const TrackingRecording({
           required this.tripId,
           required this.startedAt,
           required this.distanceMeters,
           required this.pointCount,
           required this.manuallyStarted,
           this.currentSpeedKmh,
         });
         final int tripId;
         final DateTime startedAt;
         final double distanceMeters;
         final int pointCount;
         final bool manuallyStarted;
         final double? currentSpeedKmh;

         Duration duration(DateTime now) => now.difference(startedAt);
       }
       ```

    4. `test/features/trips/domain/fixtures/trip_fixtures.dart` — golden `FixInput` lists (used by ingestor tests in Task 2):
       - `goldenSuburbanDrive10Fixes` — 10 fixes 1 s apart, accuracy 8 m, ~40 km/h, `activityType: 'in_vehicle'`
       - `goldenWithGap` — 5 fixes → 2-min gap (no fixes) → 5 fixes ~200 m further along the same road (should emit GapObserved, not SplitRequired)
       - `goldenSplitCandidate` — 5 fixes → 6-min gap → recovered fix ~800 m away (SplitRequired)
       - `goldenParkingLotShuffle` — 8 fixes over 40 s within a 30 m bbox (finalize → passesKeeperThreshold=false)
       - `goldenShortDrive45s` — 45 s of fixes at 30 km/h (duration<60 → false)
       - `goldenTinyDistanceCrawl` — 60 fixes, 1 Hz, 1.5 m/s traffic jam moving only 90 m total (distance<100 → false)

    5. `test/features/trips/domain/haversine_test.dart`:
       - Frankfurt (50.1109, 8.6821) → Grebenhain (50.5013, 9.3389) ≈ 61.3 km (verify to ±0.5%). Recompute if a different fixture pair reads more naturally — just document the pair in a comment and hard-code the expected value.
       - Same-point distance = 0.0
       - Small distance (1 arc-second lat ≈ 30.9 m) matches to within 5%.

    Anti-patterns to avoid:
    - Do NOT depend on `geolocator` for `distanceBetween` — this file must be Flutter-independent.
    - Do NOT put the FGB-specific `bg.Location` type in `FixInput` — FGB conversion happens in Wave 2's tracking_service.dart.
    - Do NOT use `withOpacity` anywhere (there's no color code here, but for future readers — STATE.md rule).
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/trips/domain/haversine_test.dart` all green
  </verify>
  <done>
    Haversine + FixInput + TrackingState types available; golden fixture library exists for Task 2 to consume.
  </done>
</task>

<task type="auto">
  <name>Task 2: TripFixIngestor + TripFixBatcher + full test suite</name>
  <files>
    - lib/features/trips/domain/trip_fix_ingestor.dart
    - lib/features/trips/domain/trip_fix_batcher.dart
    - test/features/trips/domain/trip_fix_ingestor_test.dart
    - test/features/trips/domain/trip_fix_batcher_test.dart
  </files>
  <action>
    1. `lib/features/trips/domain/trip_fix_ingestor.dart` — implements the sealed IngestorOutcome hierarchy and the ingest/finalize methods per RESEARCH.md §"Fix Ingestor — Pure Dart, Unit-Testable".

       Contract:
       ```dart
       sealed class IngestorOutcome {
         const IngestorOutcome();
       }
       final class FixAccepted extends IngestorOutcome {
         const FixAccepted({
           required this.lat, required this.lon, required this.ts,
           required this.speedKmh, required this.accuracyMeters,
           this.altitudeMeters, this.motionType,
         });
         final double lat; final double lon; final DateTime ts;
         final double speedKmh; final double accuracyMeters;
         final double? altitudeMeters; final String? motionType;
       }
       final class FixRejected extends IngestorOutcome {
         const FixRejected(this.reason);
         final String reason; // 'accuracy' | 'rate_limit' | 'duplicate'
       }
       final class GapObserved extends IngestorOutcome {
         const GapObserved(this.gapStart, this.gapEnd);
         final DateTime gapStart; final DateTime gapEnd;
       }
       final class SplitRequired extends IngestorOutcome {
         const SplitRequired(this.recovered);
         final FixAccepted recovered;
       }

       class TripFixIngestor {
         TripFixIngestor({
           this.maxAccuracyMeters = 25.0,
           this.minFixIntervalMs = 900,
           Duration? gap,
           this.splitDistanceMeters = 500,
           this.keeperMinSeconds = 60,
           this.keeperMinDistanceMeters = 100,
           this.keeperMinBboxDiagonalMeters = 50,
         }) : gap = gap ?? const Duration(minutes: 5);

         final double maxAccuracyMeters;
         final int minFixIntervalMs;
         final Duration gap;
         final double splitDistanceMeters;
         final int keeperMinSeconds;
         final double keeperMinDistanceMeters;
         final double keeperMinBboxDiagonalMeters;

         IngestorOutcome ingest(FixInput input);
         TripSummaryDraft? finalize({required DateTime startedAt});
       }
       ```

       Implementation notes:
       - Track internal state: `_lastAccepted` (FixAccepted?), `_pointCount`, `_totalDistanceMeters`, `_gapSecondsAccumulated`, `_maxSpeedKmh`, `_bbox` (min/max lat/lon), `_seenUuids` (bounded ring buffer of last 100 UUIDs).
       - Rules in order (short-circuit on first hit):
         1. **De-duplication**: if `input.uuid != null && _seenUuids.contains(uuid)` → `FixRejected('duplicate')`.
         2. **Accuracy filter**: if `input.accuracyMeters > maxAccuracyMeters` → `FixRejected('accuracy')`.
         3. **Rate limit**: if `_lastAccepted != null && input.ts.difference(_lastAccepted.ts).inMilliseconds < minFixIntervalMs` → `FixRejected('rate_limit')`.
         4. **Gap detection**: if `_lastAccepted != null`, compute `dt = input.ts - _lastAccepted.ts`. If `dt > this.gap`:
            - Compute `distance = haversineMeters(_lastAccepted.lat, _lastAccepted.lon, input.lat, input.lon)`.
            - If `distance > splitDistanceMeters` → `SplitRequired(recovered)` — DO NOT update internal running totals from the recovered fix; the caller opens a new trip and feeds it as the first fix of that new trip.
            - Else → accept the fix (see step 5), then also return `GapObserved(_lastAccepted.ts, input.ts)` **instead** of `FixAccepted`. (Choose one — the simpler contract is: emit `GapObserved` on the boundary, then subsequent calls emit `FixAccepted` for the same fix's follow-ups. Alternative: return a compound record. Pick one and document.)
            - Add `dt` (minus 1 s to avoid double-counting the boundary second) to `_gapSecondsAccumulated`.
         5. **Accept**: update `_lastAccepted`, `_pointCount++`, `_totalDistanceMeters +=` haversine distance from prev, update `_bbox`, update `_maxSpeedKmh` using `speedMps * 3.6` (fall back to `distance/dt * 3.6` if `speedMps == null || speedMps < 0`). Compute `speedKmh` for the FixAccepted output the same way. Return `FixAccepted(...)`.

       - `finalize` computes:
         - `durationSeconds` = wall duration from `startedAt` to `_lastAccepted?.ts` **minus** `_gapSecondsAccumulated`
         - `distanceMeters` = `_totalDistanceMeters`
         - `avgSpeedKmh` = `distanceMeters / max(durationSeconds, 1) * 3.6`
         - `maxSpeedKmh` = `_maxSpeedKmh`
         - `bbox` from `_bbox`
         - `bboxDiagonalMeters` = haversine(bboxSW, bboxNE)
         - `passesKeeperThreshold` = NOT (duration < 60 OR distance < 100 OR bboxDiagonal < 50)
         - Return `TripSummaryDraft(pointCount, startedAt, endedAt=_lastAccepted.ts, durationSeconds, distanceMeters, avgSpeedKmh, maxSpeedKmh, bbox..., passesKeeperThreshold)`. If `_pointCount == 0`, return `null`.

       - `TripSummaryDraft` is a local class inside this file (do NOT reuse `TripSummary` from Plan 03-01 — that one is repository-shaped with `autoStopped`, which the ingestor doesn't know about; Wave 2 combines Draft + auto/manual flag into the repo's TripSummary).

    2. `lib/features/trips/domain/trip_fix_batcher.dart`:
       ```dart
       import 'package:auto_explore/features/trips/data/trips_repository.dart';
       // (or a narrower TripPointsSink interface — see note below)

       class TripFixBatcher {
         TripFixBatcher({
           required this.tripId,
           required this.sink,
           this.batchSize = 20,
         });
         final int tripId;
         final TripPointsSink sink; // narrower interface, not the full repo
         final int batchSize;
         final _pending = <TripPointsCompanion>[];

         Future<void> add(TripPointsCompanion p) async {
           _pending.add(p);
           if (_pending.length >= batchSize) await flush();
         }
         Future<void> flush() async {
           if (_pending.isEmpty) return;
           final toSend = List<TripPointsCompanion>.of(_pending);
           _pending.clear();
           await sink.appendPoints(tripId, toSend);
         }
         int get pendingCount => _pending.length;
       }
       ```
       **Sink interface** — to keep tests trivial, define a `TripPointsSink` mixin/interface here:
       ```dart
       abstract interface class TripPointsSink {
         Future<void> appendPoints(int tripId, List<TripPointsCompanion> ps);
       }
       ```
       Have `TripsRepository` (from 03-01) `implement TripPointsSink` — no code change needed if the method signature matches. Test can supply a `_FakeSink` implementing this interface.

    3. `test/features/trips/domain/trip_fix_ingestor_test.dart`:
       - Use the fixtures from Task 1.
       - Cases:
         - accuracy > 25 m → FixRejected('accuracy')
         - two fixes 500 ms apart → second is FixRejected('rate_limit')
         - duplicate UUID → FixRejected('duplicate')
         - `goldenWithGap` (2-min gap, same road) → no SplitRequired emitted
         - `goldenSplitCandidate` (6-min gap + 800 m) → SplitRequired emitted at the gap boundary
         - `goldenParkingLotShuffle` → finalize.passesKeeperThreshold == false (bbox<50 m)
         - `goldenShortDrive45s` → passesKeeperThreshold == false (duration<60)
         - `goldenTinyDistanceCrawl` → passesKeeperThreshold == false (distance<100)
         - `goldenSuburbanDrive10Fixes` → 10 FixAccepted, finalize.avgSpeedKmh within ±5% of 40, maxSpeedKmh close to 40, pointCount == 10, passesKeeperThreshold == true

    4. `test/features/trips/domain/trip_fix_batcher_test.dart`:
       - Fake `TripPointsSink` records `(tripId, list.length)` per call.
       - Feed 19 points → 0 flush calls.
       - Feed 20th → 1 flush of length 20, `pendingCount == 0`.
       - Feed 25 → 1 auto-flush at 20, `pendingCount == 5`.
       - Explicit `flush()` on 5-pending → 1 more sink call of length 5.
       - `flush()` on empty → no sink call.

    Anti-patterns to avoid:
    - Do NOT import `flutter_background_geolocation` here. If you find yourself needing `bg.Location`, put a converter in Wave 2's `tracking_service.dart` and keep the ingestor accepting `FixInput` only.
    - Do NOT store an unbounded `_seenUuids` set — bound at 100 (FIFO or ring); the FGB replay window on resume is small.
    - Do NOT let the ingestor own a `TripsRepository` reference — it emits outcomes; the caller in Wave 2 decides whether to persist.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/trips/domain/` — every test green
    - Total ingestor code ~200-300 lines; test file ~200-300 lines. If either doubles, revisit.
  </verify>
  <done>
    Ingestor emits the four IngestorOutcome variants correctly on the golden fixtures. Batcher flushes on batchSize boundary + explicit flush(). All 9+ test cases pass. Zero FGB references in `lib/features/trips/domain/`.
  </done>
</task>

</tasks>

<verification>
- `flutter analyze` clean
- `flutter test test/features/trips/domain/` all green
- No new pub deps added in this plan (deps are 03-03's job)
- Zero `flutter_background_geolocation` imports under `lib/features/trips/domain/`
- Commit: `feat(03-02): pure-Dart trip fix ingestor + haversine + batcher`
</verification>

<success_criteria>
- 80% of P3 tracking logic is now unit-testable without any device or FGB mock
- Wave 2 has a well-defined seam: convert `bg.Location` → `FixInput`, feed to ingestor, react to `IngestorOutcome`
- Golden fixtures exercised in CI catch regressions on the accuracy / gap / split / keeper rules
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-02-SUMMARY.md`
</output>
