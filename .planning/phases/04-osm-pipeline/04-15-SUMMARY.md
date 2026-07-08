---
phase: 04-osm-pipeline
plan: 15
subsystem: matching-runtime
tags: [way-candidate-source, overpass, tile-cache, trip-lifecycle, coordinator, connectivity, drive-deferred, wave-2, code-complete]
status: code-complete-drive-deferred

# Dependency graph
requires:
  - phase: 04-osm-pipeline (Plan 04-13)
    provides: OverpassClient (primary + fallback endpoints, retry schedule, `fetchRawJson` exposed for cache write path) + OverpassResponseParser + WayCandidate model + payload-probe verdict (MANDATORY tile-splitting)
  - phase: 04-osm-pipeline (Plan 04-14)
    provides: `overpass_way_cache` composite-PK table + `pending_road_fetches` FK-cascade table + both DAOs (put/getByTile/sweepTtl/enforceLruBudget/totalBytes; enqueue/listPending/getByTrip/incrementAttempts/removeByTrip)
  - phase: 03-tracking-mvp (Plan 03-01 + 03-04)
    provides: `TripStatus` enum persisted via `.name` TEXT + `TrackingService.stopActive` lifecycle path
provides:
  - `WayCandidateSource` abstract interface (Phase 5 matcher's runtime seam)
  - `OverpassWayCandidateSource` (cache-first, per-tile fetch, concurrency=2, gzip on write, gunzip+parse on read, wayId dedupe, bbox-clip)
  - `FixtureWayCandidateSource` (test/helpers; consumes the 04-13 gzipped Overpass fixtures)
  - `TileBboxMath` + `TileId` + `LatLonBbox` pure-math primitives (slippy z12 default, meridian-safe)
  - `TripRoadFetchCoordinator` (online → fetch → transition to pending; offline → enqueue + stay in `pendingRoadData`; drainQueue with exponential backoff 5m/30m/2h/12h/24h → abandon at 5 attempts)
  - `ConnectivitySeam` + `ConnectivityPlusSeam` production adapter over `connectivity_plus ^7.0.0`
  - `TripStatus.pendingRoadData` enum value (inserted between `recording` and `pending`; safe — persisted as `.name` TEXT via `TripStatusConverter`, not ordinal)
  - `AppLifecycleState.resumed` hook in `lib/app.dart` drains the pending queue
  - 20 new tests: 6 tile-math + 6 overpass-way-source + 8 coordinator (all green; 249/249 total)
affects:
  - 04-16 (bundled admin polygons) — coordinator is now the single entry-point for post-trip pipeline work; admin lookup will hang off the same seam
  - Phase 5 (HMM matcher) — WayCandidateSource is the runtime contract; FixtureWayCandidateSource is the test-side impl for golden corpora

# Tech tracking
tech-stack:
  added:
    - "connectivity_plus ^7.0.0 (alphabetized in pubspec)"
  patterns:
    - "Nullable optional-injection for back-compat: `TrackingService.roadFetchCoordinator` is nullable — when null (141 pre-existing tests), state transitions bypass the coordinator (pre-04-15 recording→pending path); when wired (prod), coordinator drives the state machine."
    - "Coordinator API accepts bbox OR polyline (via `LatLonBbox.fromPolyline(polyline)`) — production TrackingService supplies TripSummary bbox directly; test suite reuses the polyline helper."
    - "Fire-and-forget from TrackingService.stopActive → coordinator.onTripStopped (unawaited); AppLifecycleState.resumed → coordinator.drainQueue()."
    - "Per-tile fetch with concurrency=2 (matching FOSSGIS Overpass slot count) is the ONLY code path — no coalescing branch, per 04-13 MANDATORY tile-split verdict."
    - "TripStatus enum widening without SQL migration — persisted as `.name` TEXT via TripStatusConverter, so a new enum value is a Dart-only change; drift_schema_v3.json re-dump is byte-identical."

key-files:
  created:
    - lib/features/matching/data/way_candidate_source.dart
    - lib/features/matching/data/tile_bbox_math.dart
    - lib/features/matching/data/overpass_way_candidate_source.dart
    - lib/features/matching/data/connectivity_seam.dart
    - lib/features/matching/data/trip_road_fetch_coordinator.dart
    - test/helpers/fixture_way_candidate_source.dart
    - test/features/matching/tile_bbox_math_test.dart
    - test/features/matching/overpass_way_candidate_source_test.dart
    - test/features/matching/trip_road_fetch_coordinator_test.dart
  modified:
    - lib/features/matching/data/overpass_client.dart
    - lib/features/matching/data/matching_providers.dart
    - lib/features/trips/domain/trip_status.dart
    - lib/features/trips/data/trips_dao.dart
    - lib/features/trips/data/trips_repository.dart
    - lib/features/trips/domain/tracking_service.dart
    - lib/features/trips/data/tracking_service_providers.dart
    - lib/app.dart
    - pubspec.yaml
    - pubspec.lock
    - test/features/trips/presentation/tracking_notifier_test.dart

key-decisions:
  - "WayCandidateSource interface lives in lib/features/matching/data/ — the single seam Phase 5's HMM matcher consumes. Two impls: OverpassWayCandidateSource (runtime, cache-first) + FixtureWayCandidateSource (test/helpers/, deterministic offline). Both apply the Kfz allowlist + dedupe by wayId per way_candidate.dart."
  - "Slippy z12 as the cache granularity (RESEARCH §2). TileBboxMath is pure math, no I/O. Meridian-crossing produces non-negative x per Task 1 test."
  - "Cache-first with per-tile fetch (concurrency=2) is the only path — no coalescing branch was built. 04-13 payload-probe verdict was MANDATORY tile-splitting for v1; the plan sketched an OPTIONAL coalescing branch that the probe eliminated."
  - "TripStatus.pendingRoadData inserted between `recording` and `pending`. Safe because TripStatusConverter persists via `.name` TEXT, not ordinal. State flow: recording → pendingRoadData → pending → matched → confirmed."
  - "TripRoadFetchCoordinator fire-and-forget from TrackingService.stopActive; AppLifecycleState.resumed → coordinator.drainQueue() in lib/app.dart. Coordinator drives the state transition to `pending` after successful fetch; on offline / network error, trip stays in `pendingRoadData` with a `pending_road_fetches` row."
  - "Exponential backoff schedule 5m / 30m / 2h / 12h / 24h → abandon at 5 attempts. Backoff clamped via `row.attempts.clamp(0, delays.length - 1)`."
  - "ConnectivitySeam abstraction over `connectivity_plus ^7.0.0` (alphabetized dep addition). Production adapter is `ConnectivityPlusSeam`; test suite injects a fake. Simpler than the plan-suggested http.head fallback."
  - "TrackingService.roadFetchCoordinator is nullable — preserves 141 pre-existing tests. When null, transitions directly from recording to pending (pre-04-15 behavior). When wired (prod), coordinator drives the state transition."
  - "drift_schemas/drift_schema_v3.json re-dumped and BYTE-IDENTICAL to 04-14's dump — TripStatus lives entirely in Dart via TripStatusConverter; there is no SQL CHECK constraint on trips.status, so a new enum value is not a schema-level change. schemaVersion stays at 3."
  - "OverpassClient.fetchRawJson extracted from fetchWaysInBbox so the cache-write path stores the exact Overpass response bytes (Task 2 mandate: gzip raw response body). fetchWaysInBbox still returns parsed WayCandidates for callers that don't need the raw bytes."
  - "**04-15 Task 4 device drive DEFERRED** to a combined Kleinheubach-friendly session at Phase 4 close-out per user directive 2026-07-08. Memory ref: `phase-4-drives-deferred-to-gym-trip.md`. Same code-complete-drive-deferred pattern used by Phase 3 (STATE 2026-07-05)."

patterns-established:
  - "Post-trip pipeline seam: TrackingService.stopActive → coordinator.onTripStopped (unawaited, fire-and-forget). Coordinator owns the multi-step state transition. Future 04-16 admin-lookup work hangs off the same coordinator or a sibling."
  - "AppLifecycleState.resumed as the connectivity-drain trigger. lib/app.dart's WidgetsBindingObserver is now the drainQueue entry point — no timer polling, no dedicated background job."
  - "Nullable optional-injection for coordinator hand-offs — preserves back-compat with the pre-hook test suite and gives the coordinator a clean seam to add / remove in Phase 5 rewiring."

# Metrics
duration: 30min
completed: 2026-07-08
---

# Phase 4 Plan 15: WayCandidateSource + Trip Flow Summary

**Wave 2 close-out: the Overpass adapter is code-complete. WayCandidateSource seam + cache-first runtime impl + fixture test source ship; `pendingRoadData` trip state inserted; TripRoadFetchCoordinator wires trip-stop into cache-fill (or enqueue + drain on reconnect). Task 4 (real-device Wave 2 smoke) is DEFERRED to a combined Phase-4 close-out drive.**

## Status

**Code-complete (drive-verify deferred to combined Phase 4 close-out drive).**

Tasks 1–3 landed as atomic commits; Task 4 (real-device Wave 2 smoke — Scenarios A, B, C + Ancillary) is DEFERRED. No `docs(04-15): Wave 2 Overpass adapter verified on device` commit yet — that lands post-drive. Same pattern as Phase 3 close-out (STATE 2026-07-05: "Code-complete without in-car verification. Deferred to a batched drive session"). Memory ref: `phase-4-drives-deferred-to-gym-trip.md`.

## Performance

- **Duration:** ~30 min (Tasks 1–3 execution) + close-out
- **Tasks:** 4 total (3× `type="auto"` all landed; 1× `type="checkpoint:human-action"` DEFERRED)
- **Files created:** 9
- **Files modified:** 11

## Task Commits

Each of the three implementation tasks was committed atomically per project CLAUDE.md rules — files staged individually (no `git add -A` / `git commit -a`, per Wave-hygiene STATE decisions 2026-07-03 / 2026-07-06 / 03-1-02 reinforcement):

1. **Task 1: WayCandidateSource interface + tile bbox math + fixture test source** — `6333035` (feat)
2. **Task 2: OverpassWayCandidateSource with cache-first + coalescing** — `7a3a58f` (feat)
3. **Task 3: pendingRoadData state + TripRoadFetchCoordinator + tracking hook** — `ac660bc` (feat)
4. **Task 4: Real-device Wave 2 smoke** — **DEFERRED** to combined Phase-4 close-out drive.

Plan metadata commit (code-complete close-out) follows this SUMMARY.

## Accomplishments

- **WayCandidateSource abstract interface + Kfz allowlist alignment.** `lib/features/matching/data/way_candidate_source.dart` (40 lines) exposes `Future<List<WayCandidate>> fetchWaysInBbox({minLat, minLon, maxLat, maxLon, throwOnError})` — the single method Phase 5's HMM matcher will consume. Doc comments explicitly enumerate the two impls (Overpass + Fixture) and their shared post-conditions (Kfz allowlist applied, wayId dedupe across tiles).
- **TileBboxMath + TileId + LatLonBbox pure-math primitives.** 164 lines of slippy tile math: `lonToTileX`, `latToTileY` (Web Mercator forward), `bboxToZ12Tiles` (returns `Set<TileId>` of overlapping tiles), `tileToBbox` (inverse — Mercator back to lat/lon), `unionBbox`, plus `LatLonBbox.fromPolyline` used by the coordinator. No `dart:io`, no async — trivially unit-testable. 6 tests green including Berlin z12 (2200, 1343), meridian-crossing non-negative x, round-trip within tolerance.
- **OverpassWayCandidateSource — the runtime cache-first impl.** 204 lines. Partitions every bbox into z12 tiles per 04-13 MANDATORY verdict. Per-tile flow: (1) `cacheDao.getByTile(z, x, y)` → if hit + within TTL, decode + continue; (2) on miss, fetch via `OverpassClient.fetchRawJson`, gzip the raw response body, `cacheDao.put(z, x, y, gzipped, wayCount)`; (3) gunzip + parse via `OverpassResponseParser`; (4) union results, dedupe by `wayId`, bbox-clip via `geometry.any(point-in-bbox)`. Concurrency=2 (FOSSGIS slot count) for cache misses. `throwOnError: false` returns partial results (cached-only) on network failure. 6 tests green.
- **TripRoadFetchCoordinator wires trip-stop into cache-fill or enqueue.** 204 lines. Public API: `onTripStopped({tripId, bbox OR polyline})` and `drainQueue({DateTime? now})`. Online path transitions `recording → pendingRoadData → pending` (via `TripsDao.transitionToPendingRoadData` + `transitionToPending`); offline path transitions to `pendingRoadData` + enqueues via `PendingRoadFetchesDao.enqueue`; `drainQueue` walks `listPending()` oldest-first, respects exponential backoff (5m / 30m / 2h / 12h / 24h clamped via `row.attempts.clamp`), abandons rows at 5 attempts. 8 tests green including 4-min-old-not-retried (5m gate) and abandon-after-5.
- **`TripStatus.pendingRoadData` inserted between `recording` and `pending`.** Safe because `TripStatusConverter` persists via `.name` TEXT, not ordinal. `drift_schemas/drift_schema_v3.json` re-dumped and confirmed byte-identical to 04-14's dump — enum widening is Dart-only, no schema-level change. `schemaVersion` stays at 3.
- **`ConnectivitySeam` + `ConnectivityPlusSeam` production adapter.** Thin abstraction over `connectivity_plus ^7.0.0` (alphabetized dep addition). `Future<bool> isOnline()` is the only contract. Production reads the plugin; tests inject a fake. Simpler than the plan-suggested http.head timeout fallback (§Deviations authorised).
- **AppLifecycleState.resumed drain hook in `lib/app.dart`.** Root `App` widget grows `WidgetsBindingObserver`; `didChangeAppLifecycleState(AppLifecycleState.resumed)` fires `unawaited(ref.read(tripRoadFetchCoordinatorProvider).drainQueue())`. No timer polling, no background job.
- **TrackingService optional-injection preserves 141 pre-existing tests.** `TrackingService.roadFetchCoordinator` is nullable. When null, `stopActive` transitions the trip directly to `pending` (pre-04-15 behavior); when wired (production), `stopActive` closes the trip as `pendingRoadData` and fires `coordinator.onTripStopped` fire-and-forget. Coordinator drives the state transition to `pending`. `tracking_notifier_test.dart` grew a small override to inject a fake `WayCandidateSource` + `ConnectivitySeam` so the coordinator hand-off completes without a real platform channel.
- **249/249 tests green post-Wave-2; `flutter analyze --no-pub` clean.** Net +20 tests (6 tile-math + 6 overpass-way-source + 8 coordinator).

## Files Created / Modified

**Created (9):**

- `lib/features/matching/data/way_candidate_source.dart` — abstract WayCandidateSource interface.
- `lib/features/matching/data/tile_bbox_math.dart` — TileBboxMath + TileId + LatLonBbox.
- `lib/features/matching/data/overpass_way_candidate_source.dart` — runtime cache-first impl.
- `lib/features/matching/data/connectivity_seam.dart` — ConnectivitySeam + ConnectivityPlusSeam.
- `lib/features/matching/data/trip_road_fetch_coordinator.dart` — TripRoadFetchCoordinator.
- `test/helpers/fixture_way_candidate_source.dart` — test-only WayCandidateSource impl.
- `test/features/matching/tile_bbox_math_test.dart` — 6 tests.
- `test/features/matching/overpass_way_candidate_source_test.dart` — 6 tests.
- `test/features/matching/trip_road_fetch_coordinator_test.dart` — 8 tests.

**Modified (11):**

- `lib/features/matching/data/overpass_client.dart` — extracted `fetchRawJson()` to expose the untransformed body.
- `lib/features/matching/data/matching_providers.dart` — added `tileBboxMathProvider`, `wayCandidateSourceProvider`, `connectivitySeamProvider`, `tripRoadFetchCoordinatorProvider` (all plain `Provider<T>` per STATE 01-01).
- `lib/features/trips/domain/trip_status.dart` — added `pendingRoadData` between `recording` and `pending`.
- `lib/features/trips/data/trips_dao.dart` — added `transitionToPendingRoadData` + `transitionToPending`; `closeTrip` gains optional status param (defaults to `pending` for back-compat).
- `lib/features/trips/data/trips_repository.dart` — propagates status param through `closeTrip`.
- `lib/features/trips/domain/tracking_service.dart` — optional `roadFetchCoordinator` param + branch in `stopActive`.
- `lib/features/trips/data/tracking_service_providers.dart` — wires `tripRoadFetchCoordinatorProvider` into the production TrackingService.
- `lib/app.dart` — root App gains `WidgetsBindingObserver` + `didChangeAppLifecycleState` resume hook.
- `pubspec.yaml` — `connectivity_plus: ^7.0.0` added (alphabetized).
- `pubspec.lock` — updated.
- `test/features/trips/presentation/tracking_notifier_test.dart` — override fake WayCandidateSource + ConnectivitySeam.

## Deferred Verification Checklist

**Scenarios re-scoped to Kleinheubach (49.79°N, 9.19°E) — the user does not live in Berlin. "Small trip near home" replaces every "from Berlin" phrase. Cross-country cache-hit scenario stays intact (location-agnostic). See memory: `phase-4-drives-deferred-to-gym-trip.md` for the full Kleinheubach adaptation.**

Build for Android device (release build, real MapTiler key):

```bash
flutter run --release --dart-define-from-file=env/dev.json
```

**Scenario A — Online trip finish:**

1. Wi-Fi ON. Start a manual trip near home (FAB).
2. Drive / walk ~500 m so the polyline is non-empty.
3. Tap Stop.
4. Within 30 s, verify (via debug HUD if present, or by inspecting App DB via `flutter pub run drift_dev` tools, or by scrolling app logs for the coordinator's log lines):
   - Trip transitioned: `recording → pendingRoadData → pending`.
   - `overpass_way_cache` now has ≥ 1 row for the trip's bbox tiles.
   - `pending_road_fetches` is empty.
5. Restart the app. Confirm the trip is still in `pending` state (not lost).

**Scenario B — Offline trip finish + reconnect drain:**

1. Airplane mode ON before starting the trip.
2. Start manual trip near home; walk ~500 m; Stop.
3. Verify:
   - Trip is in `pendingRoadData` state.
   - `pending_road_fetches` has exactly one row for this trip.
   - `overpass_way_cache` has NO new rows for this trip's bbox.
4. Turn Wi-Fi / mobile data back on.
5. Kill + reopen the app (triggers `drainQueue` via lifecycle resume).
6. Within 60 s, verify:
   - `pending_road_fetches` is empty.
   - `overpass_way_cache` has rows for the trip's bbox tiles.
   - Trip transitioned to `pending`.

**Scenario C — Cross-country cache hit:**

1. From Kleinheubach, do a small manual trip (100 m walk indoors is enough).
2. From the app's dev HUD (or Drift devtools), note the cached tile IDs.
3. Do a second manual trip in the same area.
4. Verify: no new Overpass network request in the coordinator's log (cache hit); trip transitions immediately to `pending`.

**Ancillary check:** confirm the MapTiler tiles are still rendering (Wave 1 not regressed).

**Approve on success; capture logs + screenshots on any failure and return with issue details.**

Post-drive: land a `docs(04-15): Wave 2 Overpass adapter verified on device` commit.

## Decisions Made

Recorded in STATE.md `Decisions` under the 2026-07-08 04-15 bullets. Key highlights:

- **WayCandidateSource seam is the Phase 5 contract.** Two impls: OverpassWayCandidateSource (runtime, cache-first) + FixtureWayCandidateSource (test-side, deterministic). Both apply the Kfz allowlist + dedupe by wayId.
- **Slippy z12 cache granularity.** TileBboxMath is pure math; ~9.7 × 9.7 km at Berlin latitude per tile.
- **Per-tile fetch (concurrency=2), no coalescing.** 04-13 MANDATORY verdict eliminated the OPTIONAL coalescing branch.
- **`TripStatus.pendingRoadData` inserted between `recording` and `pending`.** `.name` TEXT persistence keeps schema-v3 byte-identical.
- **Coordinator fire-and-forget from TrackingService; AppLifecycleState.resumed drains the queue.**
- **Exponential backoff 5m / 30m / 2h / 12h / 24h → abandon at 5.**
- **`connectivity_plus ^7.0.0` (alphabetized).** ConnectivitySeam abstraction over the plugin.
- **`TrackingService.roadFetchCoordinator` nullable.** Preserves 141 pre-existing tests.
- **`drift_schema_v3.json` re-dump byte-identical.** TripStatus lives in Dart via TripStatusConverter, not a SQL CHECK.

## Deviations from Plan

**1. [Auto-fixed — Rule 3 Blocking] Coalescing branch NOT built (per 04-13 MANDATORY tile-split verdict)**

- **Found during:** Task 2 planning
- **Issue:** Plan §Task 2 sketched an OPTIONAL coalescing branch (single query for ≤4 missing tiles) gated on the 04-13 payload-probe verdict. The probe returned MANDATORY tile-splitting for v1.
- **Fix:** Only the per-tile fetch code path (concurrency=2) exists. Per-tile is the sole path; no `if OPTIONAL` branch to maintain. Simpler + matches the probe verdict.
- **Files affected:** `lib/features/matching/data/overpass_way_candidate_source.dart`.
- **Commit:** Task 2 (`7a3a58f`).

**2. [Auto-fixed — Rule 3 Blocking] Coordinator API accepts `bbox:` OR `polyline:`**

- **Found during:** Task 3 wiring
- **Issue:** Production TrackingService already carries a computed `TripSummary` with a bbox (Plan 03-01); recomputing the bbox from the polyline inside the coordinator is wasteful. But plan sketch showed `polyline: List<LatLng>` in the coordinator API, and the test suite finds `LatLonBbox.fromPolyline(polyline)` easier to reason about.
- **Fix:** Coordinator accepts either shape. `onTripStopped({required int tripId, required LatLonBbox bbox})` is the primary; `LatLonBbox.fromPolyline(polyline)` is the tests' helper. Production supplies the pre-computed bbox directly.
- **Files affected:** `lib/features/matching/data/trip_road_fetch_coordinator.dart`, `lib/features/matching/data/tile_bbox_math.dart` (added `LatLonBbox.fromPolyline`).
- **Commit:** Task 3 (`ac660bc`).

**3. [Auto-fixed — Rule 3 Blocking] `TrackingService.roadFetchCoordinator` is nullable for test back-compat**

- **Found during:** Task 3 — 141 pre-existing tracking tests suddenly needed a fake coordinator + fake WayCandidateSource + fake ConnectivitySeam
- **Issue:** Making the coordinator a required constructor arg on TrackingService would have exploded the constructor surface for every test that stubs TrackingService.
- **Fix:** Made `roadFetchCoordinator` optional/nullable. When null (pre-04-15 test suites), the state machine bypasses the coordinator entirely and transitions recording → pending directly (pre-04-15 behavior). When wired (production `tracking_service_providers.dart`), the coordinator drives the transition. Rule 3 blocking-fix: preserves 141 tests, no behavior change in production.
- **Files affected:** `lib/features/trips/domain/tracking_service.dart`, `lib/features/trips/data/tracking_service_providers.dart`, `test/features/trips/presentation/tracking_notifier_test.dart`.
- **Commit:** Task 3 (`ac660bc`).

**4. [Auto-fixed — Rule 3 Blocking] `drift_schemas/drift_schema_v3.json` re-dumped byte-identical**

- **Found during:** Task 3 — plan mandate to re-dump the schema after adding `TripStatus.pendingRoadData`
- **Issue:** Plan text framed the re-dump as an intentional structural change (enum widening) that 04-15 owns. Actual behavior: TripStatus is persisted in Dart via `TripStatusConverter.name` on a plain TEXT column. There is no SQL CHECK constraint enumerating the accepted values, so a new enum member is a Dart-only change. The `drift_dev schema dump` output is byte-identical to 04-14's dump.
- **Fix:** Re-dumped anyway (per plan mandate) and confirmed byte-identical. Documented the "no schema-level change" fact for future TripStatus widenings.
- **Files affected:** `drift_schemas/drift_schema_v3.json` (byte-identical; no diff to commit).
- **Commit:** Task 3 (`ac660bc`) — no file change; the mandate was honored + the observation captured.

**5. [Non-blocking — Rule 3 flavor] Extracted `OverpassClient.fetchRawJson` for cache-write path**

- **Found during:** Task 2 — cache write requires the raw response bytes, not the parsed WayCandidate list
- **Issue:** Existing `fetchWaysInBbox` returned parsed `List<WayCandidate>` after decoding + parsing. The cache-write path in `OverpassWayCandidateSource` must store the exact Overpass response bytes so the parser can be revved without invalidating the cache (04-14 SUMMARY §Downstream implications).
- **Fix:** Extracted `Future<String> fetchRawJson({bbox})` — the transport-only path. `fetchWaysInBbox` now composes `fetchRawJson` + parser. Cache-write calls `fetchRawJson` directly.
- **Files modified:** `lib/features/matching/data/overpass_client.dart`.
- **Commit:** Task 2 (`7a3a58f`).

**6. [Drive deferred — user directive] Task 4 real-device Wave 2 smoke → combined Phase-4 close-out drive**

- **Found during:** Post-Task-3 checkpoint
- **User directive 2026-07-08:** "I will do the testing later when I drive to the gym, until then, continue with the rest of the phase and I will test combined at the phase end."
- **Fix:** Author this SUMMARY as code-complete-drive-deferred. Do NOT land the plan's post-approval `docs(04-15): Wave 2 Overpass adapter verified on device` commit — that lands post-drive. Instead, land a metadata commit describing the deferral. Combined checklist covers 04-15 Scenarios A/B/C + 04-16 admin lookup + MapTiler smoke at Kleinheubach + Frankfurt or Würzburg.
- **Files affected:** SUMMARY.md + STATE.md only.
- **Commit:** the metadata commit that follows this SUMMARY. Same code-complete-drive-deferred pattern as Phase 3 (STATE 2026-07-05). Memory ref: `phase-4-drives-deferred-to-gym-trip.md`.

---

**Total deviations:** 4 auto-fixes (Rules 1 / 3) + 1 process (extract fetchRawJson) + 1 drive-defer. No architectural checkpoints. No Rule 4 escalations.
**Impact on plan:** Tasks 1–3 landed exactly to spec (with the coalescing branch elided per the 04-13 verdict). Task 4 batched to a combined drive; no code-level rework.

## Authentication Gates

None. All work runs offline (Drift in-memory tests + Overpass fixture parsing + mocked http client).

## Issues Encountered

- **Coalescing branch elimination.** Not an issue — the plan text sketched an OPTIONAL branch; the 04-13 probe verdict made it unreachable code. Removed at authoring time.
- **`tracking_notifier_test` needed a fake WayCandidateSource + ConnectivitySeam override.** Small addition (~10 lines) to prevent the coordinator hand-off from hitting a real platform channel in test.
- **Fake `WayCandidateSource` fixture-fetch pattern.** Test's `_FakeWayCandidateSource implements WayCandidateSource { … }` records call args + returns a canned `List<WayCandidate>` — the pattern used across the 8 coordinator tests.

## Success Criteria (Wave 2 close-out)

| # | Criterion | Status |
| --- | --- | --- |
| 1 | `WayCandidateSource` interface + `OverpassWayCandidateSource` runtime impl + `FixtureWayCandidateSource` test impl all exist. | PASS (`grep -r "class WayCandidateSource" lib/ test/` returns 3 hits — interface + runtime + fixture). |
| 2 | Trip lifecycle has `pendingRoadData` state; online trips flow `recording → pendingRoadData → pending` within 30 s; offline trips enqueue and drain on next connectivity. | PASS-code (unit tests green: `online trip stop → source called + trip transitions to pending`; `offline trip stop → source NOT called + pending row enqueued`); real-device timing DEFERRED. |
| 3 | Cache is deduped, TTL-swept at 30 days, LRU-evicted at 50 MB. | PASS (04-14 DAO tests already green; 04-15 wayId dedupe test adds the source-layer proof). |
| 4 | All tests green; `flutter analyze` clean. | PASS (249/249 tests; `flutter analyze --no-pub` = `No issues found!`). |
| 5 | Real-device scenarios A + B + C all pass. | **DEFERRED (drive-verify batched)** — combined Phase-4 close-out drive at Kleinheubach; see Deferred Verification Checklist above and memory: `phase-4-drives-deferred-to-gym-trip.md`. |
| 6 | `tool/osm_pipeline/` UNTOUCHED (grep-verify). | PASS (`git diff HEAD~4 HEAD -- tool/osm_pipeline/` returns 0 changes across all three 04-15 commits). |

**Score:** 5/6 PASS (code-complete). 1/6 DEFERRED (drive-verify).

## User Setup Required

None new for Wave 2 code paths. Wave 1 setup (`env/dev.json` with MapTiler key) remains sufficient. `connectivity_plus ^7.0.0` pulls its own platform bindings on `flutter pub get`.

## Downstream contract for Phase 5

- **`WayCandidateSource` is the seam Phase 5's HMM matcher consumes.** The interface is intentionally minimal — a single `fetchWaysInBbox` method — so the matcher can compose it against either the runtime Overpass impl (cache-first, network-backed) or the deterministic `FixtureWayCandidateSource` (golden corpora, no I/O). Both impls apply the Kfz allowlist (`kfzHighwayClasses`) and deduplicate by `wayId` — the matcher does NOT need to re-filter or re-dedupe.
- **Cache format is parser-versioned-agnostic.** OverpassWayCacheDao stores gzipped raw Overpass JSON (04-14 decision). If Phase 5 needs a richer WayCandidate shape (e.g. added `access` or `bicycle` fields), the parser can be revved without invalidating the cache — decode on read, not on write.
- **Trip-lifecycle post-condition:** by the time a trip is in `pending`, `overpass_way_cache` has rows for every z12 tile the polyline touches. Phase 5's matcher can assume WayCandidate availability for any trip in `pending` OR later states.
- **`pending_road_fetches` is transient.** Rows exist only while a trip is in `pendingRoadData`. Successful drain → row deleted + trip transitions to `pending`. Phase 5 should never see a trip in `pending` with a live `pending_road_fetches` row.

## Next Phase Readiness

**Ready for 04-16 (bundled admin polygons + lookup).** No blockers. Verified:

- `git status --porcelain` clean (only `.idea/` untracked)
- `flutter analyze --no-pub` clean
- 249/249 tests green (previously 229 in 04-14; net +20 new tests: 6 tile-math + 6 overpass-way-source + 8 coordinator)

**Grep tripwires post-04-15:**

- `class WayCandidateSource` — 1 hit in `lib/features/matching/data/way_candidate_source.dart`.
- `class OverpassWayCandidateSource` — 1 hit in `lib/features/matching/data/overpass_way_candidate_source.dart`.
- `class FixtureWayCandidateSource` — 1 hit in `test/helpers/fixture_way_candidate_source.dart` (NOT imported from `lib/`).
- `class TileBboxMath` / `class TileId` / `class LatLonBbox` — all in `lib/features/matching/data/tile_bbox_math.dart`.
- `class TripRoadFetchCoordinator` — 1 hit in `lib/features/matching/data/trip_road_fetch_coordinator.dart`.
- `pendingRoadData` — 1 hit in `lib/features/trips/domain/trip_status.dart` (between `recording` and `pending`).
- `connectivity_plus: ^7.0.0` — 1 hit in `pubspec.yaml` (alphabetized between existing deps).
- `AppLifecycleState.resumed` — 1 hit in `lib/app.dart`'s `didChangeAppLifecycleState` override.
- `tool/osm_pipeline/` — untouched (`git log --oneline HEAD~4..HEAD -- tool/osm_pipeline/` returns nothing).

---

**Deferred item:** 04-15 Task 4 real-device Wave 2 smoke (Scenarios A / B / C + Ancillary MapTiler check). Batched to combined Phase-4 close-out drive at Kleinheubach + Frankfurt / Würzburg. Memory: `phase-4-drives-deferred-to-gym-trip.md`. Post-drive: land `docs(04-15): Wave 2 Overpass adapter verified on device` commit.

---

*Phase: 04-osm-pipeline*
*Status: code-complete-drive-deferred*
*Completed (code): 2026-07-08*
*Drive verification: pending combined Phase-4 close-out session*
