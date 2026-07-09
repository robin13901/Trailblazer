---
phase: 06-inbox-match-wire-up
plan: 06-06
subsystem: testing
tags: [golden-corpus, fixture-export, hmm-matcher, drift, path_provider, kDebugMode]

# Dependency graph
requires:
  - phase: 05-matching
    provides: golden_corpus_test.dart harness + FixtureWayCandidateSource + 3-file fixture format
  - phase: 06-05
    provides: TripDetailScreen (/trips/:id) to host the debug export FAB
provides:
  - GoldenFixtureExporter service (trip → 3-file golden fixture under AppDocs)
  - kDebugMode-only "Export fixture" FAB on TripDetailScreen (tree-shaken from release)
  - record → export → pull → commit workflow documentation
affects: [phase-6-close-out-drives, phase-7-rendering, matcher-regression]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Debug-only widget + co-located provider gated by kDebugMode compile-time const for release tree-shaking"
    - "Async appDocsFactory seam (Future<Directory> Function()) for path_provider test injection"
    - "Atomic file write via tmp + rename per file"

key-files:
  created:
    - lib/features/trips/data/golden_fixture_exporter.dart
    - lib/features/trips/presentation/widgets/debug_export_button.dart
    - test/features/trips/golden_fixture_exporter_test.dart
  modified:
    - lib/features/trips/presentation/trip_detail_screen.dart
    - test/fixtures/golden_trips/README.md

key-decisions:
  - "ways.json.gz captures RAW bbox ways (fetchWaysInBbox), NOT corridor-filtered subset — corpus test re-derives the filter"
  - "Path B (re-gzip from parsed WayCandidates) chosen over Path A (raw cache bytes) — per-tile cache bytes can't concatenate into one valid envelope"
  - "expected_ways.json shape is {wayId, direction} (matching the REAL 001 fixture), NOT the plan-sketched {wayId, startMeters, endMeters}"
  - "Provider wired via existing wayCandidateSourceProvider + tripsDaoProvider + DrivenWayIntervalsDao(appDatabaseProvider) — the plan-sketched overpassWayCandidateSourceProvider/drivenWayIntervalsDaoProvider do not exist"
  - "appDocsFactory seam is Future<Directory> Function() (async) — path_provider's resolver is async, unlike the plan's synchronous Directory Function() sketch"
  - "≥20-fixture (and ≥3-seed) accumulation DEFERRED-to-manual — requires real drives; tooling is the deliverable"

patterns-established:
  - "kDebugMode-gated debug tooling: widget returns SizedBox.shrink + provider only read from debug branch → dropped from release binary"

# Metrics
duration: ~40min
completed: 2026-07-09
---

# Phase 6 Plan 06-06: Golden Corpus Expansion Tooling Summary

**Shipped the golden-corpus export pipeline — a `GoldenFixtureExporter` service plus a kDebugMode-only "Export fixture" FAB on TripDetailScreen — that turns any recorded trip into a commit-ready 3-file matcher regression fixture; corpus accumulation to ≥20 is deferred to real close-out drives.**

## Performance

- **Duration:** ~40 min
- **Completed:** 2026-07-09
- **Tasks:** 3/3 (autonomous, no checkpoints)
- **Files created:** 3 · **modified:** 2

## Accomplishments

- **`GoldenFixtureExporter.export(tripId, slug)`** reads a trip's raw state (`TripsDao.listPointsForTrip`, `WayCandidateSource.fetchWaysInBbox`, `DrivenWayIntervalsDao.getByTrip`) and writes `gps_trace.json` + `ways.json.gz` + `expected_ways.json` to `<AppDocs>/golden_export/<slug>/`. Slug validated `^\d{3}_[a-z0-9_]+$`; atomic tmp+rename per file; clean overwrite on slug collision.
- **`DebugExportButton`** — kDebugMode-only FAB wired as `TripDetailScreen.floatingActionButton`; slug-prompt dialog → export → path/error SnackBar. Absent (SizedBox.shrink) and tree-shaken in release/profile builds.
- **README rewritten** around the in-app export FAB (replaced the stale `save_trip_fixture.dart` CLI reference), documenting record → export → adb/simulator pull → verify → commit.
- **7 exporter unit tests** including a mandatory round-trip: the exported `ways.json.gz` re-parses through the exact corpus helper (`FixtureWayCandidateSource.fromGzippedOverpassJson`) and covers the seeded interval way ids — Path A/B drift fails loudly.
- **Regression proven:** existing `golden_corpus_test.dart` (fixture `001_synthetic_straight_east`) still green; full `test/features/trips/` suite (180 tests) green.

## Exporter API

```dart
class GoldenFixtureExporter {
  GoldenFixtureExporter({
    required TripsDao tripsDao,
    required WayCandidateSource waySource,
    required DrivenWayIntervalsDao intervalsDao,
    Future<Directory> Function()? appDocsFactory, // test seam (async)
  });

  /// Returns absolute path to <AppDocs>/golden_export/<slug>/.
  /// Throws StorageError on invalid slug / no points; propagates NetworkError.
  Future<String> export({required int tripId, required String slug});
}

// Debug-only provider, co-located in debug_export_button.dart:
final goldenFixtureExporterProvider = Provider<GoldenFixtureExporter>((ref) => ...);
```

## Deviations from Plan

The plan's task sketches were written before inspecting the real fixture; several sketched details were wrong and corrected against ground truth:

1. **[Rule 1 — schema correction] `expected_ways.json` shape.** The plan sketched `{wayId, startMeters, endMeters}`. The REAL `001_synthetic_straight_east/expected_ways.json` and `golden_corpus_test.dart` use `{wayId, direction}`. Matched the real format. (Files: golden_fixture_exporter.dart)
2. **[Rule 3 — API correction] Provider wiring.** The plan referenced `overpassWayCandidateSourceProvider` and `drivenWayIntervalsDaoProvider` — neither exists. Wired via the real `wayCandidateSourceProvider` (interface), `tripsDaoProvider`, and `DrivenWayIntervalsDao(ref.watch(appDatabaseProvider))`.
3. **[Rule 3 — API correction] `appDocsFactory` seam is async.** The plan sketched `Directory Function()?`; `path_provider`'s `getApplicationDocumentsDirectory` is `Future<Directory>`, so the seam is `Future<Directory> Function()`. Tests pass `() async => tempDir`.
4. **[Issue 7 decision] Path B (re-gzip) chosen.** `fetchWaysInBbox` returns parsed `WayCandidate`s, and the cache stores per-tile gzipped Overpass bytes that can't be concatenated into a single valid envelope. So the exporter re-emits an Overpass `out geom;`-shaped envelope from the candidates and gzips it. Documented in the exporter's file header. The round-trip test validates the choice.
5. **[Scope] No widget smoke test added.** The plan Task 2 suggested a FAB smoke test, but the plan frontmatter `files_owned`/`files_modified` does not list a button-test file or `trip_detail_screen_test.dart`. Per the strict ownership scope, no out-of-scope test files were created/modified. Coverage of the FAB integration is proven by the existing `trip_detail_screen_test.dart` (12 tests) staying green with the FAB present.

## DEFERRED-to-manual

**The "≥3 seed fixtures exported" (and ≥20 close-out) must-have is DEFERRED-to-manual.** Exporting fixtures requires real recorded drives on a device — the execution environment has no device/trips. The export *tooling* is what ships in this plan; fixture accumulation happens organically during the Phase 6 close-out drive batch (batched per memory `defer-in-car-verification` / `phase-4-drives-deferred-to-gym-trip`). The README documents the full pull→verify→commit loop for that batch. This is NOT a blocker for plan completion.

## Verification

- `flutter analyze` (trips lib + tests) — No issues found.
- `flutter test test/features/trips/` — 180 passed.
- `flutter test test/features/matching/golden_corpus_test.dart` — passed (regression).

## Commits

- `6d23cff` feat(06-06): GoldenFixtureExporter with 3-file corpus export
- `5cc22d6` feat(06-06): kDebugMode-only Export fixture FAB on TripDetailScreen
- `dc2e7c5` docs(06-06): golden corpus record→export→pull→commit workflow
