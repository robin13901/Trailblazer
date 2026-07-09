---
plan: 06-06
phase: 6
wave: 3
depends_on: [06-05]
type: execute
autonomous: true
files_owned:
  - lib/features/trips/presentation/widgets/debug_export_button.dart
  - lib/features/trips/data/golden_fixture_exporter.dart
  - test/features/trips/golden_fixture_exporter_test.dart
  - test/fixtures/golden_trips/README.md
files_modified:
  - lib/features/trips/presentation/widgets/debug_export_button.dart
  - lib/features/trips/data/golden_fixture_exporter.dart
  - test/features/trips/golden_fixture_exporter_test.dart
  - test/fixtures/golden_trips/README.md
  - lib/features/trips/presentation/trip_detail_screen.dart
must_haves:
  truths:
    - "In kDebugMode, TripDetailScreen shows an 'Export as golden fixture' action (Q9)"
    - "Exporter writes gps_trace.json + ways.json.gz + expected_ways.json to <AppDocs>/golden_export/<slug>/ (Q9)"
    - "test/fixtures/golden_trips/README.md documents the export → commit → golden_corpus_test workflow"
    - "Existing golden_corpus_test still passes with the current fixture (regression check)"
    - "At minimum 3 seed fixtures are exported by end of P6 dogfooding (best-effort; ≥20 remains the phase-close-out goal)"
  artifacts:
    - path: "lib/features/trips/data/golden_fixture_exporter.dart"
      provides: "GoldenFixtureExporter.export(tripId, slug) → Future<String pathToDir>"
    - path: "lib/features/trips/presentation/widgets/debug_export_button.dart"
      provides: "Debug-only FAB attached to TripDetailScreen"
    - path: "test/fixtures/golden_trips/README.md"
      provides: "Workflow docs for record → export → commit"
  key_links:
    - from: "debug_export_button.dart"
      to: "GoldenFixtureExporter.export"
      via: "onPressed handler in kDebugMode-guarded widget"
      pattern: "kDebugMode"
    - from: "GoldenFixtureExporter"
      to: "TripsDao.listPointsForTrip / OverpassWayCandidateSource / DrivenWayIntervalsDao.getByTrip"
      via: "read → serialize → write to AppDocs"
      pattern: "listPointsForTrip|fetchWaysInBbox|getByTrip"
verification:
  analyzer: "flutter analyze passes"
  tests:
    - test/features/trips/golden_fixture_exporter_test.dart
    - test/features/matching/golden_corpus_test.dart
---

<objective>
Ship the golden-corpus expansion tooling (kDebugMode-only export button + exporter service) and document the record → export → commit workflow. Fixture accumulation happens organically during Phase 6 dogfooding drives; the drive itself is the phase close-out checkpoint (already covered by 06-05's checkpoint + batched drive per memory `phase-4-drives-deferred-to-gym-trip`).
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
@.planning/phases/06-inbox-match-wire-up/06-05-SUMMARY.md
@CLAUDE.md

# Existing golden infrastructure
@test/features/matching/golden_corpus_test.dart
@test/fixtures/golden_trips/

# Data sources for export
@lib/features/trips/data/trips_dao.dart
@lib/features/matching/data/overpass_way_candidate_source.dart
@lib/core/db/daos/driven_way_intervals_dao.dart
</context>

<invariants>
- Riverpod codegen OFF.
- Package imports only.
- `withValues(alpha:)` never `withOpacity()`.
- Debug-only button MUST be gated by `kDebugMode` (tree-shaken from release — see `foundation.dart`).
- No new packages — reuse `dart:io`, `dart:convert`, `path_provider`, `path`.
- No drive checkpoint in THIS plan; the drive that produces fixtures is 06-05's checkpoint + phase close-out batch.
- `sort_pub_dependencies` — n/a.
- Fixture format (already established by 06-05's `golden_corpus_test.dart`): three files per directory — `gps_trace.json`, `ways.json.gz`, `expected_ways.json`. Match byte-for-byte.
</invariants>

<tasks>

<task id="1" type="auto">
  <title>Task 1: GoldenFixtureExporter — read+serialize+write</title>
  <files>
    lib/features/trips/data/golden_fixture_exporter.dart
    test/features/trips/golden_fixture_exporter_test.dart
  </files>
  <action>
Service that reads a trip's raw state and writes the 3-file golden fixture format under `<AppDocs>/golden_export/<slug>/`.

```dart
class GoldenFixtureExporter {
  GoldenFixtureExporter({
    required TripsDao tripsDao,
    required OverpassWayCandidateSource waySource,
    required DrivenWayIntervalsDao intervalsDao,
    Directory Function()? appDocsFactory,  // test seam
  });

  /// Exports fixture for tripId with human slug like '002_kleinheubach_roundabout'.
  /// Returns absolute path to the created directory.
  /// Throws DomainError on failure — caller wraps if needed.
  Future<String> export({required int tripId, required String slug});
}
```

Implementation:
1. `points = await tripsDao.listPointsForTrip(tripId)` — serialize as JSON array of `{lat, lon, timestamp}` matching the format read by `golden_corpus_test.dart`. Look at the existing fixture's `gps_trace.json` to match schema exactly.
2. `intervals = await intervalsDao.getByTrip(tripId)` — serialize as `[{"wayId": ..., "startMeters": ..., "endMeters": ...}]` per the test's expected shape (READ `golden_corpus_test.dart` to confirm — do NOT invent).
3. Ways cache: call `waySource.fetchWaysInBbox(trip.bbox)`. The `OverpassWayCacheDao` already stores gzipped payloads — retrieve the raw gzipped bytes and write to `ways.json.gz` verbatim. If retrieving raw bytes isn't straightforward, re-gzip a JSON serialization that matches the parser input.
4. Write `<AppDocs>/golden_export/<slug>/{gps_trace.json, ways.json.gz, expected_ways.json}` atomically (tmp file + rename per file).
5. Return the directory path.

Slug validation: `^\d{3}_[a-z0-9_]+$` (e.g. `002_kleinheubach_roundabout`). Reject invalid slugs with a DomainError.

Tests (`test/features/trips/golden_fixture_exporter_test.dart`) — in-memory Drift, fake `OverpassWayCandidateSource`, temp dir for `appDocsFactory`:
- export creates 3 files with correct names.
- gps_trace.json parses as valid JSON and has 1 entry per point seeded.
- expected_ways.json parses and matches the seeded intervals count.
- ways.json.gz is a valid gzip stream (bytes 1F 8B header).
- Invalid slug → throws `DomainError`.
- Slug collision (dir exists) → overwrites cleanly.
- Round-trip: export a fixture, then run `golden_corpus_test.dart`'s single-fixture logic against it in-test → passes.

**Note on round-trip test:** if reusing the exact test logic is too invasive, at minimum verify the JSON schema by parsing the exported files with the same code that `golden_corpus_test.dart` uses (extract a `_loadFixture` helper if needed).
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/golden_fixture_exporter_test.dart` green.
Regression: `flutter test test/features/matching/golden_corpus_test.dart` still passes (proves we didn't break existing fixture parsing).
  </verify>
  <done>
`GoldenFixtureExporter.export` produces valid 3-file fixtures; ≥6 test cases pass; existing golden corpus test unaffected.
  </done>
</task>

<task id="2" type="auto">
  <title>Task 2: Debug export button on TripDetailScreen (kDebugMode-gated)</title>
  <files>
    lib/features/trips/presentation/widgets/debug_export_button.dart
    lib/features/trips/presentation/trip_detail_screen.dart
  </files>
  <action>
```dart
class DebugExportButton extends ConsumerWidget {
  const DebugExportButton({required this.tripId, super.key});
  final int tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kDebugMode) return const SizedBox.shrink();
    return FloatingActionButton.extended(
      heroTag: 'export_fixture_$tripId',
      onPressed: () => _prompt(context, ref),
      icon: const Icon(Icons.save_alt_outlined),
      label: const Text('Export fixture'),
    );
  }

  Future<void> _prompt(BuildContext context, WidgetRef ref) async {
    final slug = await showDialog<String>(
      context: context,
      builder: (_) => const _SlugPromptDialog(),
    );
    if (slug == null || slug.isEmpty) return;

    final path = await ref.read(goldenFixtureExporterProvider).export(
      tripId: tripId,
      slug: slug,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Exported to $path')),
    );
  }
}
```

`_SlugPromptDialog` is a simple TextField + Cancel/Save AlertDialog with slug-format hint text ("e.g. 002_kleinheubach_roundabout").

**Wire into `trip_detail_screen.dart`**:
- Add `floatingActionButton: DebugExportButton(tripId: tripId)` to the detail screen's Scaffold.
- Import `foundation.dart` for `kDebugMode`.

Provider (co-locate in `debug_export_button.dart` for tree-shaking discipline — kDebugMode also gates the provider so release builds don't retain the exporter tree):
```dart
final goldenFixtureExporterProvider = Provider<GoldenFixtureExporter>((ref) {
  return GoldenFixtureExporter(
    tripsDao: ref.watch(tripsDaoProvider),
    waySource: ref.watch(overpassWayCandidateSourceProvider),
    intervalsDao: ref.watch(drivenWayIntervalsDaoProvider),
  );
});
```

No unit test for the widget (kDebugMode gating makes it awkward in test env — `kDebugMode` is true in `flutter test`, so it renders and can be tested). Add ONE smoke test:
- kDebugMode is true in tests → FAB visible; onPressed opens dialog; entering slug + tap Save calls exporter (verify via provider-override on a fake exporter).
  </action>
  <verify>
`flutter analyze` clean.
`flutter test test/features/trips/trip_detail_screen_test.dart` — existing tests still pass with FAB now present.
  </verify>
  <done>
Debug button visible in kDebugMode on TripDetailScreen, triggers exporter with a user-provided slug.
  </done>
</task>

<task id="3" type="auto">
  <title>Task 3: Golden corpus workflow documentation</title>
  <files>
    test/fixtures/golden_trips/README.md
  </files>
  <action>
Create/update the README documenting the full workflow. Suggested content:

```markdown
# Golden Trip Corpus

Regression fixtures for the HMM matcher. Each subdirectory is one recorded drive.

## Fixture layout

Each `NNN_<region>_<scenario>/` contains:

- `gps_trace.json` — array of `{lat, lon, timestamp}` GPS points from the raw trip
- `ways.json.gz` — gzipped Overpass response for the trip's bbox (candidate ways)
- `expected_ways.json` — array of `{wayId, startMeters, endMeters}` — the intervals the matcher must reproduce

`golden_corpus_test.dart` iterates every subdirectory and asserts the matcher output equals `expected_ways.json`.

## Recording a new fixture (workflow)

1. Run the app in `--debug` or `--profile` (see `.claude/memory/fgb-license-and-release-builds.md` — release builds have degraded tracking).
2. Drive the scenario.
3. Open the Trips tab, Keep or leave the trip in Inbox, tap into it → TripDetailScreen.
4. Tap the **Export fixture** FAB (visible only in `kDebugMode`).
5. Enter a slug of the form `NNN_<region>_<scenario>` — e.g. `002_kleinheubach_roundabout`, `003_gymtrip_a3_northbound`.
6. Files land at `<AppDocs>/golden_export/<slug>/` on the device.
7. Pull the directory to `test/fixtures/golden_trips/` on your dev machine:
   - iOS Simulator: `~/Library/Developer/CoreSimulator/Devices/<id>/data/Containers/Data/Application/<id>/Documents/golden_export/`
   - Android: `adb pull /data/user/0/de.trailblazer/app_flutter/golden_export/`
8. Verify: `flutter test test/features/matching/golden_corpus_test.dart` — new fixture must pass without matcher changes. If it fails, the matcher has genuine regression (or the fixture is bogus — inspect).
9. Commit under `test/fixtures/golden_trips/NNN_<slug>/`.

## Slug conventions

- Zero-padded 3-digit index (`001`, `002`, ...)
- Region: `kleinheubach`, `miltenberg`, `gymtrip`, `aschaffenburg`
- Scenario: `roundabout`, `straight`, `intersection`, `bridge`, `tunnel`, `motorway`, `field_road`, etc.

## Coverage goal (Phase 6)

Target ≥ 20 fixtures by phase close-out. Minimum acceptable at first drive: 3–5 seed fixtures across distinct road types (motorway, town roundabout, rural cross-junction).

## Known limitations

- Fixtures embed the Overpass extract snapshot at record time. If OSM data changes upstream, expected_ways may drift; refresh the fixture (delete + re-record) rather than editing by hand.
- `ways.json.gz` is stored gzipped verbatim from the Overpass cache — hex-diffing before commit is unhelpful.
```

Verify the file lints as clean Markdown (no CI needed — informational file).
  </action>
  <verify>
File exists and reads clearly.
  </verify>
  <done>
README committed documenting the full record→export→pull→commit workflow.
  </done>
</task>

</tasks>

<verification>
Fast-loop: `flutter analyze`.
Loop-tests: `flutter test test/features/trips/golden_fixture_exporter_test.dart`.
Regression sanity: `flutter test test/features/matching/golden_corpus_test.dart` still green.
Pre-push covers the full suite.
</verification>

<success_criteria>
- GoldenFixtureExporter service + widget + README shipped.
- kDebugMode gating verified (compile in release; button absent).
- Existing single golden fixture continues to pass.
- Workflow README covers the full loop end-to-end.
- Fixture accumulation (goal ≥ 20) is a **soft goal** deferred to phase close-out drives — the tooling is the hard deliverable.
- No drive checkpoint in this plan — 06-05's checkpoint + phase close-out batch handle drive-time verification.
</success_criteria>

<output>
Create `.planning/phases/06-inbox-match-wire-up/06-06-SUMMARY.md`.
Capture: exporter API, decision to defer the 20-fixture goal to phase-close-out drive batch, workflow README location.
</output>
