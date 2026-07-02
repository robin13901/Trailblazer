# Domain Pitfalls: Trailblazer

**Domain:** Flutter GPS trip-tracker with on-device OSM map-matching + MapLibre coverage visualization
**Researched:** 2026-07-02
**Overall confidence:** MEDIUM (training knowledge; WebSearch unavailable this session; a few claims flagged for validation during Phase 1/2 spikes)

---

## How to Read This Document

Each pitfall carries:
- **Severity** — Critical / High / Medium / Low
- **Domain** — a..j from the research question
- **Warning signs** — how you notice it going wrong
- **Prevention** — actionable mitigation
- **Phase** — where the roadmap should address it
- **Confidence** — HIGH / MEDIUM / LOW on the underlying claim

**Phase legend (assumed roadmap shape):**
- **P1** — Skeleton, CI, permissions, foreground scaffolding
- **P2** — MapLibre integration, style, camera, Liquid Glass shell
- **P3** — Background GPS + battery-safe recording
- **P4** — OSM extract prep + on-device road graph + R-Tree
- **P5** — HMM map matching + trip lifecycle
- **P6** — Coverage painting (driven-segment styling), review UX
- **P7** — Motion activity + Bluetooth companion signals
- **P8** — Polish, publishable-quality QA, telemetry, migrations

---

## CRITICAL (project-killer if missed)

### C1. iOS "Always" background location authorization is a two-step ladder, not a single prompt
**Domain:** (a) Flutter background GPS on iOS
**Warning signs:** App gets `whenInUse` and silently loses location after 5-10 minutes in background. Users see "Trailblazer used your location" banners but the trip stops recording after screen lock.
**Root cause:** iOS forces `whenInUse` first; `Always` can only be requested after a delay, and iOS may show a "keep using Always?" dialog days later downgrading it silently.
**Prevention:**
- Request `whenInUse` on first trip. After the user starts a trip, upgrade to `Always` on a second explicit prompt.
- Configure `UIBackgroundModes = location` in `Info.plist` and the four Purpose strings: `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationAlwaysUsageDescription` (legacy), and `NSMotionUsageDescription`.
- Enable `pausesLocationUpdatesAutomatically = false` and set `activityType = .automotiveNavigation` on the CLLocationManager.
- Set `allowsBackgroundLocationUpdates = true` AFTER requesting Always (order matters).
- Handle the auth-downgrade callback — poll `CLAuthorizationStatus` on foreground resume and surface a re-prompt UI.
**Phase:** P1 (permission flow scaffolding), P3 (background recording).
**Confidence:** HIGH — well-established Apple pattern.

### C2. Android 10+ background location + foreground service type "location" is mandatory
**Domain:** (a) Flutter background GPS on Android
**Warning signs:** App works in dev on Pixel but crashes on Samsung/Xiaomi after screen lock; `SecurityException: Starting FGS with type location requires...`; OEM battery optimizers kill the recorder in 3-15 minutes.
**Root cause:**
- Android 10 introduced `ACCESS_BACKGROUND_LOCATION` (separate prompt).
- Android 14 requires `foregroundServiceType="location"` in manifest AND runtime `startForeground(id, notif, FOREGROUND_SERVICE_TYPE_LOCATION)`.
- OEMs (Xiaomi, Huawei, OnePlus, Samsung One UI) apply aggressive doze/battery-saver on top of AOSP.
**Prevention:**
- Manifest permissions: `ACCESS_FINE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`, `ACTIVITY_RECOGNITION`, `WAKE_LOCK` (only if strictly needed).
- Use a persistent foreground service with a real notification (not a stub). Users must see "Trailblazer is recording your trip".
- Prompt user to disable battery optimization for the app on first run (`Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) and document OEM-specific instructions (dontkillmyapp.com reference).
- Test on a real Samsung and a real Xiaomi/Poco. Emulators lie about background behavior.
- Use a battle-tested plugin (see H1) rather than rolling your own service.
**Phase:** P1 (manifest + permissions), P3 (foreground service integration).
**Confidence:** HIGH.

### C3. Flutter platform views + `BackdropFilter` = broken blur, occlusion glitches, and jank
**Domain:** (h) Liquid Glass on top of MapLibre platform view
**Warning signs:** The Liquid Glass panel shows the map underneath as an opaque rectangle instead of blur; on Android, controls flicker on scroll; on iOS the map "punches through" the blur when it repaints; app is fine in debug but broken in release/profile.
**Root cause:** MapLibre-Flutter renders as a native platform view (`UiKitView`/`AndroidView`). Flutter's `BackdropFilter` reads the Flutter compositor's framebuffer; it cannot sample native content composited by the OS below the Flutter surface. On Android, "Hybrid Composition" texture-view mode can work but costs a full-screen memory copy per frame; on iOS platform views are actually composited in a Flutter overlay which somewhat helps, but still historically has issues with backdrop blur ordering. This is one of the longest-standing Flutter rendering gotchas.
**Prevention:**
- **Do not use `BackdropFilter` over a MapLibre platform view.** Instead:
  1. Fake glass with a semi-transparent gradient + subtle noise texture over the map. Users cannot tell if the tint/tone matches the map area (sample average map color into the panel tint).
  2. Or: on iOS, snapshot the map region under the panel every N frames and blur that snapshot as a Flutter image widget under the glass panel.
  3. Or: use `TextureLayerHybridComposition` on Android (test rendering cost).
- If you must have "real" blur, prototype BOTH stacks (Impeller + Skia; hybrid + virtual-display) on a real device before committing to the glass aesthetic.
- Keep the glass to edge-panels (top bar, bottom sheet) rather than full-map overlays — reduces the blur area and hides seams.
- Test with Impeller enabled on Android (default from 3.29+ on Vulkan devices).
**Phase:** P2 — Do a rendering spike **before** committing to the Liquid Glass shell.
**Confidence:** HIGH on the historical issue (Flutter issues #43902, #71888, #74801 area); MEDIUM on the exact 2026 state — verify with a device spike.

### C4. HMM map matching false-positive coverage — painting roads you didn't drive
**Domain:** (b) On-device offline map-matching accuracy
**Warning signs:** Highway on-ramps get painted before the user takes them because the HMM's emission probability picks the nearer parallel road. Frontage roads next to autobahns light up. Parking-lot maneuvers snap to the nearest street. Roundabouts get "smeared" across all exits.
**Root cause:** HMM matching relies on emission (GPS-to-segment distance) + transition (topology + realistic travel time) probabilities. Default parameters tuned on Seattle taxi data (Newson & Krumm 2009) misbehave on:
- German autobahn + parallel Bundesstraße (30-50m apart).
- Dense city grids (Berlin, Munich Altstadt).
- Tunnels and viaducts (GPS unavailable or wildly off).
- Low-speed maneuvers (< 5 km/h) where heading is noisy.
**Prevention:**
- **Never paint a segment until it's confirmed** — introduce a "candidate" state and only promote to "driven" after the HMM window advances past it (Viterbi delay of 5-10 emissions).
- Use a **retroactive re-match** at trip end. The end-of-trip Viterbi has full future context and produces cleaner paths. Trip-live coverage should be provisional; final coverage is authoritative.
- Weight emission probability by GPS accuracy (`horizontalAccuracy`). Ignore fixes with accuracy > 25m for autobahn scenarios.
- Require minimum speed (~15 km/h) for autobahn matching; below that, prefer topological continuity over nearest-road.
- Special-case parking maneuvers: if speed < 5 km/h AND accuracy > 15m, don't advance the match.
- **Ship known-hard test cases**: record 20-30 test trips (autobahn/parallel-road, roundabout, tunnel, parking, U-turn, city grid) and run them as golden tests in CI. Regressions in matching accuracy MUST fail the build.
- Consider a two-pass: fast online match (for live coverage preview) + full offline re-match on trip finalize.
**Phase:** P5 — matching quality is the differentiator, budget serious time.
**Confidence:** HIGH on the failure modes; MEDIUM on exact parameter values (they must be tuned empirically on YOUR corridor).

### C5. Battery drain makes the app unusable in real cars
**Domain:** (i) Battery drain
**Warning signs:** After a 45-minute commute, phone is 20% warmer and battery dropped 15-25%. User uninstalls after week one. iOS shows "Trailblazer" in top 3 battery consumers.
**Root cause combined from many sources:**
- Requesting `kCLLocationAccuracyBestForNavigation` all the time (worst offender).
- No motion-based state machine (recording while parked at a red light for hours).
- Waking the CPU for every GPS fix to run map matching synchronously on the UI isolate.
- Keeping the MapLibre surface rendering at 60fps in the background.
- Running Drift/SQLite writes on every fix instead of batching.
- Bluetooth LE scans continuously polling.
**Prevention:**
- **State machine:** `idle → detecting → recording → paused → recording → finalizing`. Only `recording` uses high-accuracy GPS.
- Use `kCLLocationAccuracyBest` (10m) instead of `BestForNavigation` (1m + fusion) unless you truly need it. HMM matching does fine at 10m.
- On Android, use `Fused Location Provider` with `PRIORITY_HIGH_ACCURACY` + a 1s interval; on iOS use `distanceFilter = 5m` + `activityType = automotive`.
- Run matching on a background isolate; don't block UI.
- When app is backgrounded, tell MapLibre to pause rendering (`onPause` equivalent).
- Batch DB writes every N fixes (e.g., every 20 fixes = ~20 seconds) with a `Batch` transaction. See D2.
- Bluetooth: use `startScan` with a filter for the paired car ONLY, and let the OS wake you via `CBCentralManager` connection events instead of polling.
- **Measure early:** wire up a debug HUD showing fixes/sec, isolate CPU %, DB write ms, and battery-history diff. Do a 60-minute drive with the HUD and commit the metrics to the repo as a baseline.
**Phase:** P3 (state machine) + P8 (measurement, tuning). Add a "battery baseline" gate to the definition of publishable-quality.
**Confidence:** HIGH.

---

## HIGH (rework required if missed)

### H1. Rolling your own background location service
**Domain:** (a) Flutter background GPS
**Warning signs:** You have 400+ lines of Kotlin/Swift wiring `LocationManager`, `AlarmManager`, `WorkManager`, and CoreLocation. You keep discovering new OEM-specific bugs.
**Prevention:** Adopt a proven plugin. Realistic 2026 candidates (verify current maintenance status):
- `flutter_background_geolocation` (Transistor Soft — commercial license for production; best-in-class OEM handling).
- `background_locator_2` (open source, less polished).
- `geolocator` + `flutter_background_service` (DIY combo — works but you inherit all the OEM debugging).
**Recommendation:** Since this is a personal-quality-hobby project, start with `geolocator` + `flutter_background_service`. If you hit OEM battery-killer walls in P3, switch to `flutter_background_geolocation` (paid, but includes battle-tested OEM workarounds).
**Phase:** P3 decision point.
**Confidence:** MEDIUM — verify plugin health at implementation time.

### H2. Germany OSM extract shipping size and update strategy
**Domain:** (d) OSM data preparation & shipping
**Warning signs:** APK is 400MB. App Store rejects for size. First launch downloads 800MB over cellular. Users on 64GB phones complain.
**Root cause:** Germany OSM PBF extract (Geofabrik) is ~4-5 GB. Even after filtering to drivable ways (`highway=motorway|trunk|primary|secondary|tertiary|unclassified|residential|service`), you're looking at 200-500 MB depending on tag preservation and geometry compression.
**Prevention:**
- **Ship a slim road graph, not raw OSM.** Preprocess offline (Node/Python/Rust pipeline) into:
  - Node table: `(id, lat, lon)` — use int32 fixed-point coordinates (multiply by 1e7).
  - Way/Segment table: `(id, from_node, to_node, highway_class, name_id, oneway, geom_blob)`.
  - R-Tree spatial index on segment bboxes.
  - Interned strings table for names (drop most of them, or ship a compressed dictionary).
- Drop unused tags. Keep: `highway`, `oneway`, `maxspeed`, `access` (for gating). Drop everything else.
- Target: <150 MB for the country graph after simplification. Aim for <100 MB by dropping `service` roads and driveways.
- **Do not embed in APK.** Ship a lightweight app and download the graph on first launch over Wi-Fi (with clear user consent). Cache in app-private storage.
- Version the graph file; support delta updates for later phases.
- Test on iOS (App Store shipping) and Android (Play Asset Delivery for large assets).
**Phase:** P4 (graph pipeline is a separate deliverable — build the extract tool BEFORE mobile matching code).
**Confidence:** HIGH.

### H3. SQLite R-Tree query performance at scale
**Domain:** (g) SQLite R-Tree for country-sized network
**Warning signs:** Map-matching candidate lookup takes 200-800ms per fix. UI stutters. Trip live-view lags by seconds. Battery drain from CPU.
**Root cause:** Naive R-Tree query for "segments near (lat, lon)" returns thousands of candidates in dense areas. Follow-up geometric distance calc on Dart side is slow.
**Prevention:**
- **Use a small candidate box** (~100m × 100m) not "all segments in 1km". The HMM only cares about the top 5-10 candidates.
- Store the R-Tree with `virtual table rtree_i32` using integer coords (1e7 scale). Integer R-Tree is measurably faster than float R-Tree.
- Pre-compute geometry-distance calculations in a compiled extension (Drift supports custom SQL functions) or in Rust via FFI if needed.
- Cache the last N candidates — consecutive GPS fixes usually hit the same segments.
- **Benchmark early:** on trip 1 in P4, log p50/p95/p99 candidate-query latency. Fail P4 if p95 > 30ms on a mid-range Android.
- Consider a two-tier index: a coarse H3/geohash bucket in memory pointing to segment IDs, R-Tree only for tie-breaking.
- Run all matching queries on a background isolate — never on the UI thread.
**Phase:** P4 (index design) + P5 (benchmark at match integration).
**Confidence:** MEDIUM-HIGH — SQLite R-Tree is well-known but exact numbers depend on schema.

### H4. Drift migration handling for a big local graph + user trips
**Domain:** (g)/(d) Drift + SQLite migrations
**Warning signs:** App update wipes user's trip history. Or app crashes on first launch after update because migration ran on a graph the user hadn't downloaded yet.
**Prevention:**
- **Separate two databases:** a `graph.db` (immutable, downloaded, replaceable) and a `user.db` (trips, coverage, settings — precious). Drift supports multiple `QueryExecutor` instances. Different lifecycles, different migration policies.
- User DB: strict schema versioning via Drift's `MigrationStrategy.onUpgrade`. Never destructive.
- Graph DB: treat as a cache; delete-and-redownload is acceptable. Store checksum + version.
- On startup: check graph DB version → if missing/stale → prompt user before download. Never block trip recording waiting for graph download; queue trips as raw GPS and match retroactively when the graph is available.
- **Write migration tests.** Drift 2.x has `SchemaVerifier`. Snapshot each schema in `test/generated_migrations/` and verify every up-path.
- Never write raw `ALTER TABLE` — go through Drift's typed migration API.
**Phase:** P1 (DB structure) + P4 (graph DB) + P8 (migration hardening).
**Confidence:** HIGH.

### H5. Real-time coverage painting requires diff, not rebuild
**Domain:** (c) MapLibre with thousands of colored segments
**Warning signs:** Adding a single driven segment causes a 300ms freeze because the entire GeoJSON source is re-uploaded. FPS drops from 60 to 15. iOS memory warning.
**Root cause:** MapLibre GL Native re-tessellates the entire vector source on `setGeoJsonSource`. With 10,000+ segments, this is expensive.
**Prevention:**
- **Do not use one giant GeoJSON source updated on every match.** Instead, one of:
  1. **Data-driven styling via feature-state** (MapLibre supports `feature-state`): keep segments in a static vector tile source (generated from your graph) and toggle their color via `setFeatureState({ driven: true })`. Zero re-tessellation. This is the RIGHT approach — verify MapLibre-Native-Flutter exposes feature-state; MapLibre GL JS has had it for years.
  2. If feature-state not available in flutter plugin: partition the country into ~5km x 5km tiles; each tile is a separate GeoJSON source; only re-upload the tile that changed.
- Client-side vector tiles: convert your graph to MBTiles (using `tippecanoe`) offline; ship as a local `mbtiles://` source; overlay driven state via feature-state.
- Keep the "hot" (recent-trip) segments in a small dynamic layer above the static "all driven ever" layer. Only the small layer updates during recording.
- Test with 50,000 driven segments as an early stress test (fake the data) in P6 — don't wait for real coverage to accumulate.
**Phase:** P6 (coverage rendering). Do a rendering spike early.
**Confidence:** MEDIUM — HIGH for the general problem, MEDIUM for exact feature-state availability in `maplibre_gl` Flutter plugin. Verify at P2/P6.

### H6. Trip finalization edge cases
**Domain:** (f) driving detection accuracy + (b) matching
**Warning signs:** App creates a "trip" every time user walks past their car. Or one continuous trip that spans a whole day because the driving detector never fired "stopped". Trips split at stoplights.
**Prevention:**
- **Debounce start and stop.** Requires N seconds of speed > threshold to start; N seconds below threshold to stop.
- Use Core Motion's `CMMotionActivityManager` (iOS) and Activity Recognition (Android) as *hints*, not truth. Fuse with speed: `automotive` from CMMA + speed > 15 km/h + Bluetooth car-connected = high confidence.
- Coalesce trips separated by short gaps: if trip A ends and trip B starts within 3 min at similar location, they may be the same trip (short stop). Provide merge UI in review.
- Never auto-delete short trips; flag as "possibly not a drive" and let the user confirm/discard.
**Phase:** P5 (trip lifecycle) + P7 (motion + BT signals).
**Confidence:** HIGH.

---

## MEDIUM (annoying if missed)

### M1. Motion activity false triggers
**Domain:** (f) motion / driving detection
**Warning signs:** Bus, train, cycling, or being a passenger triggers "recording started". Or app never triggers because CMMA fires `unknown` for the first 30 seconds.
**Prevention:**
- Combine CMMA/`ActivityRecognition` confidence ≥ 75% with speed ≥ 15 km/h AND Bluetooth-paired car connected (best signal) OR user manual start.
- Provide manual override — "not driving" button dismisses false triggers.
- Cold-start: if the app is launched during motion, don't retroactively assume — wait for CMMA convergence.
**Phase:** P7.
**Confidence:** MEDIUM.

### M2. Bluetooth car detection edge cases
**Domain:** (e) Bluetooth-paired-device detection
**Warning signs:**
- iOS: Cannot enumerate paired classic BT devices (privacy). Only BLE, only after CoreBluetooth pairing your app initiated.
- Android 12+: `BLUETOOTH_CONNECT` runtime permission and rejected background scans.
- BT connection event fires 30-60s after actual car connection (car's BT is slow to advertise).
**Prevention:**
- Do NOT rely on iOS listing already-paired classic-BT devices from CarPlay/hands-free — iOS does not expose them to third-party apps (Apple restriction).
- Android: use `BluetoothAdapter.bondedDevices` (requires `BLUETOOTH_CONNECT`), watch for `ACTION_ACL_CONNECTED` broadcasts. Store user-selected car MAC in prefs.
- Fallback: treat "any BT audio device the user tagged as 'my car'" as the signal. Provide a settings UI to pick the car during onboarding.
- Treat BT as a hint, not a hard gate — user should be able to record without it.
- If iOS-only, consider CarPlay integration as the "car connected" signal (App entitlement required).
**Phase:** P7.
**Confidence:** MEDIUM — HIGH on the iOS restriction, MEDIUM on Android specifics per OEM.

### M3. UI freezes on large coverage recomputes
**Domain:** (c) MapLibre + coverage
**Warning signs:** Opening the map after a long trip freezes the UI for 2-3s while coverage state loads.
**Prevention:**
- Materialize a `driven_segment_ids` set into memory on app start (fits easily even for 100k segments — 400KB as int32).
- Apply feature-state in batches on a background isolate, then flush in one MapLibre call.
- Show the map immediately with an empty coverage overlay; fade in the coverage as it loads.
- Never do coverage recomputation on the UI isolate.
**Phase:** P6.
**Confidence:** HIGH.

### M4. Riverpod 2.x async pitfalls
**Domain:** state management
**Warning signs:** `Bad state: Future already completed`, providers rebuilt on every frame, memory leaks from providers that never dispose subscriptions, race conditions in async `.notifier` methods.
**Prevention:**
- Use `AsyncNotifierProvider` (not `StateNotifier` — deprecated in Riverpod 2.x) for anything async.
- Use `ref.onDispose` for every stream subscription / timer / native listener.
- Prefer `@Riverpod(keepAlive: true)` explicitly rather than defaulting; autoDispose is the default and easy to forget.
- The recording state must be `keepAlive: true` — you do NOT want it disposed when navigating away from the map.
- Test provider lifecycle explicitly: write widget tests that navigate away and back and assert recording continues.
- Avoid `ref.read` in build methods; use `ref.watch`. Use `ref.read` only in callbacks.
- Use `riverpod_generator` + `riverpod_lint` to catch bad patterns.
**Phase:** P1 (set up lint), P3+ (recording provider design).
**Confidence:** HIGH.

### M5. MapLibre style JSON drift and platform-specific expression bugs
**Domain:** (c) MapLibre styling
**Warning signs:** Style renders on Android but crashes / renders wrong on iOS (or vice versa). `interpolate` expressions silently misbehave.
**Prevention:**
- Pin `maplibre_gl` Flutter plugin version; upgrades have broken expression compatibility historically.
- Keep the style JSON in the repo; render it with `flutter_test` golden tests where feasible.
- Test the style on both platforms every time you touch it.
- Prefer simple expressions; nested `case`/`match` beyond 3-4 levels is where cross-platform bugs live.
**Phase:** P2, P6.
**Confidence:** MEDIUM.

### M6. Reviewing recorded trips UX pitfalls
**Domain:** (j) trip review UX
**Warning signs:** User can't tell which route they took vs snapped route. Can't see when they stopped. Can't correct a mismatched trip. Deletes trips because the map looks wrong.
**Prevention:**
- Show BOTH the raw GPS trace (thin gray) AND the matched route (thick colored) on the review screen. Toggle-able.
- Timeline scrubber with speed sparkline — users love this.
- "Report bad match" / "split trip here" / "delete this trip" — first-class actions.
- Never destructively delete raw GPS on match — keep it for 30 days so re-matching after algorithm improvements is possible.
- Show discovered new roads count ("You drove 3 new roads today: X, Y, Z") — dopamine hit that fuels retention.
- Handle trips where matching failed gracefully — show raw GPS with a "matching unavailable" banner rather than crashing.
**Phase:** P6, P8.
**Confidence:** MEDIUM (product design opinion, not empirically validated for this app).

---

## LOW (small annoyances, fix opportunistically)

### L1. Timezone/DST bugs in trip timestamps
Store all timestamps in UTC (unix seconds int64). Only format to local time in the UI layer. Trivial to prevent, painful to fix retroactively.
**Phase:** P1.

### L2. Locale-dependent number formatting in speed/distance
Use `intl` package. Germany uses commas as decimals. Km vs mi setting.
**Phase:** P6.

### L3. Dark mode + Liquid Glass legibility
Liquid Glass over a dark map at night can wash out. Design light AND dark glass palettes; test both at midnight over an unlit rural map.
**Phase:** P2.

### L4. GPS noise inside big buildings on cold start
User opens the app in the garage; GPS shows 5000m accuracy for 30s. Filter fixes with `horizontalAccuracy > 50m` before showing "current location".
**Phase:** P3.

---

## Phase-Specific Warning Table

| Phase | Topic | Likely Pitfall | Mitigation |
|-------|-------|----------------|------------|
| P1 | Permissions setup | Missing usage strings, wrong Info.plist keys | Follow C1/C2 checklists day one |
| P2 | Map + Glass rendering | BackdropFilter + platform view broken | Rendering spike BEFORE UI design (C3) |
| P3 | Background GPS | OEM battery killers, silent auth downgrade | Plugin choice (H1), state machine (C5) |
| P4 | OSM graph | Extract too large, R-Tree too slow | Slim schema (H2), benchmark p95 (H3) |
| P5 | Map matching | False positives, parking snap | Golden test corpus (C4), Viterbi delay |
| P6 | Coverage rendering | Full re-tessellation on every update | Feature-state approach (H5), stress test with 50k fake segments |
| P7 | Motion + BT | False triggers, iOS BT restrictions | Manual override, treat as hints (M1, M2) |
| P8 | Publish quality | Battery baseline, migration bugs | 60-min battery baseline (C5), migration tests (H4) |

---

## Research Flags (verify during Phase spikes)

Claims flagged for direct verification because WebSearch was unavailable this session and training data may be stale:

1. **Flutter BackdropFilter + MapLibre platform view rendering state in 2026** — spike on real device in P2. Test on Impeller (Android/iOS) and legacy Skia (Android).
2. **`maplibre_gl` Flutter plugin: feature-state API availability** — check the plugin's `README` and issue tracker at P2 kickoff. If missing, fall back to sharded GeoJSON.
3. **Best background-geolocation plugin in 2026** — cross-check `flutter_background_geolocation`, `geolocator` + `flutter_background_service`, and any new entrants at P3 kickoff.
4. **Android 14/15 foreground service type requirements** — check current Android developer docs at P1.
5. **Play Asset Delivery limits for >150MB assets in 2026** — verify at P4.
6. **Drift 2.x `SchemaVerifier` API stability** — verify at P1.

---

## Sources

- Training knowledge on Flutter platform views + BackdropFilter (issues #43902, #71888, #74801 area — LOW-MEDIUM confidence without fresh verification).
- Newson & Krumm, "Hidden Markov Map Matching Through Noise and Sparseness" (Microsoft Research, 2009) — foundational HMM matching paper — HIGH confidence on algorithm behavior.
- Apple CLLocationManager documentation patterns — HIGH confidence.
- Android foreground-service-type mandate (Android 14) — HIGH confidence from training.
- MapLibre feature-state pattern (from MapLibre GL JS docs) — HIGH confidence; MEDIUM confidence that Flutter plugin exposes it.
- WebFetch attempts on Flutter issue #41334 (wrong page returned), MapLibre architecture docs (no perf specifics), `flutter_background_geolocation` pub page (feature summary only) — did not yield deep verification this session.
- WebSearch tool unavailable in this session — flagged verification items above.
