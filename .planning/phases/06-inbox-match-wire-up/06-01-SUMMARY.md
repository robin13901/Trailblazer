---
phase: 06-inbox-match-wire-up
plan: 06-01
subsystem: coverage-cache
tags: [drift, coverage-cache, admin-region, invalidation, hmm-post-match]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: AdminRegionLookup (bundled Germany admin polygons + 0.01° hash grid — Plan 04-16)
  - phase: 04-osm-pipeline
    provides: TripsDao / Trips table bbox columns (Plan 03-01 + 03-04)
  - phase: 01-scaffolding
    provides: coverage_cache Drift table (schema v3, Plan 01-02)
provides:
  - CoverageCacheDao — CRUD over the physical coverage_cache table
  - CoverageInvalidator — three-trigger orchestrator (invalidateForTrip, invalidateForTripDelete, invalidateAll)
  - unionIntervals / drivenLengthMeters — pure-Dart sweep-line union over half-open per-way intervals
  - coverageCacheDaoProvider + coverageInvalidatorProvider — plain Provider<T> wiring
affects: [06-02 TripsInboxRepository wiring, 06-04+ inbox/history UI, 08 coverage recompute, 10 OSM extract swap]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Manual DatabaseAccessor DAO (matches TripsDao — STATE 03-01) — no @DriftAccessor, no part file, drops in without touching AppDatabase.daos"
    - "Orchestrator-agnostic invalidator: three trigger methods, all returning Result<int>, called by TripsInboxRepository in 06-02"
    - "hide isNotNull, isNull on drift.dart imports in DAO tests (STATE 05-01 pattern)"

key-files:
  created:
    - lib/features/coverage/domain/interval_union.dart
    - lib/features/coverage/data/coverage_cache_dao.dart
    - lib/features/coverage/data/coverage_invalidator.dart
    - lib/features/coverage/data/coverage_providers.dart
    - test/features/coverage/interval_union_test.dart
    - test/features/coverage/coverage_cache_dao_test.dart
    - test/features/coverage/coverage_invalidator_test.dart
  modified: []

key-decisions:
  - "Naming reconciliation: REQUIREMENTS.md coverage_by_region is the logical alias for the physical coverage_cache table; no rename performed in Phase 6"
  - "P6 invalidator DELETES cache rows outright rather than bumping invalidation_gen — the gen column is Phase-8's recompute concern"
  - "Sampled admin levels are [4, 6, 8, 10] (L2 country intentionally excluded — the full-DE row would invalidate on every trip)"
  - "Region key is the plain osm_id string with NO level prefix — OSM relation IDs are globally unique across admin levels (Plan 04-01 pitfall)"
  - "Missing trip / null bbox / no matching regions all short-circuit to Ok(0); idempotency comes from the DELETE returning 0 on the second call"
  - "TripsDao does not expose getById; the invalidator queries db.trips directly via tripsDao.attachedDatabase to avoid touching a file outside files_owned"

patterns-established:
  - "CoverageCacheDao surface is superset of what P6 needs — upsert + bumpInvalidationGen ship now for Phase-8 symmetry so P8 does not need to reopen this DAO"
  - "deleteByRegionIds([]) fast-path returns 0 without issuing SQL (guards SQLite's empty-IN-list error)"
  - "Interval union collapses adjacent boundaries (a.end == b.start) as a belt-and-suspenders float-precision guard — driven-way intervals accumulate from HMM projection fractions and can meet at exact floats"

# Metrics
duration: 10min
completed: 2026-07-09
---

# Phase 6 Plan 06-01: Coverage Cache DAO + Invalidator + Interval Union Summary

**Pure data-layer foundation for Phase 6 coverage-cache invalidation: CoverageCacheDao over the existing `coverage_cache` table, CoverageInvalidator with three triggers (new intervals, trip delete, OSM-extract stub), and a sweep-line interval union — ready for 06-02 to wire into TripsInboxRepository.**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-09T11:21:33Z
- **Completed:** 2026-07-09T11:31:33Z
- **Tasks:** 3/3
- **Files created:** 7 (3 lib + 4 test/providers)

## Accomplishments

- Sweep-line `unionIntervals` + `drivenLengthMeters` shipped as isolate-safe pure Dart (Drift-free, Riverpod-free) — will feed the Phase-8 recompute pass without an isolate-boundary refactor
- `CoverageCacheDao` provides 5 public methods (`upsert`, `getByRegionId`, `deleteByRegionIds`, `deleteAll`, `bumpInvalidationGen`) — enough for both P6 delete-on-invalidation and P8 recompute upsert
- `CoverageInvalidator` orchestrates all three COV-06 triggers behind a single `Result<int>` contract; 06-02 can wire without knowing the sampling ladder or the region-dedup shape
- Naming reconciliation captured: REQUIREMENTS.md `coverage_by_region` is the docs alias; the physical Drift table stays as `coverage_cache` at schema v3. No rename in P6, downstream plans should stop chasing it.

## Task Commits

Each task was committed atomically with only files_owned staged:

1. **Task 1: Pure-Dart interval-union utility (COV-01 core)** — `21423f6` (feat)
2. **Task 2: CoverageCacheDao (DatabaseAccessor pattern)** — `121fe2d` (feat)
3. **Task 3: CoverageInvalidator + coverage_providers** — `3320a33` (feat)

Metadata commit follows this SUMMARY + STATE update.

## Files Created

- `lib/features/coverage/domain/interval_union.dart` — `Interval` (`@immutable`, value equality), `unionIntervals`, `drivenLengthMeters`. Sort + sweep, merges overlapping AND adjacent intervals. No `dart:io`, no Riverpod.
- `lib/features/coverage/data/coverage_cache_dao.dart` — `DatabaseAccessor<AppDatabase>` (no `@DriftAccessor`, no part file). Public API: `upsert / getByRegionId / deleteByRegionIds / deleteAll / bumpInvalidationGen`.
- `lib/features/coverage/data/coverage_invalidator.dart` — 3-trigger orchestrator with `invalidateForTrip`, `invalidateForTripDelete`, `invalidateAll`. Samples 5 points (bbox corners + centroid) × 4 admin levels = 20 lookups per trip; region IDs deduped by `osm_id` string.
- `lib/features/coverage/data/coverage_providers.dart` — `coverageCacheDaoProvider` and `coverageInvalidatorProvider` (plain `Provider<T>`; watches `appDatabaseProvider`, `adminRegionLookupProvider`, `tripsDaoProvider`).
- `test/features/coverage/interval_union_test.dart` — 10 test cases: empty, single, disjoint, overlap, contained, chained, unsorted, adjacent, float-precision, non-mutation guard.
- `test/features/coverage/coverage_cache_dao_test.dart` — 7 tests against in-memory Drift: round-trip, upsert replace, null miss, empty-list guard, batch delete, deleteAll, gen bump.
- `test/features/coverage/coverage_invalidator_test.dart` — 7 tests with a `_FakeAdminRegionLookup` fake + real DAO/TripsDao on in-memory Drift: 4-region delete, null bbox, missing trip, idempotent second call, null-lookup at some levels skipped, invalidateForTripDelete shares behavior, invalidateAll truncates.

## API Reference (for 06-02 wiring — do not re-read source)

```dart
// coverage_providers.dart
final coverageCacheDaoProvider = Provider<CoverageCacheDao>((ref) { ... });
final coverageInvalidatorProvider = Provider<CoverageInvalidator>((ref) { ... });

// coverage_invalidator.dart
class CoverageInvalidator {
  CoverageInvalidator({
    required CoverageCacheDao cacheDao,
    required AdminRegionLookup regionLookup,
    required TripsDao tripsDao,
  });

  /// After confirmTrip flips matched -> confirmed. Idempotent.
  Future<Result<int>> invalidateForTrip(int tripId);

  /// Before discardTrip deletes the row (bbox must still be readable).
  Future<Result<int>> invalidateForTripDelete(int tripId);

  /// OSM-extract-updated stub — wired in P10. Truncates coverage_cache.
  Future<Result<int>> invalidateAll();
}

// coverage_cache_dao.dart
class CoverageCacheDao extends DatabaseAccessor<AppDatabase> {
  Future<void> upsert({
    required String regionId,
    required double drivenLengthM,
    required double totalLengthM,
    required DateTime updatedAt,
    String? extractVersion,
  });
  Future<CoverageCacheData?> getByRegionId(String regionId);
  Future<int> deleteByRegionIds(Iterable<String> regionIds);
  Future<int> deleteAll();
  Future<void> bumpInvalidationGen(String regionId);
}

// interval_union.dart
@immutable
class Interval {
  const Interval(double startMeters, double endMeters);
  double get lengthMeters;
}
List<Interval> unionIntervals(Iterable<Interval> intervals);
double drivenLengthMeters(Iterable<Interval> intervals);
```

Sampled admin levels: `kCoverageAdminLevels = [4, 6, 8, 10]` (exported constant on `coverage_invalidator.dart`).

## Decisions Made

1. **Delete rather than gen-bump in P6.** `invalidation_gen` is Phase-8's concern — P6 removes cache rows outright at every trigger. The DAO ships `bumpInvalidationGen` anyway so Phase 8 does not need to reopen this file.
2. **Admin levels sampled = [4, 6, 8, 10].** L2 (country) intentionally excluded — the full-DE region row would invalidate on every trip inside Germany, defeating the cache. L9 excluded per plan text (`4/6/8/10` was the sample set specified in the plan's key-links entry).
3. **Region key format = plain osm_id string, no level prefix.** OSM relation IDs are globally unique across admin levels (STATE Plan 04-01 pitfall). Prefixing with `"$level:"` would fragment the cache.
4. **Naming reconciliation `coverage_by_region` → `coverage_cache`.** REQUIREMENTS.md (COV-05) and ROADMAP.md talk about a `coverage_by_region` table; the physical Drift table at schema v3 is `coverage_cache`. No rename in P6. Downstream plans should treat the docs name as a logical alias.
5. **`_loadTrip` queries `tripsDao.attachedDatabase` directly** instead of adding a `getById` method to TripsDao — `trips_dao.dart` is not in this plan's `files_owned`, so touching it would break Wave-1 file-ownership hygiene. If a future plan formalises a `getById` on TripsDao, this can be refactored inward.
6. **Fake AdminRegionLookup subclasses the concrete class via `implements`** — the concrete class exposes public getters `bundleLoadCount` and `regionCount` that we override to make the fake test-usable without loading real assets.

## Deviations from Plan

None substantive. Two mechanical Ralph-loop fixes during Task 3:

1. **[Rule 1 - Bug] Removed unused `import 'package:drift/drift.dart'` from `coverage_invalidator.dart`** — `Trip` (return type of `_loadTrip`) is exported via `TripsDao`'s dependency chain, so the drift import was redundant. Analyzer warning `unused_import`.
2. **[Rule 3 - Blocking] `hide isNull, isNotNull` on the drift import in `coverage_invalidator_test.dart`** — drift's top-level `isNull` / `isNotNull` query builders collide with `flutter_test`'s matchers. Same fix pattern as STATE Plan 05-01. Combinator ordering also alphabetized to satisfy `combinators_ordering`.

Both are trivial ralph-loop iterations, not spec deviations.

## Authentication Gates

None.

## Verification

- `flutter analyze --no-pub` — clean
- `flutter test test/features/coverage/` — 24/24 green (10 interval_union + 7 coverage_cache_dao + 7 coverage_invalidator)

## Wave-1 Hygiene

Files staged INDIVIDUALLY per Wave-1 rule (memory: `wave-2-parallel-metadata-hygiene`). No `git add .` / `git add -A` used. Sibling agent 06-03 landed 2 commits between my Task 1 and Task 2 (`ae2cc5c` + `2c6bef0`); my task commits remain scoped exclusively to `files_owned`.

## Next Plan (06-02 — TripsInboxRepository wiring)

06-02 imports `coverageInvalidatorProvider` and calls:
- `invalidator.invalidateForTrip(tripId)` **AFTER** the status flip inside `confirmTrip` (matched → confirmed)
- `invalidator.invalidateForTripDelete(tripId)` **BEFORE** the trip row is deleted inside `discardTrip` (bbox must still be readable)

Both calls should surface failures as `Result<T>` at the repository boundary. The idempotent `Ok(0)` short-circuits already handle re-confirm and missing-trip cases.
