# Phase 5: Overpass-Backed Matcher + Golden Corpus — Research

**Researched:** 2026-07-08
**Domain:** HMM map-matching algorithm, Dart R-Tree, Flutter Isolate protocol, CI coverage gates, golden corpus design
**Confidence:** HIGH on codebase state (files verified); HIGH on algorithm parameters (multiple sources agree); MEDIUM on R-Tree library selection (pub.dev verified, perf untested); MEDIUM on CI coverage gate mechanism (lcov tooling confirmed, not yet wired); LOW on Viterbi Dart perf budget (no benchmark run).

---

## 1. Executive Summary

Phase 5 delivers the HMM map-matcher that turns a confirmed trip's GPS polyline into a list of `driven_way_intervals` rows in the App DB, plus a CI-runnable golden corpus that prevents regressions.

**What it must deliver (hard constraints):**

- A `MatcherIsolate` (long-lived, warm) that accepts `MatchJob` messages from the main isolate, runs Viterbi HMM over `WayCandidate` geometry, and returns `List<DrivenWayInterval>`.
- Main isolate pre-fetches ways via `WayCandidateSource` (Phase 4, already exists) and ships a plain `List<WayCandidate>` to the isolate — no Drift handle crosses the isolate boundary.
- Candidate lookup per GPS point: in-memory R-Tree built from those ways. Top-5 within adaptive radius (25 m base, expand with HDOP). Library: `rbush` ^1.1.1.
- Emission probability: Gaussian on perpendicular distance to way segment; σ_z ≈ 4.07 m (Newson-Krumm default). Transition probability: exponential on |route-dist − great-circle| with β ≈ 0.7 / mean_GPS_spacing_m.
- Viterbi lookahead ≥ 5; low-confidence points dropped (not force-snapped). Autobahn smear mitigated by min-speed 15 km/h threshold for motorway/trunk class.
- Matcher output written to `driven_way_intervals` table — the table already exists in schema v3 (`lib/core/db/tables/driven_intervals_table.dart`). **No schema migration needed for Phase 5** (confirmed via schema v3 JSON).
- Raw GPS retained 30 days via a scheduled background sweep (WorkManager on Android / BGTaskScheduler on iOS, or a simple on-open sweep).
- Golden corpus: ≥ 20 recorded trips with known-correct way-ID sequences; regression fails CI. Core matcher module ≥ 90 % line coverage.

**Key risks:**

1. **No road-network shortest-path available at runtime.** Newson-Krumm's transition probability uses road-network distance, not great-circle. The runtime has no routing engine. Approximation: use great-circle distance scaled by a detour factor (1.4 typical). This is a known acceptable approximation — confirmed by several open-source HMM implementations (FMM, Barefoot). Viterbi still rejects unrealistic jumps via the exponential penalty. Risk: slight accuracy loss on tightly parallel roads. Mitigation: `MMT-07` min-speed guard for motorway/trunk already handles the hardest case.
2. **Corpus seeding is manual work.** ≥ 20 trips across 8 scenario types requires real driving. The planner must schedule this as late-stage work and allow plans that ship 3–5 seed trips as a foundation with room for expansion.
3. **Isolate serialization cost.** A 1-hour trip's `List<WayCandidate>` (up to ~100k ways for a large bbox, each with ~20+ LatLng nodes) can be a few MB. SendPort copies the data — no shared memory. This is one-time per trip and acceptable; memory spike during transfer is the real concern.
4. **No lcov per-module threshold tool in the existing CI.** Enforcing "≥ 90 % on matcher module only" requires either `lcov --extract` per-directory or a custom Dart script. The existing CI uses `remove_from_coverage` + Codecov. Enforcing the gate in CI requires a new step.

**Primary recommendation:** Implement the pure-Dart Viterbi HMM + R-Tree in isolation first (no isolate, no Drift) so it's fully testable; then wrap in the `MatcherIsolate`; then wire coordinator → isolate → DAO.

---

## 2. HMM Algorithm Notes

### Paper reference

Newson, P. & Krumm, J. (2009). "Hidden Markov Map Matching Through Noise and Sparseness." ACM SIGSPATIAL GIS 2009. The algorithm is documented by multiple implementations (Barefoot, GraphHopper MM, FMM, Valhalla).

### States, observations, transitions

- **Hidden states:** candidate positions — a (way, projection-point) pair per GPS fix. Each GPS point has up to top-K candidates.
- **Observations:** GPS fixes (lat, lon, accuracy, timestamp).
- **Emission probability:** how likely is GPS fix `z` given the vehicle is at candidate `c`?

```
p(z | c) = (1 / (sqrt(2π) * σ_z)) * exp(-d_perp² / (2 * σ_z²))
```

Where `d_perp` = perpendicular distance from GPS fix to the way segment (meters). In log-space: `log_p = -0.5 * log(2π * σ_z²) - d_perp² / (2 * σ_z²)`.

**σ_z parameter (HIGH confidence):**
- Newson-Krumm (2009) derive σ_z = 4.07 m from their GPS dataset.
- Barefoot default: σ = 5 m.
- Practical range: 4–20 m depending on device and environment. Use an adaptive version: `σ_z = max(4.07, horizontalAccuracy / 2.0)` where `horizontalAccuracy` is the iOS/Android HDOP-derived value in meters. This satisfies MMT-04's "emission probability weighted by horizontalAccuracy."

- **Transition probability:** how likely is a transition from candidate `c_i` (at fix `t`) to candidate `c_j` (at fix `t+1`)?

```
p(c_j | c_i) = (1/β) * exp(-|route_dist(c_i, c_j) - great_circle(c_i, c_j)| / β)
```

Where `route_dist` ≈ road-network distance, `great_circle` = Haversine distance between GPS fixes (not candidates). `β` is a scale parameter.

**β parameter (HIGH confidence from Barefoot/FMM):**
- Newson-Krumm (2009): β is tuned per dataset; typical range 0.3–3.0.
- Barefoot default: β = 10.0 (in their units, where the argument is a ratio).
- FMM / practical implementations: β = 0.7 / mean_GPS_sample_spacing_m is a good heuristic (so if GPS is at 5 m spacing, β ≈ 0.14; at 20 m spacing, β ≈ 0.035).
- **For Trailblazer:** at 1 Hz and ~5–30 km/h average speed, GPS fixes are ~1–8 m apart. β ≈ 1.0 is a reasonable starting default for German roads. The golden corpus drive can be used to tune.
- **Route-distance approximation:** Without a routing engine, use `great_circle * 1.4` (standard detour factor for Germany's road network). This is MEDIUM confidence — it degrades on tight parallel-road scenarios but `MMT-07` handles motorway/trunk smear via the speed guard.

**Log-domain Viterbi (MEDIUM confidence — algorithmic standard):**

Work in log-space throughout to avoid floating-point underflow on long trips:

```
log_p(c_j at step t) = log_p(c_i at step t-1)  [best predecessor]
                     + log(transition(c_i, c_j))
                     + log(emission(c_j, z_t))
```

**Viterbi lookahead / beam pruning:**
- Lookahead ≥ 5 (MMT-07): Keep only the top-K candidates at each step that remain reachable from any of the top-5 candidates from the prior step. This prevents the O(K²) blowup from being K²·N per trip.
- Beam width: K=5 top candidates per fix. At N=3600 fixes per 60-min trip: 5 × 5 × 3600 = 90,000 candidate-pairs to score — trivially fast in Dart.
- **Backpointer table:** Store `bestPredecessor[step][candidateIdx]` as a 2D list. After all fixes, traceback from the max-probability final state.

**Low-confidence drop (MMT-05):**
- A candidate is "low confidence" if its log-probability at the Viterbi step is below a threshold relative to the best candidate. Use: drop the fix if `max_log_p - min_log_p < log(0.001)` (i.e. all candidates have negligible relative probability), or if no candidate within the radius exists. Do NOT force-snap.
- In practice: if the entire candidate set at a step has emission probability near zero (all perpendicular distances > 3 × σ_z + radius), the fix is dropped.

**Autobahn smear mitigation (MMT-07):**
- Before scoring transition from candidate on a motorway/trunk way to any other candidate: check if GPS speed at current fix is < 15 km/h. If so, penalize (add a large negative log-likelihood) transitions to motorway/trunk candidates. This prevents slow-moving GPS (traffic jam, parking) from matching to the nearest autobahn instead of a service road.
- `highwayClass` from `WayCandidate.highwayClass` is what to check. Relevant classes: `motorway`, `motorway_link`, `trunk`.

**Interval output:**
After Viterbi traceback, the sequence of `(wayId, projectionFraction)` pairs is converted to `(wayId, startMeters, endMeters, direction)` intervals. Consecutive projections on the same way are merged. Each interval is one `DrivenWayInterval`.

- `start_meters` / `end_meters`: distance along the way from the first to last projection on that way (m).
- `direction`: `'forward'` if the GPS-point sequence progresses along stored node order; `'backward'` otherwise. Computed by comparing the fractional position at first vs. last projection on the way.
- `matched_at`: `DateTime.now()` on the matcher isolate side.

---

## 3. R-Tree Strategy

### Library selection

**Use `rbush` ^1.1.1** (pub.dev verified 2026-07-08).

| Library | Downloads | Notes |
|---------|-----------|-------|
| `rbush` ^1.1.1 | 120k | Port of Vladimir Agafonkin's JS rbush. Has `knn()`. Has `RBushBase<T>` for custom types. ISC license. Dart 3 supported. |
| `r_tree` ^3.0.2 | 9k | Workiva. No `knn()` method. Lower usage. |

**Rationale:** `rbush` has `knn()` for nearest-neighbor query (needed for adaptive-radius top-5 per fix), 10× more downloads, and a `RBushBase<T>` API that lets us index `WaySegment` objects directly without wrapping.

**API contract (HIGH confidence — pub.dev verified):**

```dart
// Index way segments by their axis-aligned bounding box.
class WaySegmentIndex extends RBushBase<WaySegment> {
  WaySegmentIndex() : super(
    maxEntries: 16,          // tuning: 16 is good for bulk-load
    toBBox: (s) => RBushBox(
      minX: s.minLon, minY: s.minLat,
      maxX: s.maxLon, maxY: s.maxLat,
    ),
    getMinX: (s) => s.minLon,
    getMinY: (s) => s.minLat,
  );
}

// Bulk-load on construction (after fetching all ways for the trip bbox):
final index = WaySegmentIndex();
index.load(segments);  // STR bulk-load, O(N log N)

// Top-5 nearest segments to a GPS fix within adaptive radius:
final radiusDeg = metersToDegreesApprox(adaptiveRadiusM, fix.lat);
final results = index.knn(fix.lon, fix.lat, 5, maxDistance: radiusDeg);
```

**Important:** `rbush` knn uses Pythagorean (Euclidean) distance in coordinate space, not Haversine. For small areas (< 100 km), the error from using degree-coordinates is < 0.3% at German latitudes. This is acceptable for candidate lookup (we're doing a radius search, not exact distance ranking). Perpendicular distance to the segment (for emission probability) must still use proper geometry.

**Segment vs. way indexing:**
Index **segments** (each edge between two consecutive nodes of a way), not whole ways. A way can span 500 m; indexing the whole way would miss fixes on far ends. Each segment is an individual `(wayId, segIdx, startNode, endNode, minLat, minLon, maxLat, maxLon)` record. Memory: a 100k-way trip with ~3 segments/way average = 300k segment records. Each `RBushElement` in rbush is ~50 bytes (5 doubles + reference) = ~15 MB. Acceptable.

**Build cost:** rbush's bulk `load()` uses STR (Sort-Tile-Recursive) which is O(N log N). For 300k segments this is < 100 ms in Dart. Measured in the rbush JS original: 200k items/second build rate. Per-query cost with knn: O(log N + K).

**Adaptive radius (MMT-04):**

```dart
double adaptiveRadiusMeters(double horizontalAccuracyM) {
  const base = 25.0;
  // HDOP-expanded radius: base + accuracy/2, clamped to 150 m.
  return (base + horizontalAccuracyM / 2.0).clamp(25.0, 150.0);
}
```

Convert meters → approximate degrees: `radiusDeg = radiusM / (111320.0 * cos(lat * pi / 180))` for longitude; `/ 111320.0` for latitude. Since rbush uses Euclidean, use the max of lat/lon degree-equivalents.

---

## 4. Isolate Protocol

### Design decision: main-isolate fetch + payload send (confirmed)

The Phase 4 research (04-RESEARCH.md §8) already recommended Option A: main isolate fetches ways via `WayCandidateSource` (which has the Drift DB handle), serializes `List<WayCandidate>` + GPS points, ships to matcher isolate, matcher does pure computation, returns intervals.

This is confirmed as the right design. The matcher isolate has:
- **No Drift dependency** (WAL mode is per-connection; the isolate can't share the DB connection).
- **No Flutter dependencies** (pure Dart, fully testable with `dart test`).
- **Warm R-Tree:** keyed by trip ID or bbox hash, retained across jobs so the second trip in the same area skips R-Tree rebuild.

### MatcherIsolate protocol (MEDIUM confidence — standard Dart pattern)

```dart
// --- main isolate side ---
class MatcherIsolate {
  late Isolate _isolate;
  late SendPort _workerPort;
  final ReceivePort _mainPort = ReceivePort();
  final Map<String, Completer<MatchResult>> _pending = {};
  int _jobSeq = 0;

  Future<void> start() async {
    _isolate = await Isolate.spawn(_matcherEntry, _mainPort.sendPort);
    _workerPort = await _mainPort.first as SendPort;
    _mainPort.listen(_handleReply);
  }

  Future<MatchResult> match(MatchJob job) {
    final id = '${_jobSeq++}';
    final completer = Completer<MatchResult>();
    _pending[id] = completer;
    _workerPort.send({'id': id, 'job': job});
    return completer.future;
  }

  void cancel(String tripId) {
    _workerPort.send({'cancel': tripId});
  }

  void _handleReply(dynamic msg) {
    final id = (msg as Map)['id'] as String;
    final completer = _pending.remove(id)!;
    if (msg.containsKey('error')) {
      completer.completeError(msg['error'] as Object);
    } else {
      completer.complete(msg['result'] as MatchResult);
    }
  }

  void dispose() {
    _mainPort.close();
    _isolate.kill();
  }
}
```

### MatchJob payload (what crosses the isolate boundary)

```dart
class MatchJob {
  final int tripId;
  final List<GpsPoint> fixes;        // lat, lon, accuracy, ts, speedKmh
  final List<WayCandidate> ways;     // from WayCandidateSource
  // MatchJob must be sendable (no Dart I/O types, no futures)
}
```

`WayCandidate` contains `List<LatLng>` (from `maplibre_gl`). `LatLng` is a plain Dart class with two doubles — it's sendable. The `List<WayCandidate>` with full geometry is the largest payload item. For a typical day-trip bbox (50 km²): ~1500–5000 ways × ~10 nodes/way × 2 doubles × 8 bytes ≈ 2–8 MB. Dart's SendPort copies this — one-time cost per trip. Acceptable.

### Cancellation (MMT-08)

Cancellation is cooperative (not `Isolate.kill()`). The worker isolate checks a `_cancelledJobs` set between Viterbi frames (every 100 GPS points):

```dart
// worker side: check between frames
if (_cancelledJobs.contains(job.tripId)) {
  mainPort.send({'id': msg['id'], 'result': null, 'cancelled': true});
  return;
}
```

The cancel message (`{'cancel': tripId}`) is sent ahead of time from the coordinator when the user deletes the trip. The job returns a cancelled result; the coordinator discards partial intervals and deletes the trip row.

### R-Tree warm cache in isolate

The isolate maintains a `Map<int, WaySegmentIndex>` keyed by trip ID (cleared after result is sent). If a second trip covers the same bbox, the index is rebuilt from the new ways payload (which may overlap). A future optimization (not Phase 5 scope) would cache by bbox hash.

---

## 5. Golden Corpus Design

### Fixture format

Each golden trip is a pair of files under `test/fixtures/golden_trips/`:

```
test/fixtures/golden_trips/
  001_autobahn_a3_east/
    gps_trace.json          -- array of {lat, lon, accuracy, speedKmh, ts}
    expected_ways.json      -- array of {wayId: int, direction: 'forward'|'backward'}
    metadata.json           -- {scenario: "autobahn", date, device, notes}
  002_kreisel_kleinheubach/
    ...
```

**`gps_trace.json`** — plain JSON, no binary dependency:
```json
[
  {"lat": 49.7012, "lon": 9.2187, "accuracy": 8.5, "speedKmh": 85.0, "ts": "2026-07-08T10:00:00.000Z"},
  ...
]
```

**`expected_ways.json`** — the sequence of OSM way IDs in the correct matching order:
```json
[
  {"wayId": 4123456789, "direction": "forward"},
  {"wayId": 4123456790, "direction": "forward"},
  ...
]
```

### Road network fixture (critical for offline CI reproducibility)

Golden trips cannot use live Overpass in CI — they need a deterministic road network. Two options:

| Option | Pros | Cons |
|--------|------|------|
| **A. Fixture `WayCandidateSource` backed by a saved Overpass JSON** | Uses existing `FixtureWayCandidateSource` from `test/helpers/` | Requires saving a per-trip Overpass JSON (10–200 KB) |
| **B. Minimal per-trip JSON with only the relevant ways** | Tiny, hand-verifiable | Manual to create — must manually extract relevant ways |

**Use Option A.** The workflow:
1. Developer drives the route.
2. After trip, run a one-off Dart script (`tool/osm_pipeline/bin/save_trip_fixture.dart`) that calls the live `OverpassWayCandidateSource.fetchWaysInBbox()` for the trip's bbox and saves the gzipped JSON alongside the GPS trace.
3. Run the matcher against the saved JSON, inspect output, confirm correct way sequence, write `expected_ways.json`.
4. Commit both files.

The `FixtureWayCandidateSource` already exists at `test/helpers/fixture_way_candidate_source.dart` and supports `fromGzippedOverpassJson()`. Phase 5 needs:
- A per-trip fixture directory structure (as above).
- A test harness (`test/features/matching/golden_corpus_test.dart`) that loops over all `test/fixtures/golden_trips/*/` directories and runs the matcher.

### Scenario list (MMT-09 — ≥ 20 trips)

| # | Scenario | Why it's hard |
|---|----------|---------------|
| 1–3 | Autobahn (A3, A45, A63 or similar) forward | Parallel-road smear, high speed |
| 4–5 | Bundesstraße (B469, B8) at moderate speed | Mixed class transitions |
| 6–7 | Kreisverkehr (roundabout) entry/exit | Short tight curves, multiple ways |
| 8–9 | Kreisel full loop (drove the roundabout) | Circling behavior |
| 10–11 | Tunnel (GPS blackout) | Gap handling — no force-snap |
| 12–13 | Parking lot approach | Low speed, should not match to main road |
| 14–15 | U-turn on a narrow street | Direction reversal |
| 16–17 | Dense city grid (Frankfurt or Würzburg Altstadt) | Many candidate ways close together |
| 18–19 | Roundabout entry + straight exit | One-way ways, direction accuracy |
| 20 | One-way street pair (Einbahnstraße) | Oneway filter must prevent wrong-direction match |

**Seeding strategy:** Trips 1–5 should be recorded as part of the Phase 5 close-out drive (the Phase 4 + Phase 5 combined drive). Remaining trips can be added over subsequent drives. CI regression checks ALL committed trips — starting with 3 is fine, expanding to 20 is iterative.

### CI assertion pattern

```dart
// test/features/matching/golden_corpus_test.dart
void main() {
  final corporaDir = Directory('test/fixtures/golden_trips');
  
  for (final tripDir in corporaDir.listSync().whereType<Directory>()) {
    test('golden trip: ${tripDir.path.split('/').last}', () async {
      final trace = _loadGpsTrace(tripDir);
      final source = await FixtureWayCandidateSource.fromGzippedOverpassJson(
        '${tripDir.path}/ways.json.gz',
      );
      final ways = await source.fetchWaysInBbox(/* trip bbox */);
      
      final result = HmmMatcher().match(trace, ways);
      
      final expected = _loadExpectedWays(tripDir);
      
      // Assert way-ID sequence matches (order-sensitive, no float comparison).
      expect(
        result.intervals.map((i) => i.wayId).toList(),
        equals(expected.map((e) => e.wayId).toList()),
        reason: 'golden trip ${tripDir.path} way-ID sequence mismatch',
      );
    });
  }
}
```

The assertion is **way-ID sequence equality** — no floating-point comparisons on start/end meters (those are expected to vary slightly with tuning).

### Coverage gate (≥ 90 % line coverage on matcher module)

The existing CI already runs `flutter test --coverage` and strips generated files via `remove_from_coverage`. To enforce the 90 % threshold on the matcher module specifically, add a CI step after `remove_from_coverage`:

```bash
# Extract coverage for the matching module only, then check threshold.
lcov --extract coverage/lcov.info \
     "*/lib/features/matching/*" \
     "*/lib/core/matcher/*" \
     -o coverage/matcher_lcov.info

# Compute coverage percentage (requires lcov + bc on the runner — Ubuntu has both).
LINES_FOUND=$(grep -E '^LF:' coverage/matcher_lcov.info | awk -F: '{sum+=$2} END{print sum}')
LINES_HIT=$(grep -E '^LH:' coverage/matcher_lcov.info | awk -F: '{sum+=$2} END{print sum}')
PCT=$(echo "scale=1; $LINES_HIT * 100 / $LINES_FOUND" | bc)
echo "Matcher coverage: ${PCT}% (${LINES_HIT}/${LINES_FOUND})"
if (( $(echo "$PCT < 90.0" | bc -l) )); then
  echo "FAIL: matcher coverage ${PCT}% < 90%"
  exit 1
fi
```

This approach is LOW confidence on exact syntax (not tested in CI), but uses only standard POSIX tools available on Ubuntu runners. A simpler alternative is a Dart script under `tool/check_coverage.dart` that parses `matcher_lcov.info` directly.

**Alternative (simpler, no lcov tools required):** Write a standalone test that directly counts covered lines via `dart coverage` tooling — but this has higher setup cost. Stick with `lcov --extract`.

---

## 6. Data Model Confirmation

### `driven_way_intervals` table — CONFIRMED via codebase

**File:** `lib/core/db/tables/driven_intervals_table.dart`

```dart
class DrivenWayIntervals extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get wayId => integer()();              // OSM way ID
  IntColumn get tripId => integer()              
      .references(Trips, #id, onDelete: KeyAction.setNull)
      .nullable()();
  RealColumn get startMeters => real()();          // distance from way start
  RealColumn get endMeters => real()();            // distance from way end
  TextColumn get direction => text()             
      .withDefault(const Constant('forward'))();   // 'forward'|'backward'|'both'
  DateTimeColumn get matchedAt => dateTime()       
      .withDefault(currentDateAndTime)();
}
```

**Schema v3 SQL (confirmed from drift_schemas/drift_schema_v3.json):**
```sql
CREATE TABLE IF NOT EXISTS "driven_way_intervals" (
  "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  "way_id" INTEGER NOT NULL,
  "trip_id" INTEGER NULL REFERENCES trips (id) ON DELETE SET NULL,
  "start_meters" REAL NOT NULL,
  "end_meters" REAL NOT NULL,
  "direction" TEXT NOT NULL DEFAULT 'forward',
  "matched_at" INTEGER NOT NULL DEFAULT (...)
);
```

**Zero-work finding:** The table is fully defined in schema v3. **No DB migration is needed for Phase 5.** The only work is a new `DrivenWayIntervalsDao` (currently not in `lib/core/db/daos/` — must be created).

**Direction encoding:** TEXT string, values `'forward'` / `'backward'` / `'both'`. `'both'` may be useful when a point is matched to a non-directional way segment that was traversed in both directions. The matcher should use `'forward'` or `'backward'` per matched direction; `'both'` can be set by Phase 6's interval-collapse pass if needed.

**FK on tripId:** `ON DELETE SET NULL` — intervals survive trip deletion (intentional, matching Phase 1 decision: `driven_intervals -> trips SET NULL`). This means the interval remains even if the trip is deleted, so coverage aggregation (Phase 6) is unaffected.

**Missing: `timestamp` column mentioned in requirements (MMT-06: `driven_way_intervals(way_id, start_m, end_m, direction, trip_id, timestamp)`).** The actual table has `matched_at` not `timestamp` — these are semantically equivalent (both = time of matching). No issue.

**Needed DAO methods:**
```dart
// lib/core/db/daos/driven_way_intervals_dao.dart  (new in Phase 5)
class DrivenWayIntervalsDao extends DatabaseAccessor<AppDatabase> {
  Future<void> insertBatch(List<DrivenWayIntervalsCompanion> rows) async { ... }
  Future<List<DrivenWayInterval>> getByTrip(int tripId) async { ... }
  Future<void> deleteByTrip(int tripId) async { ... }
}
```

**Wire into AppDatabase:** Add `DrivenWayIntervalsDao` to the `@DriftDatabase(daos: [...])` list. This requires a `build_runner build` run but NOT a schema version bump.

---

## 7. Retention Job Design (MMT-10)

**What:** 30-day default retention of raw GPS points after matching. User can override (Phase 10 settings UI — deferred). Phase 5 ships the retention mechanism, not the UI.

**Where to enforce:** A periodic sweep function, not a per-trip post-match hook. Reasons:
1. The retention clock starts at `matched_at`, not at trip end. The sweep must look at `DrivenWayIntervals.matchedAt` to know which trips have been matched and when.
2. A nightly sweep is simpler than hooking into every match completion.

**Mechanism (MEDIUM confidence — platform-specific):**

| Platform | Background task mechanism | Notes |
|----------|--------------------------|-------|
| Android | `WorkManager` (via `flutter_workmanager` package) | Reliable, battery-aware, persists across reboots |
| iOS | `BGTaskScheduler` (via `flutter_background_fetch` or `workmanager`) | More restricted; min interval 15 min |
| Both | On-open sweep (simplest) | No package needed; runs at cold start; may lag if user doesn't open app |

**Recommendation for Phase 5:** Use the **on-open sweep** pattern — zero new packages, adequate for personal use. Add a `rawGpsRetentionSweep()` call in `app.dart` at `AppLifecycleState.resumed` (alongside `drainQueue`). The sweep:

```dart
Future<void> rawGpsRetentionSweep({Duration retentionPeriod = const Duration(days: 30)}) async {
  final cutoff = DateTime.now().subtract(retentionPeriod);
  // Delete trip_points for trips that were matched before the cutoff
  // AND have at least one driven_way_intervals row (i.e. are matched).
  await _tripsDao.deleteTripPointsForMatchedTripsOlderThan(cutoff);
}
```

The SQL is a correlated delete:
```sql
DELETE FROM trip_points
WHERE trip_id IN (
  SELECT DISTINCT d.trip_id 
  FROM driven_way_intervals d
  WHERE d.matched_at < ? AND d.trip_id IS NOT NULL
);
```

This requires a new `TripsDao` method (or a new `TripPointsDao` method). Add to the existing `TripsDao` to keep the Drift access pattern consistent.

**Retention override (SET-06 deferred to Phase 10):** Implement as `AppPrefs` key `raw_gps_retention_days` with default `30`. The sweep reads it. No UI in Phase 5.

---

## 8. Package / Dependency Survey

### Required new packages

| Package | Version | Reason | Confidence |
|---------|---------|--------|-----------|
| `rbush` | ^1.1.1 | R-Tree candidate index | HIGH — pub.dev verified, 120k downloads |

### Packages already present (no new deps)

| Package | Current version | Used by Phase 5 for |
|---------|----------------|-------------------|
| `drift` | ^2.34.0 | `DrivenWayIntervalsDao`, writes + queries |
| `flutter_riverpod` | ^3.3.2 | `matcherIsolateProvider`, coordinator wiring |
| `maplibre_gl` | ^0.26.2 | `LatLng` type in `WayCandidate` (already imported) |
| `logging` | ^1.3.0 | Matcher + coordinator logging |
| `meta` | ^1.16.0 | `@immutable` on matcher domain objects |

### Packages NOT needed

- `latlong2` — not needed; `haversineMeters()` already exists at `lib/features/trips/domain/haversine.dart`. Reuse it. Do NOT add a new distance package.
- `dart_earcut` — not needed; no polygon triangulation.
- `vector_math` — not needed; distance math is bespoke (haversine + perpendicular distance).
- Any HMM package — none exist on pub.dev (confirmed). Roll our own.
- `dart:isolate` — already in Dart SDK; no new package.

### pubspec.yaml change

```yaml
# Add to dependencies (alphabetized per sort_pub_dependencies):
rbush: ^1.1.1
```

---

## 9. Performance Budget & Risks

### Target

60-min trip (~3600 GPS samples at 1 Hz) matches in < 5 s on midrange Android in warm isolate state (MMT-01 SLA is not explicitly stated but ≤ 60 s is the user-perceptible threshold).

### Rough Dart performance estimates (LOW confidence — no benchmark run)

| Operation | Estimated time | Notes |
|-----------|---------------|-------|
| Deserialize `List<WayCandidate>` in isolate (from `SendPort`) | ~50–200 ms | 5000 ways × 10 nodes = 50k LatLng objects |
| Build `WaySegmentIndex` R-Tree (rbush bulk load) | ~20–100 ms | 15k segments for 5000 ways |
| Viterbi per fix: knn query + 5 candidates + emission + transition | ~0.1–0.5 ms/fix | 0.5 ms × 3600 = 1.8 s |
| Viterbi traceback | < 1 ms | O(N × K) = 18000 ops |
| Write intervals to DB | ~10–50 ms | 50–200 rows typical |
| **Total (cold isolate, large bbox)** | **~2–4 s** | Well within budget |

### Memory estimates

| Component | Memory |
|-----------|--------|
| 5000 ways × ~10 nodes × 2 doubles × 8 bytes | ~800 KB |
| 15k WaySegment objects in rbush | ~5–8 MB (rbush node overhead) |
| GPS trace 3600 fixes × ~5 doubles × 8 bytes | ~150 KB |
| Viterbi state tables: 3600 × 5 candidates × 2 doubles | ~290 KB |
| **Isolate total** | **~10–15 MB** |

Comfortable on any modern phone. The main-isolate side holds the same `List<WayCandidate>` temporarily during serialization — peak memory spike is the double-held payload (~2 MB for a typical trip).

### Risk: very large bbox trips

A cross-country trip (Berlin → Munich, 600 km) would produce a bbox touching ~200 z12 tiles. The `WayCandidateSource` would return tens of thousands of ways. Mitigation: the `TripRoadFetchCoordinator` already handles tile-by-tile fetching. The matcher's R-Tree load cost scales linearly. Worst case: 50k ways → 150k segments → R-Tree build ~500 ms. Still within 5 s budget.

### Risk: R-Tree degree-coordinate Pythagorean approximation

`rbush.knn()` uses Pythagorean distance in degree space. At 49°N latitude (Bavaria), 1 degree longitude ≈ 71.5 km, 1 degree latitude ≈ 111 km. The anisotropy ratio is ~1.55. This means knn radius in degrees is slightly elliptical. For the candidate lookup (we want within 25–150 m), the error is at most 55% in the worst direction. Since we do a subsequent perpendicular-distance check with real Haversine anyway, false-positives from the R-Tree are expected and dropped at the emission step. False-negatives (missing a close candidate) are the risk — mitigated by using `max(latDegRadius, lonDegRadius)` for the knn distance bound.

---

## 10. Proposed Plan Decomposition

### Summary (7–8 plans, 3 waves)

| # | Plan ID | Name | Wave | Type | Depends on |
|---|---------|------|------|------|------------|
| 1 | 05-01 | DrivenWayIntervalsDao + raw-GPS retention sweep | 1 | execute | — |
| 2 | 05-02 | Geometry primitives + emission/transition probability functions | 1 | execute | — |
| 3 | 05-03 | WaySegmentIndex (R-Tree wrapper) | 1 | execute | — |
| 4 | 05-04 | Viterbi decoder (pure, no I/O) | 2 | execute | 05-02, 05-03 |
| 5 | 05-05 | HmmMatcher orchestrator (glues R-Tree + Viterbi → intervals) | 2 | execute | 05-04 |
| 6 | 05-06 | MatcherIsolate wrapper + cancellation + Riverpod wiring | 3 | execute | 05-05 |
| 7 | 05-07 | Coordinator wire-up (pending trip → match → intervals DB write) | 3 | execute | 05-06 |
| 8 | 05-08 | Golden corpus scaffolding + ≥ 5 seed trips + CI gate | 3 | execute | 05-05 |

### Wave structure

**Wave 1 (parallel — all independent pure-Dart):**
- **05-01:** `DrivenWayIntervalsDao` (insert batch, get by trip, delete by trip) + `TripsDao.deleteTripPointsForMatchedTripsOlderThan()`. Wire DAO into `AppDatabase`. Add to `@DriftDatabase(daos:[...])`. No schema bump — table already exists. Includes `migration_v3_no_change_test.dart` (confirm DAO queries work against v3 DB).
- **05-02:** Pure functions in `lib/features/matching/domain/hmm_probability.dart`: `emissionLogProb(perpDistM, sigmaM)`, `transitionLogProb(routeDistM, greatCircleDistM, beta)`, `adaptiveRadius(horizontalAccuracyM)`, `perpDistanceToSegment(fix, segStart, segEnd)`. ~100 lines. 20+ unit tests with golden values.
- **05-03:** `lib/features/matching/domain/way_segment_index.dart` — `WaySegment` value type + `WaySegmentIndex extends RBushBase<WaySegment>`. Methods: `buildFromWays(List<WayCandidate>)`, `queryTopK(lat, lon, radiusDeg, k)`. ~80 lines. Tests with fixture ways from existing `FixtureWayCandidateSource`.

**Wave 2 (serial — 05-04 depends on 05-02 + 05-03):**
- **05-04:** `lib/features/matching/domain/viterbi_decoder.dart` — pure Dart Viterbi over `List<GpsPoint>` × `WaySegmentIndex`. Lookahead ≥ 5, adaptive beam pruning, low-confidence drop, backpointer traceback. ~200 lines. Tests include: short known trace → correct way sequence; gap produces no interval; autobahn smear mitigated by speed guard; one-way respects direction. **This is the highest-complexity plan.**
- **05-05:** `lib/features/matching/domain/hmm_matcher.dart` — orchestrator: accepts `MatchJob`, calls decoder, converts (wayId, fractions) → `DrivenWayInterval` list. Handles edge cases: empty trace, single-point trace, zero-way trips. ~100 lines. Integration tests with `FixtureWayCandidateSource` + synthetic GPS traces.

**Wave 3 (serial — after Wave 2 core matcher is solid):**
- **05-06:** `lib/features/matching/data/matcher_isolate.dart` — `MatcherIsolate` class (Isolate.spawn + SendPort protocol + cancellation + `matcherIsolateProvider`). The entry point function calls `HmmMatcher().match()`. Tests with `flutter_test` isolate spawning (note: isolate tests work in `flutter test` via `dart:isolate`).
- **05-07:** `lib/features/matching/data/trip_match_coordinator.dart` — watches for `TripStatus.pending` trips, enqueues them into `MatcherIsolate`, writes results via `DrivenWayIntervalsDao`, advances trip status to `TripStatus.matched`. Handles cancellation (trip deletion → `matcherIsolate.cancel(tripId)` + `DrivenWayIntervalsDao.deleteByTrip(tripId)`). Wires retention sweep into `app.dart` resume hook.
- **05-08:** Golden corpus scaffolding + first 5 seed trips + CI coverage gate. New `test/fixtures/golden_trips/` directory structure. Fixture-save Dart script at `tool/osm_pipeline/bin/save_trip_fixture.dart`. `test/features/matching/golden_corpus_test.dart`. Updated `ci.yml` with `lcov --extract` + coverage threshold step. **Note:** The full 20-trip corpus is not expected on day one. CI starts passing with 5 trips and grows organically.

### Dependency graph

```
05-01 ──┐
05-02 ──┤ (Wave 1, parallel)
05-03 ──┤
        ↓
      05-04 (Wave 2)
        ↓
      05-05 (Wave 2)
        ↓ (all 3 Wave 3 plans can run in parallel after 05-05)
   ┌────┤
05-06  05-07  05-08
```

05-06 and 05-07 are serial (05-07 depends on 05-06). 05-08 only depends on 05-05 (uses `HmmMatcher` directly, no isolate).

---

## 11. Open Questions / Decisions the Planner Must Make

1. **β parameter default value.** Research recommends β = 1.0 as starting default. The golden corpus (05-08) is the only way to empirically validate this. Should 05-04 hard-code β = 1.0 and σ_z = 4.07 initially, then expose them as tunable parameters after first corpus run? **Recommendation:** yes — expose as named constructor parameters with documented defaults; first corpus run will determine if tuning is needed.

2. **`DrivenWayIntervalsDao` location.** Should it be in `lib/core/db/daos/` (matching the existing two DAOs) or in `lib/features/matching/data/`? The existing pattern puts DAOs in `lib/core/db/daos/`. **Recommendation:** `lib/core/db/daos/driven_way_intervals_dao.dart` — keeps DB layer consistent.

3. **Retention sweep: on-open vs. WorkManager.** Research recommends on-open sweep for Phase 5 simplicity (no new packages). Is this acceptable, or does the planner want background WorkManager wiring now? **Recommendation:** on-open sweep in Phase 5; defer WorkManager to Phase 10 (which already handles background jobs for OSM extract refresh).

4. **`TripStatus.matched` vs. `TripStatus.confirmed`.** The current `TripStatus` enum has `matched` and `confirmed` as distinct states. The requirements say the matcher writes intervals and advances to some state. Phase 6 (Inbox) adds the user-confirmation step. Phase 5 should advance to `matched` (not `confirmed`) after successful match. **Confirm:** `pending → matched` is the Phase 5 state transition; `matched → confirmed` is Phase 6 inbox.

5. **50+ trip corpus seeding strategy.** Corpus growth beyond 5 seed trips requires real drives over specific scenario types. Tunnels (GPS blackout) and parking lots may be hard to script. **Recommendation:** create a `tool/record_golden_trip.dart` script that captures a live trip + auto-saves the Overpass fixture, making future seed trips a one-tap operation during any drive.

6. **Direction field value `'both'`.** The table allows `'both'` but the matcher will produce `'forward'` or `'backward'`. Is `'both'` needed in Phase 5? **Recommendation:** No — the matcher always produces a direction. `'both'` is a Phase 6 coverage-aggregation concept when two matched intervals on the same way cover both directions. Phase 5 emits `'forward'` or `'backward'` only.

7. **`rbush` version constraint.** `rbush` ^1.1.1 is on pub.dev with 120k downloads. Version 1.1.1 was published 2 years ago — no recent updates. Verify pub.dev for latest version before pinning. **Verify:** `dart pub add rbush` and check what version resolves.

8. **Viterbi gap detection (tunnel / signal loss).** When consecutive GPS points are > 60 seconds apart, the Viterbi should treat it as a potential gap (no transition probability connects the two fix clusters). **Design:** check timestamp delta between consecutive fixes; if `Δt > kGapThresholdSeconds = 60`, reset the Viterbi state and start a new segment. The intervals before and after the gap are independently valid.

9. **Golden corpus CI failure mode.** If a golden trip fails (wrong way sequence), CI blocks the merge. This could create friction for pure algorithm tuning commits. **Recommendation:** put golden corpus tests in a separate CI step that runs AFTER the coverage gate; mark it as required. This way, algorithm tuning without corpus updates fails visibly but doesn't block unrelated PRs. Consider `--run-skipped` flag for the corpus step when explicitly tuning.

10. **`app_database.dart` DAO registration.** Adding `DrivenWayIntervalsDao` to `@DriftDatabase(daos: [...])` requires a `build_runner build` regeneration of `app_database.g.dart`. This is standard codegen work. Confirm the CI step already runs `dart run build_runner build` before tests (confirmed in `ci.yml` line 33 — yes, it does).

---

## Sources

### Primary (HIGH confidence)
- `lib/core/db/tables/driven_intervals_table.dart` — table schema confirmed
- `lib/core/db/app_database.dart:39` — schema version 3 confirmed
- `drift_schemas/drift_schema_v3.json` — `driven_way_intervals` full SQL confirmed (includes all required columns)
- `lib/features/matching/domain/way_candidate.dart` — `WayCandidate`, `kfzHighwayClasses`, `OnewayDirection` confirmed
- `lib/features/matching/data/way_candidate_source.dart` — interface confirmed
- `lib/features/matching/data/matching_providers.dart` — `wayCandidateSourceProvider` confirmed
- `lib/features/matching/data/trip_road_fetch_coordinator.dart` — pending-state flow confirmed
- `lib/features/trips/domain/trip_status.dart` — `TripStatus` enum with `matched` state confirmed
- `lib/features/trips/domain/haversine.dart` — haversine function confirmed (Phase 5 reuses this, no new dep)
- `test/helpers/fixture_way_candidate_source.dart` — `FixtureWayCandidateSource` with `fromGzippedOverpassJson` confirmed
- `.github/workflows/ci.yml` — existing CI structure confirmed; `build_runner build` + coverage confirmed
- `pub.dev/packages/rbush` — `rbush` ^1.1.1, 120k downloads, `knn()` method confirmed
- Flutter docs Isolate.spawn pattern — bidirectional SendPort/ReceivePort protocol confirmed
- Barefoot wiki (HMM algorithm) — σ_z ≈ 5 m, λ = 0.1, Viterbi backpointer pattern confirmed

### Secondary (MEDIUM confidence)
- Phase 4 research `04-RESEARCH.md §8` — Option A isolate protocol (main fetches, ships List<WayCandidate>) confirmed as design direction
- `pub.dev/packages/r_tree` — rejected in favor of rbush (no knn(), lower downloads)
- `rbush` Pythagorean knn caveat — documented on pub.dev; Haversine correction at emission step confirmed as mitigation
- β parameter range (0.3–3.0) — multiple open-source HMM implementations agree
- lcov `--extract` per-directory coverage gate — standard POSIX approach; not yet implemented in this CI

### Tertiary (LOW confidence — flag for validation)
- Dart Viterbi performance estimates — extrapolated from JS rbush benchmarks + Dart/JS speed ratio; no actual benchmark run
- β = 1.0 default value — reasonable starting estimate, must be validated against golden corpus
- Detour factor 1.4 for Germany — community standard; no measurement against actual trip data

---

## Metadata

**Confidence breakdown:**
- Table schema / codebase state: HIGH — all files read and verified
- Algorithm parameters (HMM): MEDIUM-HIGH — multiple sources converge, but β needs tuning
- R-Tree library (`rbush`): HIGH — pub.dev verified, confirmed knn() API
- Isolate protocol: HIGH — Flutter docs confirmed
- CI coverage gate: MEDIUM — lcov approach known, not yet wired
- Perf budget: LOW — no benchmark run

**Research date:** 2026-07-08
**Valid until:** 2026-09-08 (30-day window; `rbush` version should be checked at plan time)

---

## RESEARCH COMPLETE
