---
plan: 06-01
phase: 6
wave: 1
depends_on: []
type: execute
autonomous: true
files_owned:
  - lib/features/coverage/data/coverage_cache_dao.dart
  - lib/features/coverage/data/coverage_invalidator.dart
  - lib/features/coverage/data/coverage_providers.dart
  - lib/features/coverage/domain/interval_union.dart
  - test/features/coverage/coverage_cache_dao_test.dart
  - test/features/coverage/coverage_invalidator_test.dart
  - test/features/coverage/interval_union_test.dart
files_modified:
  - lib/features/coverage/data/coverage_cache_dao.dart
  - lib/features/coverage/data/coverage_invalidator.dart
  - lib/features/coverage/data/coverage_providers.dart
  - lib/features/coverage/domain/interval_union.dart
  - test/features/coverage/coverage_cache_dao_test.dart
  - test/features/coverage/coverage_invalidator_test.dart
  - test/features/coverage/interval_union_test.dart
must_haves:
  truths:
    - "Writing new driven_way_intervals for a trip deletes affected coverage_cache rows (COV-06 trigger 1, invoked via confirmTrip in 06-02)"
    - "Deleting a trip via the invalidator path removes affected coverage_cache rows (COV-06 trigger 2)"
    - "invalidateAll() truncates coverage_cache as a stub for OSM-extract-updated (COV-06 trigger 3)"
    - "Interval union collapses overlapping per-way intervals into disjoint segments (COV-01)"
    - "coverage_cache is queryable and writeable via a DatabaseAccessor-style DAO"
  artifacts:
    - path: "lib/features/coverage/domain/interval_union.dart"
      provides: "Pure-Dart sweep-line union of [start,end] intervals"
      min_lines: 20
    - path: "lib/features/coverage/data/coverage_cache_dao.dart"
      provides: "CRUD for CoverageCache rows keyed by regionId"
    - path: "lib/features/coverage/data/coverage_invalidator.dart"
      provides: "invalidateForTrip / invalidateForTripDelete / invalidateAll"
    - path: "lib/features/coverage/data/coverage_providers.dart"
      provides: "Provider<CoverageCacheDao>, Provider<CoverageInvalidator>"
  key_links:
    - from: "CoverageInvalidator.invalidateForTrip"
      to: "AdminRegionLookup.regionAt"
      via: "Point-in-polygon sampling at trip bbox corners + centroid, levels 4/6/8/10"
      pattern: "AdminRegionLookup"
    - from: "CoverageInvalidator"
      to: "CoverageCacheDao.deleteByRegionIds"
      via: "batch DELETE FROM coverage_cache WHERE region_id IN (...)"
      pattern: "deleteByRegionIds|DELETE FROM coverage_cache"
verification:
  analyzer: "flutter analyze passes with no new warnings"
  tests:
    - test/features/coverage/interval_union_test.dart
    - test/features/coverage/coverage_cache_dao_test.dart
    - test/features/coverage/coverage_invalidator_test.dart
---

<objective>
Ship the pure data-layer foundation for Phase 6 coverage-cache invalidation and per-way interval unioning: a CoverageCacheDao over the existing `coverage_cache` table, a CoverageInvalidator with three triggers (new intervals, trip delete, OSM extract stub), and a pure-Dart interval-union utility. No UI, no wiring into TripsRepository yet (that lives in 06-02).

**Naming reconciliation:** REQUIREMENTS.md (COV-05) and ROADMAP.md refer to a `coverage_by_region` table. The **physical Drift table at schema v3 is named `coverage_cache`** (see `lib/core/db/tables/coverage_cache_table.dart` and `drift_schemas/drift_schema_v3.json`). No rename is performed in Phase 6 — the requirements-doc name is treated as the logical alias for the physical `coverage_cache` table. When writing SUMMARY, restate this reconciliation so downstream plans/phases don't chase a ghost rename.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/06-inbox-match-wire-up/06-CONTEXT.md
@.planning/phases/06-inbox-match-wire-up/06-RESEARCH.md
@CLAUDE.md

# Existing infrastructure to reuse (READ these, do not duplicate)
@lib/core/db/tables/coverage_cache_table.dart
@lib/core/db/app_database.dart
@lib/features/admin/data/admin_region_lookup.dart
@lib/features/admin/data/admin_region_providers.dart
@lib/features/trips/data/trips_dao.dart
@lib/features/trips/data/trips_repository.dart
@drift_schemas/drift_schema_v3.json
</context>

<invariants>
- Riverpod codegen OFF — use plain `Provider<T>` / `Notifier`; no `@Riverpod` annotations.
- Package imports only (`package:auto_explore/...`).
- `sort_pub_dependencies` — no new deps expected in this plan.
- `DomainError` + `Result<T>` at boundaries; wrap non-DomainError throwables via `DomainError.wrap()`.
- Codegen order: `build_runner build` → `drift_dev schema generate` → `flutter analyze`/`flutter test`.
- `withValues(alpha:)` never `withOpacity()` (no UI here but stay disciplined).
- Ralph Loop tiered: run `flutter analyze` per commit; the pre-push hook covers `flutter test`.
- NO schema bump — `coverage_cache` already exists at schema v3 (do NOT touch table definition).
- NO drive checkpoint in this plan — deferred to phase close-out.
</invariants>

<tasks>

<task id="1" type="auto">
  <title>Task 1: Pure-Dart interval-union utility (COV-01 core)</title>
  <files>
    lib/features/coverage/domain/interval_union.dart
    test/features/coverage/interval_union_test.dart
  </files>
  <action>
Create a Drift-free, isolate-safe sweep-line union over half-open intervals `[startMeters, endMeters)`.

Signature:
```dart
class Interval {
  const Interval(this.startMeters, this.endMeters)
      : assert(endMeters >= startMeters);
  final double startMeters;
  final double endMeters;
  double get lengthMeters => endMeters - startMeters;
}

/// Collapse overlapping/adjacent intervals into disjoint unions.
/// Input intervals are copied; input list is not mutated.
/// Returns a new list sorted by startMeters.
List<Interval> unionIntervals(Iterable<Interval> intervals);

/// Sum of union lengths.
double drivenLengthMeters(Iterable<Interval> intervals);
```

Algorithm (from RESEARCH.md Q3):
1. Copy inputs to a list, sort by startMeters ascending.
2. Iterate; if current.start > merged.last.end → append; else merge by setting `merged.last.end = max(merged.last.end, current.end)`.
3. Adjacent intervals (start == last.end) merge (belt-and-suspenders for float noise).

Tests (`test/features/coverage/interval_union_test.dart`):
- empty → empty, drivenLength == 0
- single interval preserved
- two disjoint intervals stay disjoint, sum correct
- two overlapping [0,10] + [5,15] → [0,15], length 15
- fully contained [0,20] + [5,10] → [0,20]
- three chained overlaps + one disjoint tail
- unsorted input still produces sorted output
- adjacent [0,10] + [10,20] → [0,20]
- floating-point precision: [0.0, 0.1] + [0.1, 0.2] → single interval, length ≈ 0.2

NO Drift import in this file. NO Riverpod. Pure Dart.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/coverage/interval_union_test.dart` — all cases green.
  </verify>
  <done>
`interval_union.dart` exists with `Interval`, `unionIntervals`, `drivenLengthMeters`; ≥9 test cases pass.
  </done>
</task>

<task id="2" type="auto">
  <title>Task 2: CoverageCacheDao (DatabaseAccessor pattern)</title>
  <files>
    lib/features/coverage/data/coverage_cache_dao.dart
    test/features/coverage/coverage_cache_dao_test.dart
  </files>
  <action>
Add a manual-DAO (constructor takes `AppDatabase` — match `TripsDao` style; **no** `@DriftAccessor`).

Public API:
```dart
class CoverageCacheDao {
  CoverageCacheDao(this._db);
  final AppDatabase _db;

  /// Upsert (used by Phase 8 recompute; provide now so Phase 8 doesn't reopen this DAO).
  Future<void> upsert({
    required String regionId,
    required double drivenLengthM,
    required double totalLengthM,
    required DateTime updatedAt,
    String? extractVersion,
  });

  /// Point-read.
  Future<CoverageCache?> getByRegionId(String regionId);

  /// Batch delete affected rows on invalidation.
  Future<int> deleteByRegionIds(Iterable<String> regionIds);

  /// Nuke everything (OSM-extract-updated stub in P6).
  Future<int> deleteAll();

  /// Convenience: bump invalidationGen without recomputing (for Phase 8-ready path).
  /// P6 doesn't call this but ship it now for symmetry.
  Future<void> bumpInvalidationGen(String regionId);
}
```

Reference the existing table via the generated `CoverageCache` data class + `coverageCache` accessor on `AppDatabase`. Do NOT redefine the table.

Column names for reference (verified against `drift_schemas/drift_schema_v3.json` `coverage_cache` entity): `region_id` (PK), `driven_length_m`, `total_length_m`, `updated_at`, `extract_version`, `invalidation_gen`. Use the Drift-generated Dart field names (`regionId`, `drivenLengthM`, etc.) — do not hand-write raw SQL against these column names.

Tests (`test/features/coverage/coverage_cache_dao_test.dart`) using in-memory Drift (`NativeDatabase.memory()`) — follow the pattern from any existing DAO test (grep `test/core/db/` or `test/features/trips/`):
- upsert then getByRegionId round-trips all fields including `extractVersion` and `invalidationGen == 0`.
- deleteByRegionIds([]) is a no-op returning 0 (guard the empty-list SQL edge case).
- deleteByRegionIds with 3 IDs deletes exactly those 3.
- deleteAll clears all rows and returns the deleted count.
- bumpInvalidationGen increments from 0 → 1 → 2.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/coverage/coverage_cache_dao_test.dart` green.
  </verify>
  <done>
DAO exists with 5 public methods; all test cases pass.
  </done>
</task>

<task id="3" type="auto">
  <title>Task 3: CoverageInvalidator + coverage_providers</title>
  <files>
    lib/features/coverage/data/coverage_invalidator.dart
    lib/features/coverage/data/coverage_providers.dart
    test/features/coverage/coverage_invalidator_test.dart
  </files>
  <action>
`CoverageInvalidator` orchestrates cache invalidation from three triggers. Keep it agnostic of when it's called — 06-02 wires it into TripsRepository (both `confirmTrip` and `discardTrip` paths).

Signature:
```dart
class CoverageInvalidator {
  CoverageInvalidator({
    required CoverageCacheDao cacheDao,
    required AdminRegionLookup regionLookup,
    required TripsDao tripsDao,          // for bbox lookup
  });

  /// Trigger 1: called by TripsInboxRepository.confirmTrip AFTER status flip
  /// (matched → confirmed), so the "user has accepted this trip as counting
  /// for coverage" moment invalidates affected regions.
  /// Reads trip.bbox (bbox_min_lat/bbox_min_lon/bbox_max_lat/bbox_max_lon),
  /// samples the 4 corners + centroid, resolves adminRegionIds at levels
  /// 4/6/8/10 via AdminRegionLookup.regionAt, dedupes, and calls
  /// cacheDao.deleteByRegionIds(regionIds).
  /// Idempotent — calling repeatedly for the same trip after cache is already
  /// invalidated deletes 0 rows and returns Result.ok(0).
  /// Returns Result<int> — count of coverage rows invalidated.
  Future<Result<int>> invalidateForTrip(int tripId);

  /// Trigger 2: called by TripsInboxRepository.discardTrip BEFORE deleting the trip,
  /// so bbox is still readable. Identical body to invalidateForTrip.
  Future<Result<int>> invalidateForTripDelete(int tripId);

  /// Trigger 3 (P6 stub for OSM extract updated — wired in P10).
  /// Truncates coverage_cache.
  Future<Result<int>> invalidateAll();
}
```

- Wrap all non-DomainError throwables via `DomainError.wrap()` and return `Result<int>` via existing helpers.
- If trip row is null OR bbox is null (fail-matched trip): return `Result.ok(0)` — no invalidation.
- Sample levels [4, 6, 8, 10] against `AdminRegionLookup.regionAt(lat, lon, level)`; skip null returns.

Providers (`lib/features/coverage/data/coverage_providers.dart`):
```dart
final coverageCacheDaoProvider = Provider<CoverageCacheDao>((ref) {
  return CoverageCacheDao(ref.watch(appDatabaseProvider));
});

final coverageInvalidatorProvider = Provider<CoverageInvalidator>((ref) {
  return CoverageInvalidator(
    cacheDao: ref.watch(coverageCacheDaoProvider),
    regionLookup: ref.watch(adminRegionLookupProvider),
    tripsDao: ref.watch(tripsDaoProvider),
  );
});
```

Tests (`test/features/coverage/coverage_invalidator_test.dart`) — use fakes for `AdminRegionLookup` and `TripsDao`, real `CoverageCacheDao` on in-memory Drift:
- invalidateForTrip on a trip with bbox in Kleinheubach → deletes rows for the 4 sampled admin regionIds (fake returns e.g. "DE"/"BY"/"MIL"/"KHB").
- invalidateForTrip on a trip with NULL bbox → returns `Result.ok(0)`, no deletes issued.
- invalidateForTrip on a missing tripId → returns `Result.ok(0)`.
- invalidateForTrip called twice for the same trip → second call returns Result.ok(0) after seeded regions already deleted (idempotency).
- invalidateForTripDelete produces the same behavior as invalidateForTrip (share the impl).
- invalidateAll wipes all seeded rows and returns the count.
- AdminRegionLookup returning null for some corners doesn't crash (skip nulls).

Pitfall reminders (from RESEARCH.md §Pitfalls):
- `coverage_cache` PK is `regionId` alone — OSM relation IDs are globally unique across levels; do NOT prefix with `"$level:"`.
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/coverage/coverage_invalidator_test.dart` green.
  </verify>
  <done>
`CoverageInvalidator` exposes 3 methods, all returning `Result<int>`; providers exist; ≥7 test cases pass including the idempotency case that 06-02 relies on.
  </done>
</task>

</tasks>

<verification>
Fast-loop (per commit): `flutter analyze` (also `flutter analyze --fatal-infos` since we're touching data-layer files).
Behavior-sensitive (run inside the loop too, this plan is all logic): `flutter test test/features/coverage/`.
Pre-push hook covers the full test suite.
</verification>

<success_criteria>
- Three test files added, all cases pass on `flutter test`.
- Analyzer clean.
- `CoverageInvalidator` is callable via `ref.read(coverageInvalidatorProvider)` — verified by 06-02 wiring test.
- No changes to `coverage_cache_table.dart` or `app_database.dart` schema definitions.
- `invalidationGen` column left untouched (P8 uses it; P6 just deletes rows).
- SUMMARY.md restates the `coverage_by_region` (docs) → `coverage_cache` (physical) naming reconciliation.
</success_criteria>

<output>
After completion, create `.planning/phases/06-inbox-match-wire-up/06-01-SUMMARY.md` per the summary template.
Key items to capture: exact DAO/invalidator API signatures (so 06-02 can wire without re-reading source), decision to DELETE rather than bump gen in P6, list of admin levels sampled (4/6/8/10), and the naming reconciliation note (REQUIREMENTS.md `coverage_by_region` == physical `coverage_cache`).
</output>
</content>
</invoke>