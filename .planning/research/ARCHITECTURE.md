# Architecture Research — Trailblazer

**Domain:** Flutter GPS trip-tracker with on-device OSM map-matching + coverage aggregation
**Researched:** 2026-07-02
**Confidence:** MEDIUM-HIGH (Drift/Riverpod/MapLibre patterns HIGH; HMM map-matching packaging MEDIUM; iOS background specifics MEDIUM)

---

## 1. System Overview

Trailblazer is a **local-first, single-user** mobile app. There is no server. Everything — GPS capture, map-matching, coverage aggregation, tile rendering — runs on-device. The architecture must therefore treat the phone as if it were a small server: background workers, an on-disk read-only reference dataset (OSM), and a mutable operational database (trips + driven intervals).

The dominant architectural forces are:

1. **Two very different data lifetimes.** OSM data is large, read-only, versioned by extract date, and shipped/downloaded as an artifact. User data (trips, driven intervals, vehicles) is small, mutable, and migrated in-place. These must not share a database file or a migration story.
2. **Latency-heterogeneous work.** GPS ingest must run in a battery-friendly background context; map-matching is CPU-heavy and must not touch the UI isolate; map rendering must be reactive; coverage aggregation is expensive and must be cached.
3. **Feature-first modular boundaries** with a small set of **cross-cutting infrastructure modules** (OSM data, map-matching engine, background/services, database).

```
┌──────────────────────────────── PRESENTATION (UI isolate) ─────────────────────────────────┐
│                                                                                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │  Map     │  │ Tracking │  │  Trips   │  │ Vehicles │  │ Regions  │  │ Settings │        │
│  │ Screen   │  │  Screen  │  │  Inbox   │  │  Screen  │  │ Coverage │  │  Screen  │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │             │             │             │             │             │              │
│  ┌────┴─────────────┴─────────────┴─────────────┴─────────────┴─────────────┴──────┐       │
│  │                          Riverpod providers (per feature)                        │       │
│  └────┬─────────────┬─────────────┬─────────────┬─────────────┬─────────────┬──────┘       │
└───────┼─────────────┼─────────────┼─────────────┼─────────────┼─────────────┼──────────────┘
        │             │             │             │             │             │
┌───────┴─────────────┴─────────────┴─────────────┴─────────────┴─────────────┴──────────────┐
│                              DOMAIN / APPLICATION SERVICES                                 │
│  ┌──────────────┐  ┌───────────────┐  ┌────────────────┐  ┌──────────────┐  ┌───────────┐  │
│  │ TripSession  │  │ TripReview    │  │ CoverageQuery  │  │ VehicleMatch │  │ FocusArea │  │
│  │  Service     │  │  Service      │  │  Service       │  │  Service     │  │ Resolver  │  │
│  └──────┬───────┘  └───────┬───────┘  └────────┬───────┘  └──────┬───────┘  └─────┬─────┘  │
└─────────┼──────────────────┼───────────────────┼─────────────────┼────────────────┼────────┘
          │                  │                   │                 │                │
┌─────────┴──────────────────┴───────────────────┴─────────────────┴────────────────┴────────┐
│                                   INFRASTRUCTURE                                           │
│                                                                                            │
│  ┌─────────────────┐  ┌─────────────────┐  ┌───────────────┐  ┌──────────────────────┐     │
│  │  GPS Recorder   │  │ Map-Matching    │  │ OSM Data      │  │ Bluetooth Fingerprint│     │
│  │  (native bg     │  │  Engine         │  │  Repository   │  │   Watcher            │     │
│  │   plugin)       │  │  (HMM, isolate) │  │  (RO SQLite   │  │  (native bg plugin)  │     │
│  └────────┬────────┘  └────────┬────────┘  │   + R-Tree)   │  └──────────┬───────────┘     │
│           │                    │           └───────┬───────┘             │                 │
│           │                    │                   │                     │                 │
│  ┌────────┴────────────────────┴───────────────────┴─────────────────────┴──────────┐      │
│  │              Drift (App DB)          │           Drift (OSM DB, read-only)       │      │
│  │  trips, points, driven_intervals,    │  ways, way_geoms, way_admin_joins,        │      │
│  │  vehicles, bt_fingerprints,          │  admin_regions (L2/4/6/8/9-10),           │      │
│  │  coverage_cache, migrations          │  rtree_ways (spatial index), meta         │      │
│  └──────────────────────────────────────┴───────────────────────────────────────────┘      │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Key idea:** two Drift databases, not one. The **App DB** is small and migrated with the app. The **OSM DB** is a versioned artifact — replaced wholesale when a new extract is shipped.

---

## 2. Component Responsibilities

### 2.1 Feature modules (`lib/features/<feature>/{data,domain,presentation}`)

| Module | Owns | Depends on | Does NOT own |
|--------|------|------------|--------------|
| `tracking/` | Recording state, live trip session, motion/permission UX, current TripSession service | `core/background`, `core/db` (App DB), `map_matching` (post-hoc) | Map rendering, OSM lookups |
| `trips/` | Trip entity, review inbox, confirmation UI, trip detail, vehicle assignment | `core/db`, `tracking/` (for pending trips), `vehicles/` (for assignment) | Map-matching internals, OSM data |
| `map/` | MapLibre widget, camera state, style loading, GeoJSON sources for driven ways, focus-area detection, layer toggling | `map_matching` (read-only via `CoverageQuery`), `regions/` | Trip lifecycle, OSM extract prep |
| `vehicles/` | Vehicle CRUD, active vehicle, Bluetooth fingerprint config, matcher policy | `core/db`, `core/background` (BT watcher) | GPS, matching |
| `regions/` | Admin-region browser (L2/4/6/8/9-10), coverage % per region, regional focus mode | OSM DB (read), App DB (driven intervals), `coverage/` | Rendering internals |
| `coverage/` | Coverage aggregation service, per-region cache, invalidation rules | App DB, OSM DB (admin joins) | UI, matching |
| `settings/` | Preferences, extract version, permissions status, storage/data mgmt | `core/*` | Everything else |

### 2.2 Cross-cutting infrastructure modules (`lib/core/`)

| Module | Owns |
|--------|------|
| `core/db/` | Drift app database, migrations, DAOs base class, DB isolate bootstrap |
| `core/osm/` | OSM DB Drift schema (read-only), extract-version metadata, artifact download/verify/swap logic, R-Tree query helpers |
| `core/map_matching/` | HMM map-matcher (candidate search via R-Tree, emission + transition models, Viterbi), match orchestrator, matcher isolate lifecycle |
| `core/background/` | Platform channels for background GPS, motion activity, Bluetooth watcher; work scheduling (WorkManager on Android, BGTaskScheduler on iOS); permission plumbing |
| `core/logging/` | Structured logging, crash breadcrumbs, matcher diagnostics |
| `core/errors/` | Error types, Result/Either helpers, user-facing error mapping |
| `core/routing/` | GoRouter config, deep links |
| `core/theme/` | Theme + design tokens |

### 2.3 Why `map_matching` is its own core module (not inside `trips/`)

- It has **its own runtime concern** (isolate, memory, cancellation).
- It is consumed by **multiple** features: `trips/` (post-confirmation match), `coverage/` (rematch on extract update), `settings/` (rebuild driven intervals for diagnostics).
- It has **no UI**, so shoehorning it into a feature module violates the feature-first convention.
- Its dependency graph (OSM DB + R-Tree + math kernels) is heavier than any feature's.

### 2.4 Why OSM data is its own core module (not inside `map/` or `regions/`)

- It is **read-only reference data**, not application state.
- Multiple features consume it (`map/`, `regions/`, `map_matching`, `coverage/`).
- Its lifecycle (download / verify / swap / gc) is orthogonal to app data lifecycle.
- Putting it inside `map/` would imply a rendering-only concern; it is actually a data concern.

---

## 3. Recommended Project Structure

```
lib/
├── main.dart
├── app.dart                                 # ProviderScope, routing, theme wiring
│
├── core/
│   ├── db/
│   │   ├── app_database.dart                # Drift @DriftDatabase
│   │   ├── tables/                          # trips, points, driven_intervals, vehicles, bt_fp, coverage_cache
│   │   ├── daos/
│   │   ├── migrations/                      # per-version migration files
│   │   └── isolate_bootstrap.dart           # DriftIsolate.spawn wiring
│   │
│   ├── osm/
│   │   ├── osm_database.dart                # Drift RO schema for OSM artifact
│   │   ├── tables/                          # ways, way_geoms, way_admin_joins, admin_regions, rtree_ways, meta
│   │   ├── artifact/
│   │   │   ├── extract_manifest.dart
│   │   │   ├── downloader.dart              # first-run / update
│   │   │   ├── verifier.dart                # checksum + schema version
│   │   │   └── swap.dart                    # atomic replace of DB file
│   │   └── queries/
│   │       ├── candidate_ways.dart          # R-Tree bbox lookup
│   │       └── admin_lookup.dart            # point -> admin regions
│   │
│   ├── map_matching/
│   │   ├── engine/
│   │   │   ├── hmm.dart                     # Viterbi core
│   │   │   ├── emission.dart                # distance-based likelihood
│   │   │   ├── transition.dart              # route-cost transitions
│   │   │   └── candidate_search.dart        # R-Tree bbox per point
│   │   ├── orchestrator.dart                # match(trip) -> intervals
│   │   ├── isolate/
│   │   │   ├── matcher_isolate.dart         # long-lived worker
│   │   │   └── protocol.dart                # request/response messages
│   │   └── models/
│   │       ├── match_input.dart
│   │       ├── match_result.dart
│   │       └── driven_interval.dart
│   │
│   ├── background/
│   │   ├── gps/
│   │   │   ├── gps_service.dart             # facade over plugin
│   │   │   ├── android_config.dart
│   │   │   └── ios_config.dart
│   │   ├── motion_activity.dart
│   │   ├── bluetooth_watcher.dart
│   │   └── scheduler.dart                   # WorkManager / BGTaskScheduler
│   │
│   ├── logging/
│   ├── errors/
│   ├── routing/
│   └── theme/
│
└── features/
    ├── tracking/
    │   ├── data/                            # writes raw points/pending trips
    │   ├── domain/                          # TripSessionService, states
    │   └── presentation/                    # widgets, providers, screens
    ├── trips/
    │   ├── data/
    │   ├── domain/                          # TripReviewService, confirm/assign
    │   └── presentation/                    # inbox, detail, confirm sheet
    ├── vehicles/
    │   ├── data/
    │   ├── domain/                          # VehicleMatchService (uses BT watcher)
    │   └── presentation/
    ├── map/
    │   ├── data/                            # style loading, geojson sources
    │   ├── domain/                          # FocusAreaResolver, camera state
    │   └── presentation/                    # MapLibre widget, layer toggles
    ├── regions/
    │   ├── data/                            # admin-region queries (OSM DB)
    │   ├── domain/
    │   └── presentation/                    # region browser, coverage list
    ├── coverage/
    │   ├── data/                            # cache DAO
    │   ├── domain/                          # aggregation, invalidation
    │   └── presentation/                    # shared widgets
    └── settings/
        ├── data/
        ├── domain/
        └── presentation/

assets/
├── map_style/                               # MapLibre style JSON (offline-friendly)
└── osm/                                     # optional: bundled small extract (dev/test)

tool/
└── osm_pipeline/                            # offline dev-machine pipeline (Dart or Python)
    ├── download_pbf.dart
    ├── extract_roads.dart
    ├── extract_admin.dart
    ├── build_rtree.dart
    ├── build_admin_joins.dart
    └── package_sqlite.dart
```

### Structure rationale

- **`core/` vs `features/`:** anything shared by 2+ features or with its own runtime lifecycle belongs in `core/`. Everything user-facing belongs in `features/`.
- **`tool/osm_pipeline/`:** the extract pipeline is *not* app code. It runs on a developer machine, outputs a SQLite artifact, and is checked into a release process — not shipped as source in the APK/IPA.
- **Two DBs, two Drift schemas:** `core/db/` (mutable) and `core/osm/` (read-only artifact). Never merge.
- **`map_matching/isolate/` sibling to `engine/`:** the pure algorithm is testable without isolates; the isolate glue is a thin adapter.

---

## 4. Architectural Patterns

### Pattern 1: Two-Database Split (App DB + OSM DB)

**What:** App data lives in an app-owned, migrated Drift database in the app documents directory. OSM data lives in a separate Drift database file that is a **versioned, replaceable artifact**.

**When to use:** Always for this project. This is the single most important architectural decision.

**Trade-offs:**
- (+) OSM updates never risk user data; migration story is simpler.
- (+) OSM DB can be attached read-only (`SQLITE_OPEN_READONLY`), enabling safe mmap + shared cache.
- (+) Different backup policy (App DB backs up; OSM DB does not — `NSURLIsExcludedFromBackupKey` on iOS; `android:allowBackup` exclusion).
- (−) Cross-DB joins are impossible; joins must happen in Dart (or via `ATTACH DATABASE`).

**Sketch:**
```dart
final appDb = AppDatabase(await appIsolate.connect(singleClientMode: true));
final osmDb = OsmDatabase(await osmIsolate.connect(singleClientMode: true, readOnly: true));
```

### Pattern 2: Long-Lived Matcher Isolate (not one-shot compute)

**What:** Spawn a **single, long-lived** map-matching isolate at first use. Send it match requests via a `SendPort`. It holds warm handles to the OSM DB and R-Tree.

**When to use:** When multiple trips may be matched in a session and OSM DB open cost is non-trivial (it is — schema + statement prep + spatial index cache warmup).

**Trade-offs:**
- (+) Amortizes DB open + statement preparation across many matches.
- (+) Enables cancellation and back-pressure.
- (−) More lifecycle complexity than `Isolate.run` / `compute`. Needs explicit teardown on low-memory events.

**Alternative rejected:** Drift's `computeWithDatabase()` is elegant for one-shot work but re-establishes connection state each call — wasteful when matching a batch of trips.

### Pattern 3: Riverpod as the Only State Surface (no Bloc, no Provider-legacy)

**What:** All UI-visible state (recording status, inbox count, coverage %, focus area) flows through Riverpod providers. Services expose streams/futures; providers expose `AsyncValue`.

**Rules:**
- Notifiers (`Notifier`/`AsyncNotifier`) for mutable UI state.
- `StreamProvider` for Drift's auto-updating queries — Drift streams integrate natively.
- `FutureProvider.autoDispose.family` for parameterized reads (e.g., coverage for region X).
- **No `ref.read` in build methods.** `ref.watch` in build, `ref.read` in callbacks.

### Pattern 4: DAO-per-Table + Service-per-Feature

**What:** Drift DAOs are thin (queries only). Feature services orchestrate multiple DAOs, background plugins, and the matcher.

**Trade-offs:**
- (+) Keeps SQL contained; keeps business rules testable with mock DAOs.
- (−) One more layer than a raw repository pattern — but necessary because most features touch 2–3 tables plus a background service.

### Pattern 5: R-Tree Candidate Search + HMM Viterbi

**What:** For each GPS point, query the R-Tree spatial index for candidate way segments within a search radius (typ. 30–100 m, adaptive on HDOP). Emission = distance to segment. Transition = shortest-path cost between candidates on consecutive points. Viterbi decodes the maximum-likelihood sequence.

**When to use:** This is the standard approach (Newson & Krumm 2009, and every practical open-source variant since).

**Trade-offs:**
- (+) Robust to GPS noise, urban canyons, dual carriageways.
- (−) Cost is `O(points × candidates²)` in transitions; tune candidate cap (e.g., top-5 per point) and pre-filter by heading.

### Pattern 6: Coverage Cache with Explicit Invalidation

**What:** Coverage % per region is not computed on every screen open. It is cached in `coverage_cache(region_id, driven_length_m, total_length_m, updated_at, extract_version, invalidation_gen)`.

**Invalidation triggers:**
- New driven interval committed → invalidate touched regions (via way→region join).
- OSM extract swapped → invalidate all rows (bump `invalidation_gen`).
- Trip deleted / unconfirmed → invalidate touched regions.

**Trade-offs:**
- (+) Region-list screen is O(regions) DB read, not aggregation.
- (−) Requires careful "which regions did this interval touch?" invalidation. Cheap because way_admin_joins is precomputed in the OSM pipeline.

### Pattern 7: Focus-Area Resolver as Pure Function

**What:** `(mapCenter, zoom) → RegionLevel × RegionId` is a pure function driven by zoom thresholds and a point-in-region OSM lookup. It runs on the UI isolate on camera-idle (debounced).

**Trade-offs:**
- (+) Deterministic, testable, cheap.
- (−) Requires small point-in-region index (already produced by extract pipeline).

---

## 5. Data Flow

### 5.1 Trip capture flow (background → App DB → UI)

```
[Motion activity: "driving"]
        │
        ▼
[Native bg plugin] ─── location updates ──► [GPS Service (Dart)]
        │                                          │
        │                                          ▼
        │                             [TripSession domain object]
        │                                          │
        │                                          ▼
        │                                  Drift App DB (points)
        │                                          │
        │                                          ▼
        │                              (stream) ► [Tracking provider] ► [UI]
        ▼
[Motion: "still" ≥ N minutes] ──► [TripSession.finalize()] ──► trip.status = pending
```

Notes:
- The GPS plugin runs in its own OS-managed process/service. Data crosses into the Flutter isolate via method/event channels.
- Writes to the App DB happen on the Drift server isolate (via `DriftIsolate`), so no jank on UI.

### 5.2 Trip confirmation + matching flow

```
[User taps "Confirm" in Inbox]
        │
        ▼
[TripReviewService.confirm(tripId, vehicleId)]
        │
        ├─► App DB: trip.status = confirmed, trip.vehicle_id = ?
        │
        └─► [MatchOrchestrator.enqueue(tripId)]
                    │
                    ▼
              (SendPort) ──► [Matcher Isolate]
                                    │
                                    ├── read points from App DB (via DriftIsolate)
                                    ├── candidate search on OSM DB R-Tree
                                    ├── HMM Viterbi
                                    │
                                    ▼
                              driven_intervals[]
                                    │
                                    ▼
                              App DB.write(intervals)
                                    │
                                    ▼
                        [CoverageInvalidator]
                                    │
                                    ▼
                        coverage_cache row bumps → provider re-emits → UI updates
```

### 5.3 Map render flow

```
[MapScreen build]
        │
        ▼
[coverageStyleProvider] ──► reads driven_intervals ± focus filter
        │
        ▼
Build in-memory GeoJSON FeatureCollection (or serve via a data-driven style property)
        │
        ▼
MapLibre style updateSource("driven_ways", geojson)
        │
        ▼
Layer paint uses ["case", ["get", "driven"], color_driven, color_undriven]
```

For large data volumes, prefer **feature-state–like** approaches: keep the full network as a vector source (from the OSM DB served through a local `mbtiles` file if size permits) and toggle a paint expression based on a driven-way-id set — but only if the initial GeoJSON approach exceeds ~50k features on-screen.

### 5.4 Bluetooth vehicle-fingerprint flow

```
[OS BT stack] ──► [BT Watcher plugin] ──► [VehicleMatchService]
                                                │
                                                ├─ match paired MAC → vehicle_id
                                                │
                                                ▼
                                    Currently-active-vehicle provider
                                                │
                                                ▼
                                On new trip: auto-fill vehicle assignment
```

---

## 6. Background Execution Architecture

### Android

- **Foreground service** for active recording (persistent notification, `FOREGROUND_SERVICE_LOCATION`).
- **WorkManager** for periodic maintenance (coverage recompute, extract update check).
- Motion-activity API for start/stop hints.
- Battery-optimization exemption prompt in onboarding.

### iOS

- **`allowsBackgroundLocationUpdates = true`** with `location` background mode; use significant-location-change + region monitoring to wake the app between updates.
- **Core Motion (CMMotionActivityManager)** for driving detection.
- **BGTaskScheduler** (`BGProcessingTask`) for coverage recompute and extract updates.
- No true foreground services on iOS — reliance is on the OS-managed location subsystem. Design for **event-driven wakeups**, not a continuously-running Dart isolate.

### Isolate topology

```
┌───────────────────────────┐
│      UI isolate           │  Flutter, MapLibre, Riverpod
└──┬─────────┬──────────────┘
   │         │
   │         │ SendPort
   │         ▼
   │   ┌─────────────────────────┐
   │   │  Matcher isolate        │  HMM, OSM RO reads
   │   │  (long-lived, on-demand)│
   │   └─────────────────────────┘
   │
   │ Drift protocol
   ▼
┌───────────────────────────┐
│  Drift App DB isolate     │  spawned by DriftIsolate.spawn()
└───────────────────────────┘
┌───────────────────────────┐
│  Drift OSM DB isolate     │  read-only
└───────────────────────────┘

(background OS process) ──► method channel ──► UI isolate
[native GPS/BT plugin]
```

Rules:
- The **matcher isolate** connects to both Drift isolates via `DriftIsolate.connect(singleClientMode: false)` so multiple consumers can share connections.
- Native plugin events land on the UI isolate first. Heavy processing is dispatched to the matcher isolate immediately.
- Never touch SQLite files from two isolates without going through Drift's isolate protocol.

---

## 7. Database Migration Strategy

### App DB

- Standard Drift `MigrationStrategy`.
- Every schema change → increment `schemaVersion` → add `from_N_to_N_plus_1.dart` under `core/db/migrations/`.
- Use Drift's **schema tests** (`drift_dev schema dump` + generated migration tests) — one test per version pair.
- **Additive migrations only** in the first year: add tables/columns, do not drop or repurpose. When a rename is truly needed, use the "new column, backfill, drop later" three-release dance.

### OSM DB

- **No in-place migration.** New extract = new schema version = new file.
- Manifest file (`osm_manifest.json`) records: extract date, source URL, schema version, checksum, way count, region counts.
- On app launch, compare the app's *required* schema version to the on-device manifest. If mismatch, prompt to update (or block matching until an update is present).
- **Swap procedure:** download to `osm_new.sqlite` → verify checksum → close old handles → atomic rename → reopen → invalidate coverage cache (bump `invalidation_gen`).
- Keep last-known-good extract around until swap succeeds; delete only after first successful open.

### Coverage cache

- Not a schema concern per se; but every migration that changes way-id representation must clear the cache (or the invalidator must recompute).

---

## 8. Cross-Cutting Concerns

### Error handling

- Domain services return `Result<T, DomainError>` (sealed classes). No throwing across isolate boundaries.
- UI maps `DomainError` → localized user message via `core/errors/error_presenter.dart`.
- Matcher isolate wraps every message with try/catch and returns `MatchFailure` explicitly.
- Crash breadcrumbs (last N GPS points, matcher state, DB write counters) attached to any error report.

### Logging & diagnostics

- Structured logging with levels; per-module tag.
- Matcher exposes a diagnostic dump (`points`, `candidates_per_point`, `viterbi_path`, `dropped_points`) gated behind a debug setting — invaluable for tuning HMM parameters.
- Include OSM extract version in every log.

### Permissions

- Centralized in `core/background/permissions.dart`: location (always), motion, Bluetooth-scan, notifications, background-app-refresh.
- Every feature that needs a permission calls `PermissionsGate` — no scattered plugin calls.

### Caching

- Coverage cache (see Pattern 6).
- Focus-area result cache (LRU by rounded lat/lon/zoom) — trivial memory optimization.
- MapLibre style objects cached across screens.

### Testing seams

- Pure algorithms (HMM, Viterbi, transition costs) — unit-tested in-process, no isolate.
- Services — tested with mock DAOs (Drift generates `MockAppDatabase` easily via `NativeDatabase.memory()`).
- Integration — spin up in-memory Drift + a tiny hand-crafted OSM DB with 3 ways + 1 admin region.

---

## 9. Suggested Build Order (Dependency Graph)

```
                          ┌─ core/theme, core/routing, core/errors, core/logging
                          │
[1] Scaffolding ──────────┤
                          │
                          └─ core/db (App DB skeleton, migrations infra)

[2] Background primitives ─── core/background (permissions, GPS plugin facade, motion)

[3] Tracking MVP ────────── features/tracking
                                 (writes raw trips + points to App DB;
                                  no matching yet; visible on a plain map)

[4] OSM pipeline (offline) ── tool/osm_pipeline
                                 (produces first artifact: small region for dev)

[5] core/osm ─────────────── OSM DB schema + artifact loader + R-Tree queries
                                 (attaches artifact, queries admin regions)

[6] Trips + review ───────── features/trips
                                 (inbox, confirm, vehicle-less first)

[7] core/map_matching ────── engine (pure) → orchestrator → isolate
                                 (unit-tested against toy OSM DB)

[8] Matching wired in ────── features/trips.confirm → orchestrator.enqueue
                                 (produces driven_intervals)

[9] features/map ─────────── MapLibre widget, driven-ways GeoJSON,
                                 focus-area resolver, style toggle

[10] features/regions + coverage ─ aggregation service + cache + region browser

[11] features/vehicles + BT ─ vehicle CRUD, BT watcher, auto-assignment

[12] features/settings ───── extract updates, permissions, diagnostics

[13] Hardening ──────────── iOS bg refinement, battery tuning,
                              coverage invalidation edge cases,
                              extract-swap failure recovery
```

**Critical dependency chain:** `core/db → core/background → tracking → OSM pipeline artifact → core/osm → core/map_matching → trips confirm-and-match → map render → coverage → regions UI`. Nothing after step 5 is possible without a working OSM artifact; that pipeline should be tackled **early**, even if only with a tiny bounding box of Berlin for development.

---

## 10. Anti-Patterns

### Anti-Pattern 1: Single monolithic Drift database for user data + OSM

**What people do:** Merge everything into one `app.sqlite` for "simplicity."
**Why it's wrong:** OSM updates become terrifying; user data becomes coupled to extract versions; backup includes 3 GB of derivable data; migrations become impossible.
**Do this instead:** Two databases, always. Only App DB is migrated.

### Anti-Pattern 2: Map-matching in the UI isolate (or in a `compute()` per trip)

**What people do:** Wrap the matcher in `compute()` because it's the easy Flutter answer.
**Why it's wrong:** Every call reopens the OSM DB, cold-starts statement caches, and warm caches never accumulate. Cancellation is impossible.
**Do this instead:** One long-lived matcher isolate; message-passing protocol; explicit cancellation tokens.

### Anti-Pattern 3: Recomputing coverage on every map frame

**What people do:** `SUM(driven_length)/SUM(total_length)` in a StreamProvider watched by the map.
**Why it's wrong:** Millions of rows in the sum. Frame drops. Battery drain.
**Do this instead:** Cache table with explicit invalidation on interval commit / extract swap.

### Anti-Pattern 4: Storing GPS points as JSON blobs

**What people do:** `points: TEXT` JSON per trip.
**Why it's wrong:** Cannot index, cannot stream, cannot batch-write during recording.
**Do this instead:** `points(trip_id, seq, ts, lat, lon, speed, accuracy)` with an index on `(trip_id, seq)`.

### Anti-Pattern 5: Doing OSM parsing at runtime on-device

**What people do:** Ship the `.osm.pbf` and parse on first launch.
**Why it's wrong:** PBF parsing on a phone is slow, memory-hungry, and unnecessary — this work has no user value.
**Do this instead:** Offline pipeline → SQLite artifact with R-Tree pre-built + admin joins precomputed.

### Anti-Pattern 6: Cross-DB SQL joins via string concatenation

**What people do:** Try to join `app.driven_intervals` with `osm.ways` in one query.
**Why it's wrong:** Different files, different Drift instances, different isolates.
**Do this instead:** Either `ATTACH DATABASE` at the SQLite layer (one place, carefully), or join in Dart. In practice: join in Dart via id sets; only ATTACH if performance forces it.

### Anti-Pattern 7: Global singleton for the matcher

**What people do:** `MatchOrchestrator.instance` as a plain top-level.
**Why it's wrong:** Untestable, unmockable, ignores Riverpod scope, leaks isolates in tests.
**Do this instead:** Riverpod `Provider<MatchOrchestrator>` with `onDispose` that tears down the isolate.

---

## 11. Integration Points

### External services (all optional / offline)

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Geofabrik / Overpass | HTTPS download during OSM pipeline (dev-time) | Not in the app; part of `tool/osm_pipeline` |
| OSM extract CDN (self-hosted or S3) | HTTPS download, resumable | For in-app extract updates; verify checksum + schema version |
| MapLibre tile source | Style JSON references a local `mbtiles` (via `flutter_map_maplibre` or `maplibre_gl` custom provider) | Fully offline; no runtime network |

### Internal boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| UI ↔ services | Riverpod providers | UI never touches DAOs directly |
| Services ↔ App DB | Drift DAOs over `DriftIsolate` | Streams for reactive reads |
| Services ↔ OSM DB | RO Drift DAOs | Never mutated from services |
| Match orchestrator ↔ matcher isolate | `SendPort` with typed message protocol | Includes cancel + progress |
| Native bg plugin ↔ Dart | Method + event channels | Payloads are dumb records; validation on Dart side |
| Feature ↔ feature | Only via `domain` service interfaces exported from the target feature | No cross-feature UI imports |

---

## 12. Scaling Considerations

Trailblazer is single-user, so "scaling" here means **data scaling on one device**, not user scaling.

| Scale | Concern | Mitigation |
|-------|---------|------------|
| 100 trips | None | Naive queries fine |
| 10k trips / 5M GPS points | Trip list scroll, coverage recompute | Paginated inbox; incremental coverage; delete raw points after successful match (keep intervals) |
| 50k trips / 50M points | DB size, backup time | Partition points by year (view over `points_YYYY`); archive raw points to compressed blobs |
| Germany OSM ways ≈ 10M+ features | Map render, matcher candidate search | Vector-tile source for rendering (not GeoJSON); R-Tree tuned page size; candidate radius adaptive |

**First bottleneck (predicted):** map rendering with driven-way GeoJSON at country zoom. Fix by moving to a vector-tile local source with a driven-id lookup used in paint expressions (or a nightly precomputed "coverage overlay" tileset).

**Second bottleneck:** coverage aggregation after adding a very long trip. Fix by incremental delta application to `coverage_cache` (which regions did the new intervals touch?), never full recompute.

---

## 13. Sources

- Drift — Isolates & background databases (`https://drift.simonbinder.eu/isolates/`) — HIGH confidence for `DriftIsolate.spawn`, `computeWithDatabase`, and connection-sharing semantics.
- Drift — Migrations & schema tests (`https://drift.simonbinder.eu/migrations/`) — HIGH confidence for App DB migration approach.
- Newson, P., & Krumm, J. (2009). *Hidden Markov Map Matching Through Noise and Sparseness.* — HIGH confidence for HMM structure; standard reference.
- MapLibre Style Spec — data-driven paint expressions (`case`, `match`, feature-state) — HIGH confidence for style-based driven/undriven coloring.
- Apple Developer — Handling Location Events in the Background (Core Location) — HIGH confidence for iOS bg model constraints.
- Android Developer — Foreground services & background location — HIGH confidence for Android foreground-service requirement.
- Riverpod 2.x documentation (`AsyncNotifier`, `Notifier`, `autoDispose`, `family`) — HIGH confidence for provider patterns.
- Feature-first layering ("data / domain / presentation") — widely used Flutter convention; MEDIUM-HIGH confidence.

**Confidence caveats:**
- Exact iOS `BGTaskScheduler` behavior for a coverage-recompute task is device- and OS-version-dependent; validate empirically in Phase iOS-hardening.
- Whether a live GeoJSON source or a precomputed vector-tile overlay wins at Germany scale is an empirical question — assume GeoJSON for MVP, plan a vector-tile fallback.

---

*Architecture research for: Trailblazer (Flutter GPS trip-tracker with on-device OSM map-matching)*
*Researched: 2026-07-02*
