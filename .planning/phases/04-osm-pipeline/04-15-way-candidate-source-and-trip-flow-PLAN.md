---
id: 04-15
phase: 04-osm-pipeline
plan: 15
type: execute
wave: 2
wave_ordering: serial-within-wave
wave_serial_order: 3  # runs last in Wave 2
depends_on: [04-14]
files_modified:
  - lib/features/matching/data/way_candidate_source.dart
  - lib/features/matching/data/overpass_way_candidate_source.dart
  - lib/features/matching/data/tile_bbox_math.dart
  - lib/features/matching/data/trip_road_fetch_coordinator.dart
  - lib/features/matching/data/matching_providers.dart
  - lib/features/tracking/data/tracking_service.dart
  - lib/core/db/tables/trips.dart
  - lib/core/db/daos/trips_dao.dart
  - lib/features/matching/data/connectivity_seam.dart
  - lib/app.dart
  - pubspec.yaml
  - drift_schemas/drift_schema_v3.json
  - test/helpers/fixture_way_candidate_source.dart
  - test/features/matching/overpass_way_candidate_source_test.dart
  - test/features/matching/tile_bbox_math_test.dart
  - test/features/matching/trip_road_fetch_coordinator_test.dart
autonomous: false
requirements: [OSM-02, OSM-05, OSM-06]

must_haves:
  truths:
    - "`WayCandidateSource` abstract interface exists with the single method `Future<List<WayCandidate>> fetchWaysInBbox({minLat, minLon, maxLat, maxLon, throwOnError})`."
    - "`OverpassWayCandidateSource` combines the 04-13 client + 04-14 cache: cache-first read, network-fill on miss, LRU + TTL enforced on write."
    - "`FixtureWayCandidateSource` (in `test/helpers/`) loads a pre-built fixture; used by the test suite; NOT part of app runtime."
    - "Trip lifecycle has a new state `pendingRoadData`: trip stops → coordinator computes bbox → resolves z12 tiles → fetches missing (or enqueues if offline) → trip transitions to `pending` once road data is present."
    - "On offline trip finish, `pending_road_fetches` gets an enqueue; on next connectivity, the coordinator drains the queue and transitions trips forward."
    - "Real-device checkpoint verifies: trip finished online caches Overpass response within 30s; trip finished with airplane mode transitions to `pendingRoadData` and reprocesses when reconnected."
  artifacts:
    - path: "lib/features/matching/data/way_candidate_source.dart"
      provides: "Abstract interface + doc comments referencing both impls."
      min_lines: 40
    - path: "lib/features/matching/data/overpass_way_candidate_source.dart"
      provides: "Cache-first runtime implementation; tile-resolution + coalesced-query logic."
      min_lines: 100
    - path: "lib/features/matching/data/tile_bbox_math.dart"
      provides: "Pure functions: `bboxToZ12Tiles(bbox)`, `tileToBbox(z, x, y)`, `unionBbox(tiles)`."
      min_lines: 40
    - path: "lib/features/matching/data/trip_road_fetch_coordinator.dart"
      provides: "Coordinator: on-trip-stop → fetch or enqueue; on-connectivity → drain queue; transitions trip state via TripsDao."
      min_lines: 100
    - path: "test/helpers/fixture_way_candidate_source.dart"
      provides: "Test-double loading a fixture PBF or a fixture JSON; test-only, NOT in main.dart's dep graph."
      min_lines: 40
  key_links:
    - from: "lib/features/matching/data/overpass_way_candidate_source.dart"
      to: "lib/core/db/daos/overpass_way_cache_dao.dart"
      via: "cache-first: getByTile → if hit, decode; if miss, fetch via OverpassClient → put in cache → return"
      pattern: "getByTile|put\\("
    - from: "lib/features/matching/data/trip_road_fetch_coordinator.dart"
      to: "lib/core/db/daos/pending_road_fetches_dao.dart"
      via: "on trip stop → tries fetchWaysInBbox → on network failure → enqueue + set trip state to pendingRoadData"
      pattern: "enqueue"
    - from: "lib/features/tracking/data/tracking_service.dart"
      to: "lib/features/matching/data/trip_road_fetch_coordinator.dart"
      via: "on trip stop, tracking service invokes coordinator.onTripStopped(tripId, polyline)"
      pattern: "onTripStopped|TripRoadFetchCoordinator"
---

## Goal

Ship the `WayCandidateSource` interface + Overpass-backed runtime impl + fixture test impl, and wire trip-finish into a coordinator that fetches (or queues for offline) road data. This is what unblocks Phase 5's matcher.

## Context

- **Wave-2 serial ordering:** 04-13 → 04-14 → 04-15 are all `wave: 2` but MUST run serially in plan-number order. 04-15 consumes the `OverpassClient` (04-13) + `OverpassWayCacheDao` + `PendingRoadFetchesDao` (04-14). Not a parallel-wave. The `wave_ordering: serial-within-wave` frontmatter annotation makes this explicit for the orchestrator.

- Research: `.planning/phases/04-osm-pipeline/04-RESEARCH.md` §2 (tile-key strategy: slippy z12, coalescing single-query for ≤4 tiles), §5 (cache + queue), §6 (WayCandidateSource design), §7 (testing strategy), §8 (Phase 5 consequences).
- Payload-probe result from 04-13: read `.planning/phases/04-osm-pipeline/04-13-PAYLOAD-PROBE.md` — if MANDATORY, this plan implements tile-splitting fully; if OPTIONAL, ships single-query-per-trip with a `TODO(tile-split)` marker.
- Existing trip lifecycle: `lib/core/db/tables/trips.dart` — grep for the existing status column (probably `TripStatus` enum with values like `active`, `pending`, `confirmed`, `rejected`). Add `pendingRoadData` between `active` and `pending`.
- Tracking service hook: `lib/features/tracking/data/tracking_service.dart` — find the `stopTrip()` method; it currently transitions active → pending. Insert coordinator invocation between the polyline write and the state transition.
- Test-impl convention: `test/helpers/fake_tile_server.dart`, `test/helpers/fake_background_geolocation_facade.dart` — put `FixtureWayCandidateSource` alongside.

## Tasks

<task type="auto">
  <name>Task 1: WayCandidateSource interface + tile bbox math + fixture test impl</name>
  <files>
    lib/features/matching/data/way_candidate_source.dart
    lib/features/matching/data/tile_bbox_math.dart
    test/helpers/fixture_way_candidate_source.dart
    test/features/matching/tile_bbox_math_test.dart
  </files>
  <intent>Pure interface + pure math + test double. No I/O.</intent>
  <action>
    **`lib/features/matching/data/way_candidate_source.dart`:**
    ```dart
    /// Abstract source of OSM way candidates for the map-matcher.
    ///
    /// Two implementations exist:
    ///   * [OverpassWayCandidateSource] — runtime, cache-first, network-backed.
    ///   * FixtureWayCandidateSource (test/helpers/) — deterministic, offline.
    ///
    /// The interface is what Phase 5's HMM matcher consumes. Both impls must
    /// apply the Kfz allowlist (kfzHighwayClasses in way_candidate.dart) and
    /// deduplicate by wayId across tile boundaries.
    abstract class WayCandidateSource {
      Future<List<WayCandidate>> fetchWaysInBbox({
        required double minLat,
        required double minLon,
        required double maxLat,
        required double maxLon,
        bool throwOnError = true,
      });
    }
    ```

    **`lib/features/matching/data/tile_bbox_math.dart`:**
    ```dart
    class TileId {
      const TileId(this.z, this.x, this.y);
      final int z, x, y;
      @override
      bool operator ==(Object other) =>
          other is TileId && other.z == z && other.x == x && other.y == y;
      @override
      int get hashCode => Object.hash(z, x, y);
    }

    class TileBboxMath {
      const TileBboxMath();

      /// Slippy tile x for (lon, zoom). Standard OSM math.
      int lonToTileX(double lon, int z) =>
          ((lon + 180.0) / 360.0 * (1 << z)).floor();

      /// Slippy tile y for (lat, zoom).
      int latToTileY(double lat, int z) {
        final rad = lat * math.pi / 180.0;
        return ((1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * (1 << z))
            .floor();
      }

      /// All z12 tiles that overlap the bbox (inclusive).
      Set<TileId> bboxToZ12Tiles(double minLat, double minLon, double maxLat, double maxLon,
          {int z = 12}) {
        final xMin = lonToTileX(minLon, z);
        final xMax = lonToTileX(maxLon, z);
        final yMin = latToTileY(maxLat, z); // note: y inverts w.r.t. lat
        final yMax = latToTileY(minLat, z);
        final out = <TileId>{};
        for (var x = xMin; x <= xMax; x++) {
          for (var y = yMin; y <= yMax; y++) {
            out.add(TileId(z, x, y));
          }
        }
        return out;
      }

      /// Bbox of a single tile: (minLat, minLon, maxLat, maxLon).
      ({double minLat, double minLon, double maxLat, double maxLon}) tileToBbox(TileId t) {
        final n = 1 << t.z;
        final minLon = t.x / n * 360.0 - 180.0;
        final maxLon = (t.x + 1) / n * 360.0 - 180.0;
        final maxLatRad = math.atan(_sinh(math.pi * (1 - 2 * t.y / n)));
        final minLatRad = math.atan(_sinh(math.pi * (1 - 2 * (t.y + 1) / n)));
        return (
          minLat: minLatRad * 180.0 / math.pi,
          minLon: minLon,
          maxLat: maxLatRad * 180.0 / math.pi,
          maxLon: maxLon,
        );
      }

      /// Smallest bbox containing all tiles.
      ({double minLat, double minLon, double maxLat, double maxLon}) unionBbox(Iterable<TileId> tiles) {
        var minLat = 90.0, minLon = 180.0, maxLat = -90.0, maxLon = -180.0;
        for (final t in tiles) {
          final b = tileToBbox(t);
          if (b.minLat < minLat) minLat = b.minLat;
          if (b.minLon < minLon) minLon = b.minLon;
          if (b.maxLat > maxLat) maxLat = b.maxLat;
          if (b.maxLon > maxLon) maxLon = b.maxLon;
        }
        return (minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon);
      }

      double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2.0;
    }
    ```

    **Tests (`test/features/matching/tile_bbox_math_test.dart`):**
    1. `Berlin (52.52, 13.405) at z12 → known tile (2196, 1343)` (compute via https://www.netzwolf.info/osm/tilebrowser.html or the reference formula, and hardcode).
    2. `bboxToZ12Tiles for 5×5km around Berlin returns 1..2 tiles`.
    3. `tileToBbox round-trips reasonably for a known tile` (assert ±0.001° tolerance).
    4. `unionBbox of 4 adjacent tiles gives the enclosing rectangle`.
    5. `bboxToZ12Tiles crossing meridian doesn't produce negative x` (defensive; if a Trailblazer user hits this, we escalate — but the math should be sane).

    **`test/helpers/fixture_way_candidate_source.dart`:**
    ```dart
    /// Test-only WayCandidateSource that loads a bundled fixture JSON blob.
    /// Backed by test/fixtures/overpass/{urban_kreuzberg,rural_grebenhain}.json.gz
    /// or a `.pbf` extracted via tool/osm_pipeline (dev-machine-only).
    class FixtureWayCandidateSource implements WayCandidateSource {
      FixtureWayCandidateSource({required List<WayCandidate> ways})
          : _ways = List.unmodifiable(ways);

      static Future<FixtureWayCandidateSource> fromGzippedOverpassJson(String path) async {
        final bytes = await File(path).readAsBytes();
        final decompressed = utf8.decode(GZipCodec().decode(bytes));
        return FixtureWayCandidateSource(
          ways: const OverpassResponseParser().parseWays(decompressed),
        );
      }

      final List<WayCandidate> _ways;

      @override
      Future<List<WayCandidate>> fetchWaysInBbox({
        required double minLat, required double minLon,
        required double maxLat, required double maxLon,
        bool throwOnError = true,
      }) async {
        // Simple bbox filter over pre-loaded ways.
        return _ways.where((w) {
          return w.geometry.any((p) =>
              p.latitude >= minLat && p.latitude <= maxLat &&
              p.longitude >= minLon && p.longitude <= maxLon);
        }).toList();
      }
    }
    ```
    Do NOT import this file from `lib/` — test-only.

    Note on the "PBF" variant: the fixture-PBF flow uses `tool/osm_pipeline` to generate `test/fixtures/berlin_small.osm.pbf` via a one-time dev-machine invocation. For this plan, the gzipped-JSON fixture is enough — a real PBF-backed test source can be added in Phase 5 planning if the matcher needs it.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/tile_bbox_math_test.dart
    ```
    Analyze clean; 5 tile-math tests green.
  </verify>
</task>

<task type="auto">
  <name>Task 2: OverpassWayCandidateSource — cache-first + tile resolution + coalescing</name>
  <files>
    lib/features/matching/data/overpass_way_candidate_source.dart
    lib/features/matching/data/matching_providers.dart
    test/features/matching/overpass_way_candidate_source_test.dart
  </files>
  <intent>Runtime source combining 04-13 client + 04-14 cache.</intent>
  <action>
    **`lib/features/matching/data/overpass_way_candidate_source.dart`:**
    - Constructor takes `OverpassClient`, `OverpassWayCacheDao`, `TileBboxMath`, `DateTime Function() now`.
    - `fetchWaysInBbox` logic:
      1. `tiles = tileMath.bboxToZ12Tiles(bbox)`.
      2. For each tile: try `cacheDao.getByTile(z,x,y)`. Skip TTL-expired rows (older than 30 days).
      3. Collect `missingTiles` list.
      4. If `missingTiles.isNotEmpty`:
         - If probe-verdict from 04-13 said tile-splitting is OPTIONAL AND missingTiles.length ≤ 4:
           coalesce: fetch single query for `tileMath.unionBbox(missingTiles)` and store the payload split by tile (or store under a synthetic "coalesced" key — simpler: fetch tile-by-tile in a loop of 1..4 tiles).
         - Else: fetch per-tile with concurrency=2 (matching FOSSGIS slot count).
         - For each fetched tile: gzip the raw response body, `cacheDao.put(z, x, y, gzipped, wayCount)`.
      5. Decode each cached tile's payload (gunzip → parse via `OverpassResponseParser`).
      6. Union results; dedupe by `wayId`.
      7. Filter to bbox (parser applied Kfz filter; here just bbox-clip via `geometry.any(point-in-bbox)`).
      8. Return list.
    - On network error: honor `throwOnError` param. If `throwOnError: false`, return partial results (cached-only). If true, rethrow as `DomainError` (04-13's client already wraps).

    **`matching_providers.dart` addition:**
    ```dart
    final tileBboxMathProvider = Provider<TileBboxMath>((_) => const TileBboxMath());

    final wayCandidateSourceProvider = Provider<WayCandidateSource>((ref) {
      return OverpassWayCandidateSource(
        client: ref.watch(overpassClientProvider),
        cacheDao: ref.watch(appDatabaseProvider).overpassWayCacheDao,
        tileMath: ref.watch(tileBboxMathProvider),
      );
    });
    ```

    **Tests (`overpass_way_candidate_source_test.dart`):**
    1. `first fetch hits network + writes cache` — MockClient returns Kreuzberg fixture; assert `cacheDao.totalBytes() > 0` after call; assert MockClient hit once.
    2. `second fetch same bbox hits cache only` — call twice; assert MockClient hit exactly once.
    3. `TTL expiry triggers refetch` — inject fake `now`; first fetch at t0; advance now by 31 days; second fetch triggers new network call.
    4. `bbox spanning 2 tiles fetches both` — assert 2 cache rows created + 2 network calls (or 1 coalesced call, depending on probe verdict).
    5. `dedupe: overlapping tiles don't double-count wayId` — seed two tiles both containing wayId=42; assert result has wayId=42 once.
    6. `throwOnError: false returns partial on network error` — first tile mock returns 500 x3; assert result is empty (no cached data) but no exception thrown.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/overpass_way_candidate_source_test.dart
    ```
    Analyze clean; all 6 tests green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Add pendingRoadData trip state + TripRoadFetchCoordinator + wire into tracking service</name>
  <files>
    lib/core/db/tables/trips.dart
    lib/core/db/daos/trips_dao.dart
    drift_schemas/drift_schema_v3.json
    lib/features/matching/data/trip_road_fetch_coordinator.dart
    lib/features/matching/data/matching_providers.dart
    lib/features/tracking/data/tracking_service.dart
    lib/features/matching/data/connectivity_seam.dart
    lib/app.dart
    pubspec.yaml
    test/features/matching/trip_road_fetch_coordinator_test.dart
  </files>
  <intent>Trip lifecycle: on stop, fetch road data OR enqueue for retry.</intent>
  <action>
    **`lib/core/db/tables/trips.dart`:**
    - Add `pendingRoadData` to the `TripStatus` enum (grep for the existing enum first). Place it BEFORE `pending` in the enum order — the state machine is `active → pendingRoadData → pending → confirmed/rejected`.
    - If the current storage is a plain int with a mapper, adjust the mapper. If it's a text column, add the string.

    **Regenerate schema:**
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/drift_schema_v3.json
    ```
    (schemaVersion stays at 3 — enum values aren't a schema migration.)

    **This step re-runs `dart run drift_dev schema dump` and OVERWRITES the `drift_schemas/drift_schema_v3.json` that 04-14 committed.** Intentional — the TripStatus enum change is part of v3 as well. 04-14 emitted the structural v3 (tables + columns), 04-15 emits the final v3 (tables + columns + TripStatus enum). Commit the regenerated file with a message noting the enum addition (see Commit Strategy at end of plan).

    **`lib/core/db/daos/trips_dao.dart`:**
    - Add `transitionToPendingRoadData(int tripId)` and `transitionToPending(int tripId)` methods if they don't already exist. Follow the existing transition method pattern.

    **`lib/features/matching/data/trip_road_fetch_coordinator.dart`:**
    ```dart
    class TripRoadFetchCoordinator {
      TripRoadFetchCoordinator({
        required this.source,
        required this.pendingDao,
        required this.tripsDao,
        required this.tileMath,
        required this.connectivity, // Connectivity+ package OR a simpler seam
      });

      final WayCandidateSource source;
      final PendingRoadFetchesDao pendingDao;
      final TripsDao tripsDao;
      final TileBboxMath tileMath;
      final ConnectivitySeam connectivity;

      /// Called by TrackingService when a trip stops.
      /// [polyline] is the recorded GPS polyline.
      Future<void> onTripStopped(int tripId, List<LatLng> polyline) async {
        final bbox = _bboxOf(polyline);
        await tripsDao.transitionToPendingRoadData(tripId);

        if (!await connectivity.isOnline()) {
          await pendingDao.enqueue(
            tripId: tripId,
            minLat: bbox.minLat, minLon: bbox.minLon,
            maxLat: bbox.maxLat, maxLon: bbox.maxLon,
          );
          return;
        }

        try {
          await source.fetchWaysInBbox(
            minLat: bbox.minLat, minLon: bbox.minLon,
            maxLat: bbox.maxLat, maxLon: bbox.maxLon,
            throwOnError: true,
          );
          await tripsDao.transitionToPending(tripId);
        } on Object {
          await pendingDao.enqueue(
            tripId: tripId,
            minLat: bbox.minLat, minLon: bbox.minLon,
            maxLat: bbox.maxLat, maxLon: bbox.maxLon,
          );
        }
      }

      /// Called on app resume / connectivity change. Drains queued fetches
      /// with exponential backoff (5m/30m/2h/12h/24h → abandon after 5).
      Future<void> drainQueue({DateTime? now}) async {
        final pending = await pendingDao.listPending();
        for (final row in pending) {
          if (!_backoffElapsed(row, now ?? DateTime.now())) continue;
          if (row.attempts >= 5) {
            // Give up — log + surface later.
            continue;
          }
          try {
            await source.fetchWaysInBbox(
              minLat: row.bboxMinLat, minLon: row.bboxMinLon,
              maxLat: row.bboxMaxLat, maxLon: row.bboxMaxLon,
            );
            await pendingDao.removeByTrip(row.tripId);
            await tripsDao.transitionToPending(row.tripId);
          } on Object {
            await pendingDao.incrementAttempts(row.id, now: now);
          }
        }
      }

      bool _backoffElapsed(PendingRoadFetchData row, DateTime now) {
        if (row.lastAttemptAt == null) return true;
        final delays = [
          Duration(minutes: 5), Duration(minutes: 30),
          Duration(hours: 2), Duration(hours: 12), Duration(hours: 24),
        ];
        final d = delays[row.attempts.clamp(0, delays.length - 1)];
        return now.difference(row.lastAttemptAt!) >= d;
      }

      ({double minLat, double minLon, double maxLat, double maxLon}) _bboxOf(List<LatLng> polyline) {
        // ... min/max iteration
      }
    }
    ```

    **`ConnectivitySeam`:** thin abstraction over `connectivity_plus` (add to pubspec if not present; alphabetize). Simple `Future<bool> isOnline()` method. Real impl reads the plugin; test impl is `class FakeConnectivity implements ConnectivitySeam { … }`.

    **`matching_providers.dart` addition:**
    ```dart
    final tripRoadFetchCoordinatorProvider = Provider<TripRoadFetchCoordinator>((ref) {
      return TripRoadFetchCoordinator(
        source: ref.watch(wayCandidateSourceProvider),
        pendingDao: ref.watch(appDatabaseProvider).pendingRoadFetchesDao,
        tripsDao: ref.watch(appDatabaseProvider).tripsDao,
        tileMath: ref.watch(tileBboxMathProvider),
        connectivity: ref.watch(connectivitySeamProvider),
      );
    });
    ```

    **`lib/features/tracking/data/tracking_service.dart`:**
    - In the `stopTrip` (or equivalent) method: AFTER polyline write, BEFORE the existing transition to `pending`, invoke `coordinator.onTripStopped(tripId, polyline)`. The coordinator does the state transition now.
    - Hook `drainQueue` into `AppLifecycleState.resumed`. Target file: `lib/app.dart` — `grep WidgetsBindingObserver lib/` shows the main app widget already implements it. Add the resume-state hook there:
      ```dart
      
      void didChangeAppLifecycleState(AppLifecycleState state) {
        if (state == AppLifecycleState.resumed) {
          ref.read(tripRoadFetchCoordinatorProvider).drainQueue();
        }
        super.didChangeAppLifecycleState(state);
      }
      ```
    - Verify: `grep -A5 "drainQueue" lib/app.dart` should show the resumed-state hook wired in.

    **Tests (`trip_road_fetch_coordinator_test.dart`):**
    1. `online trip stop → source called + trip transitions to pending`.
    2. `offline trip stop → source NOT called + pending row enqueued + trip in pendingRoadData state`.
    3. `drainQueue with successful fetch removes pending row + transitions trip to pending`.
    4. `drainQueue with failed fetch increments attempts + updates lastAttemptAt`.
    5. `drainQueue respects backoff: 4-min-old row with attempts=0 is NOT retried (5m delay)`.
    6. `drainQueue abandons row after 5 attempts` (no retry, no increment).
  </action>
  <verify>
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    flutter analyze
    flutter test test/features/matching/trip_road_fetch_coordinator_test.dart
    flutter test test/features/tracking/    # regression check on tracking_service tests
    ```
    Analyze clean; all coordinator tests green; existing tracking tests unbroken.
  </verify>
</task>

<task type="checkpoint:human-action">
  <name>Task 4: Real-device Wave 2 smoke — online + offline trip finish + reconnect drain</name>
  <files></files>
  <what-built>
    Wave 2 delivers: OverpassClient with fallback + retry; App DB v3 migration + LRU cache + pending queue DAOs; WayCandidateSource interface + Overpass impl + fixture test impl; TripRoadFetchCoordinator wiring trip-stop into cache-fill or enqueue; new `pendingRoadData` trip state; connectivity-triggered queue drain.
  </what-built>
  <how-to-verify>
    Build for Android device (release build, real MapTiler key):
    ```bash
    flutter run --release --dart-define-from-file=env/dev.json
    ```

    **Scenario A — Online trip finish:**
    1. Wi-Fi ON. Start a manual trip (FAB).
    2. Drive/walk ~500 m so the polyline is non-empty.
    3. Tap Stop.
    4. Within 30 s, verify (via debug HUD if present, or by inspecting App DB via `flutter pub run drift_dev` tools, or by scrolling app logs for the coordinator's log lines):
       - Trip transitioned: active → pendingRoadData → pending.
       - `overpass_way_cache` now has ≥ 1 row for the trip's bbox tiles.
       - `pending_road_fetches` is empty.
    5. Restart the app. Confirm the trip is still in `pending` state (not lost).

    **Scenario B — Offline trip finish + reconnect drain:**
    1. Airplane mode ON before starting the trip.
    2. Start manual trip; walk ~500 m; Stop.
    3. Verify:
       - Trip is in `pendingRoadData` state.
       - `pending_road_fetches` has exactly one row for this trip.
       - `overpass_way_cache` has NO new rows for this trip's bbox.
    4. Turn Wi-Fi/mobile data back on.
    5. Kill + reopen the app (triggers `drainQueue` via lifecycle resume).
    6. Within 60 s, verify:
       - `pending_road_fetches` is empty.
       - `overpass_way_cache` has rows for the trip's bbox tiles.
       - Trip transitioned to `pending`.

    **Scenario C — Cross-country cache hit:**
    1. From Berlin, do a small manual trip (100 m walk indoors is enough).
    2. From the app's dev HUD (or Drift devtools), note the cached tile IDs.
    3. Do a second manual trip in the same area.
    4. Verify: no new Overpass network request in the coordinator's log (cache hit); trip transitions immediately to `pending`.

    **Ancillary check:** confirm the MapTiler tiles are still rendering (Wave 1 not regressed).

    **Approve on success; capture logs + screenshots on any failure and return with issue details.**
  </how-to-verify>
  <resume-signal>Type "approved" or describe issues observed.</resume-signal>
</task>

## Success Criteria (Wave 2 close-out)

- `WayCandidateSource` interface + `OverpassWayCandidateSource` runtime impl + `FixtureWayCandidateSource` test impl all exist.
- Trip lifecycle has `pendingRoadData` state; online trips flow active→pendingRoadData→pending within 30 s; offline trips enqueue and drain on next connectivity.
- Cache is deduped, TTL-swept at 30 days, LRU-evicted at 50 MB.
- All tests green; `flutter analyze` clean.
- Real-device scenarios A + B + C all pass.
- `tool/osm_pipeline/` UNTOUCHED (grep-verify).

## Ralph Loop

- Tight loop: `flutter analyze`
- Behavior-sensitive (all three tasks): `flutter test` after each task; also `flutter test test/features/tracking/` after Task 3 to catch tracking-service regressions.
- Real-device gate is Task 4 (checkpoint).

## Deviations

- If `connectivity_plus` clashes with existing deps or the `ConnectivitySeam` abstraction feels too big, use a simpler stub: `class ConnectivitySeam { Future<bool> isOnline() => http.head(...).timeout(...).then((_) => true).catchError((_) => false); }`. Not ideal but adequate for v1.
- If the `TripStatus` enum is stored in a way that makes adding `pendingRoadData` in the middle of the ordinal sequence risky (e.g. int columns with ordinal 0..N in DB), append `pendingRoadData` at the end and handle order via the state-machine code, not the enum ordinal.
- If Task 4 Scenario C fails (cache miss despite same bbox), the tile-key math probably has a bbox-clip bug. Debug via a targeted unit test that seeds a cache row + calls the source with a bbox inside that tile.

## Commit Strategy

- Task 1 commit: `feat(04-15): WayCandidateSource interface + tile bbox math + fixture test source`
- Task 2 commit: `feat(04-15): OverpassWayCandidateSource with cache-first + coalescing`
- Task 3 commit: `feat(04-15): pendingRoadData state + TripRoadFetchCoordinator + tracking hook`
- Task 4 (checkpoint): no commit — approval gate.
- Post-approval close-out commit: `docs(04-15): Wave 2 Overpass adapter verified on device`
