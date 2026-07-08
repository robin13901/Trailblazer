---
id: 05-08
phase: 05-overpass-matcher-and-golden-corpus
plan: 08
type: execute
wave: 4
depends_on: [05-05]
files_modified:
  - test/fixtures/golden_trips/README.md
  - test/features/matching/golden_corpus_test.dart
  - tool/osm_pipeline/bin/save_trip_fixture.dart
  - tool/check_matcher_coverage.dart
  - .github/workflows/ci.yml
  - .planning/STATE.md
autonomous: true
requirements: [MMT-09, QUA-02]

# NOTE (2026-07-08 overnight-execution adjustment):
# Autonomous flipped false → true. Real-drive fixtures (originally Task 4
# checkpoint:human-action) moved to a documented post-phase follow-up so the
# entire phase can run end-to-end without halting. Task 4 is now an auto
# task that records the deferral in STATE.md and README.md. The 4 real drives
# stay in scope for Phase 5 SC3 but are executed after overnight completion,
# batched with any other pending device checkpoints — matches the existing
# "defer in-car verification" pattern used at the end of Phase 3.

must_haves:
  truths:
    - "`test/fixtures/golden_trips/README.md` documents the fixture layout: each trip is a directory containing `gps_trace.json`, `ways.json.gz`, `expected_ways.json`, `metadata.json`."
    - "`test/features/matching/golden_corpus_test.dart` iterates over every subdirectory of `test/fixtures/golden_trips/`, loads the fixture, runs `HmmMatcher.match()`, and asserts the produced interval-wayId sequence equals `expected_ways.json`."
    - "The corpus test suite is CI-runnable: `flutter test test/features/matching/golden_corpus_test.dart` passes on a clean checkout when there are 0 fixtures (skipped) and passes when there are ≥ 1 fixtures with correct expected sequences (failing = CI failure)."
    - "`tool/osm_pipeline/bin/save_trip_fixture.dart` is a CLI that, given a GPS trace JSON path and a live network, calls `OverpassWayCandidateSource.fetchWaysInBbox` for the trace's bbox and writes `ways.json.gz` next to the trace."
    - "`tool/check_matcher_coverage.dart` reads `coverage/lcov.info` (post-`remove_from_coverage`), computes line coverage for `lib/features/matching/domain/**` + `lib/core/db/daos/driven_way_intervals_dao.dart`, prints the percentage, and exits 1 when < 90% (QUA-02)."
    - "`.github/workflows/ci.yml` runs the coverage-gate script AFTER the existing `Strip generated files from coverage` step and BEFORE the Codecov upload."
    - "The corpus test includes at least 1 seed fixture (a synthetic hand-authored trip). The additional 4 real-drive fixtures required by roadmap SC3 (≥ 5 at Phase 5 close-out) are captured as a follow-up drive-batch documented in `test/fixtures/golden_trips/README.md` and `.planning/STATE.md` — same pattern as Phase 3 in-car verification deferral (see `.planning/phases/03-tracking-mvp/` close-out)."
  artifacts:
    - path: "test/fixtures/golden_trips/README.md"
      provides: "Fixture-layout spec + workflow for recording new trips."
      min_lines: 60
    - path: "test/fixtures/golden_trips/001_synthetic_straight_east/"
      provides: "First seed fixture: synthetic straight-east 5-fix trip; hand-authored ways + trace + expected."
      min_lines: 0
    - path: "test/features/matching/golden_corpus_test.dart"
      provides: "Corpus-runner test: discovers fixtures, runs matcher, asserts way-ID sequence equality."
      min_lines: 100
    - path: "tool/osm_pipeline/bin/save_trip_fixture.dart"
      provides: "Fixture-generator CLI: `dart run osm_pipeline:save_trip_fixture --trace <path>`."
      min_lines: 80
    - path: "tool/check_matcher_coverage.dart"
      provides: "lcov parser + 90% gate script; runnable via `dart run tool/check_matcher_coverage.dart`."
      min_lines: 80
  key_links:
    - from: "test/features/matching/golden_corpus_test.dart"
      to: "test/helpers/fixture_way_candidate_source.dart"
      via: "FixtureWayCandidateSource.fromGzippedOverpassJson(fixture_dir/ways.json.gz)"
      pattern: "FixtureWayCandidateSource\\.fromGzippedOverpassJson"
    - from: ".github/workflows/ci.yml"
      to: "tool/check_matcher_coverage.dart"
      via: "new step 'Enforce matcher coverage ≥ 90%' calls the Dart script; step exits 1 on failure"
      pattern: "check_matcher_coverage|Enforce matcher coverage"
    - from: "tool/osm_pipeline/bin/save_trip_fixture.dart"
      to: "lib/features/matching/data/overpass_way_candidate_source.dart"
      via: "invokes OverpassWayCandidateSource with a real HTTP client to produce the gzipped fixture"
      pattern: "OverpassWayCandidateSource|fetchWaysInBbox"
---

## Goal

Ship the golden-corpus scaffolding + first seed fixture + CI coverage gate. The scaffolding is what MMT-09 + QUA-02 verify against; the seed proves the harness works. Real-drive fixtures accumulate over subsequent PRs (research §5 + §11.5).

Resolves research §11 open questions:
- **#5 Corpus seeding strategy:** 1 synthetic seed at plan-close (proves the harness); 4 real-drive fixtures deferred to a follow-up drive-batch (documented in README + STATE.md by Task 4) to bring the corpus to the 5 seeds Phase 5 SC3 requires at close-out. Overnight-execution mode: this plan runs end-to-end and produces the deferral record; the actual drives happen out-of-band and land as a follow-up PR.
- **#9 CI failure mode:** the golden-corpus test IS a required CI step; algorithm tuning must include fixture updates. If a legitimate tuning breaks a fixture, the fix is to update `expected_ways.json` in the same PR after eyeballing the new sequence.
- **#10 build_runner ordering:** existing CI already runs build_runner before analyze/test — confirmed in `.github/workflows/ci.yml`.

Autonomous = true (2026-07-08 overnight-execution adjustment). The user-action drive-batch is captured as an auto Task 4 that writes the deferral into STATE.md + README.md — the physical drives happen after overnight completion, batched with any other pending device checkpoints.

## Context

- Research §5 has the fixture format + coverage-gate approach.
- Existing test helper: `test/helpers/fixture_way_candidate_source.dart` (`FixtureWayCandidateSource.fromGzippedOverpassJson`) is what the corpus test consumes.
- Existing CI: `.github/workflows/ci.yml` runs `flutter test --coverage`, then `remove_from_coverage` to strip generated files. Insert the coverage-gate step AFTER `remove_from_coverage` and BEFORE `codecov`.
- The coverage-gate script is Dart, not shell — matches project convention (osm_pipeline is Dart, all tools are Dart).
- The `save_trip_fixture` CLI lives under the existing `tool/osm_pipeline/bin/` directory. `tool/osm_pipeline` is a path-imported dev-only sub-package (per Phase 4 rescope 2026-07-08); the CI must NOT ship it — no change to that.
- Seed fixture format:
  ```
  test/fixtures/golden_trips/001_synthetic_straight_east/
    gps_trace.json       -- array of {lat, lon, accuracy, speedKmh, ts}
    ways.json.gz         -- gzipped Overpass response JSON (for FixtureWayCandidateSource)
    expected_ways.json   -- [{"wayId": 1, "direction": "forward"}, ...]
    metadata.json        -- {scenario, notes, recorded_at}
  ```
- Coverage-gate scope (files to include in the 90% assertion):
  ```
  lib/features/matching/domain/hmm_probability.dart
  lib/features/matching/domain/segment_geometry.dart
  lib/features/matching/domain/way_segment.dart
  lib/features/matching/domain/way_segment_index.dart
  lib/features/matching/domain/viterbi_decoder.dart
  lib/features/matching/domain/hmm_matcher.dart
  lib/features/matching/domain/match_result.dart
  lib/features/matching/domain/matched_step.dart
  lib/features/matching/domain/gps_fix.dart
  lib/features/matching/domain/driven_way_interval_draft.dart
  lib/core/db/daos/driven_way_intervals_dao.dart
  ```
  (Isolate + coordinator files are integration-tested but not gated at 90% — they include hard-to-cover error branches like isolate spawn failure.)

## Tasks

<task type="auto">
  <name>Task 1: Fixture layout README + first synthetic seed + corpus-runner test</name>
  <files>
    test/fixtures/golden_trips/README.md
    test/fixtures/golden_trips/001_synthetic_straight_east/gps_trace.json
    test/fixtures/golden_trips/001_synthetic_straight_east/ways.json.gz
    test/fixtures/golden_trips/001_synthetic_straight_east/expected_ways.json
    test/fixtures/golden_trips/001_synthetic_straight_east/metadata.json
    test/features/matching/golden_corpus_test.dart
  </files>
  <intent>Fixture format + seed + harness that will grow with the corpus.</intent>
  <action>
    **`test/fixtures/golden_trips/README.md`:** Full spec.
    Content:
    ```markdown
    # Golden Trip Corpus (Phase 5 MMT-09)

    Each subdirectory here is one recorded trip with a known-correct way-ID
    sequence. The `golden_corpus_test.dart` runner iterates over every
    subdirectory and asserts `HmmMatcher.match()` produces the expected
    sequence.

    ## Layout

        {NNN}_{scenario_slug}/
          gps_trace.json       -- input GPS trace, plain JSON array
          ways.json.gz         -- gzipped Overpass response JSON
          expected_ways.json   -- expected interval way-ID sequence
          metadata.json        -- scenario, notes, recorded_at

    ## Adding a new fixture

    1. Drive the scenario, recording via the app.
    2. Export the trip's `trip_points` as `gps_trace.json` (via debug HUD or
       Drift dump).
    3. Run `dart run osm_pipeline:save_trip_fixture --trace path/to/gps_trace.json`
       (requires internet — hits Overpass). Writes `ways.json.gz`.
    4. Run the matcher manually against the fixture, inspect the intervals,
       write `expected_ways.json` after visual verification.
    5. Commit all four files.

    ## Required scenarios (MMT-09 — ≥ 20 total)

    | # | Slug template | Scenario |
    |---|---------------|----------|
    | 1–3 | `NNN_autobahn_*` | Autobahn forward |
    | 4–5 | `NNN_bundesstrasse_*` | Bundesstraße mixed class |
    | 6–7 | `NNN_kreisel_*_entry` | Kreisverkehr entry/exit |
    | 8–9 | `NNN_kreisel_*_loop` | Full-loop roundabout |
    | 10–11 | `NNN_tunnel_*` | Tunnel GPS blackout |
    | 12–13 | `NNN_parking_*` | Parking lot approach |
    | 14–15 | `NNN_uturn_*` | U-turn on narrow street |
    | 16–17 | `NNN_citygrid_*` | Dense city grid |
    | 18–19 | `NNN_roundabout_*` | Roundabout with straight exit |
    | 20 | `NNN_einbahn_*` | One-way pair |
    ```

    **`test/fixtures/golden_trips/001_synthetic_straight_east/`:** hand-author the four files.
    - `gps_trace.json`: 5 fixes east-bound along one way (e.g., lat 49.7 constant, lon 9.0 → 9.001 in 5 steps; accuracy 5.0; speedKmh 60; ts 1s apart).
    - `ways.json.gz`: a hand-crafted minimal Overpass response containing 1 way with 3 nodes matching the trace. Author as `ways.json` first, then `gzip < ways.json > ways.json.gz`. Use way-id `1` for simplicity. Include `tags: {"highway": "residential"}`.
    - `expected_ways.json`: `[{"wayId": 1, "direction": "forward"}]`.
    - `metadata.json`: `{"scenario": "synthetic_straight_east", "notes": "Seed fixture; verifies harness works with a trivial trace.", "recorded_at": "2026-07-08"}`.

    Producing the gzipped JSON: from a Dart script or `printf ... | gzip - > ways.json.gz`. Verify with `gunzip -t ways.json.gz`.

    **`test/features/matching/golden_corpus_test.dart`:**
    ```dart
    // Phase 5 (Plan 05-08): Golden corpus regression test.
    //
    // Iterates over every subdirectory in test/fixtures/golden_trips/ and
    // asserts HmmMatcher.match(loaded_trace, loaded_ways) produces the
    // interval-wayId sequence in expected_ways.json.
    //
    // The test SKIPS an empty corpus (no directories) — this keeps the test
    // green on a fresh checkout, but ANY committed fixture MUST pass.

    import 'dart:convert';
    import 'dart:io';

    import 'package:auto_explore/features/matching/domain/gps_fix.dart';
    import 'package:auto_explore/features/matching/domain/hmm_matcher.dart';
    import 'package:flutter_test/flutter_test.dart';
    import 'package:auto_explore/features/matching/data/way_candidate_source.dart';
    import 'test/helpers/fixture_way_candidate_source.dart' as helper;

    void main() {
      final corporaDir = Directory('test/fixtures/golden_trips');
      if (!corporaDir.existsSync()) {
        test('golden corpus: directory missing (skipped)', () {}, skip: true);
        return;
      }

      final tripDirs = corporaDir
          .listSync()
          .whereType<Directory>()
          .where((d) => File('${d.path}/gps_trace.json').existsSync())
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      if (tripDirs.isEmpty) {
        test('golden corpus: no fixtures (skipped)', () {}, skip: true);
        return;
      }

      for (final tripDir in tripDirs) {
        final slug = tripDir.path.split(RegExp(r'[\\/]')).last;
        test('golden trip: $slug', () async {
          final trace = _loadGpsTrace(tripDir);
          final source = await helper.FixtureWayCandidateSource
              .fromGzippedOverpassJson('${tripDir.path}/ways.json.gz');
          final bbox = _bboxOfTrace(trace);
          final ways = await source.fetchWaysInBbox(
            minLat: bbox.minLat,
            minLon: bbox.minLon,
            maxLat: bbox.maxLat,
            maxLon: bbox.maxLon,
          );

          final result = const HmmMatcher().match(fixes: trace, ways: ways);

          final expected = _loadExpectedWays(tripDir);
          final actualIds = result.intervals.map((i) => i.wayId).toList();
          final expectedIds = expected.map((e) => e['wayId'] as int).toList();
          expect(
            actualIds,
            equals(expectedIds),
            reason: 'golden trip $slug — wayId sequence mismatch\n'
                'expected: $expectedIds\nactual:   $actualIds',
          );
        });
      }
    }

    List<GpsFix> _loadGpsTrace(Directory dir) {
      final raw = File('${dir.path}/gps_trace.json').readAsStringSync();
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map((m) => GpsFix(
        lat: (m['lat'] as num).toDouble(),
        lon: (m['lon'] as num).toDouble(),
        accuracyMeters: (m['accuracy'] as num?)?.toDouble() ?? double.nan,
        speedKmh: (m['speedKmh'] as num?)?.toDouble() ?? 0.0,
        ts: DateTime.parse(m['ts'] as String),
      )).toList();
    }

    List<Map<String, dynamic>> _loadExpectedWays(Directory dir) {
      final raw = File('${dir.path}/expected_ways.json').readAsStringSync();
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    }

    ({double minLat, double minLon, double maxLat, double maxLon}) _bboxOfTrace(
      List<GpsFix> fixes,
    ) {
      var minLat = 90.0, minLon = 180.0, maxLat = -90.0, maxLon = -180.0;
      for (final f in fixes) {
        if (f.lat < minLat) minLat = f.lat;
        if (f.lat > maxLat) maxLat = f.lat;
        if (f.lon < minLon) minLon = f.lon;
        if (f.lon > maxLon) maxLon = f.lon;
      }
      return (minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon);
    }
    ```

    (Adjust the `import 'test/helpers/...'` path to be `package:`-imported per project rule — use relative `../helpers/fixture_way_candidate_source.dart` from `test/features/matching/`, and remove the `as helper` alias if it fights `always_use_package_imports` — since `test/` is not under `package:auto_explore/...`, a relative import from within `test/` is acceptable. Match whatever the existing tests in `test/features/matching/` do.)
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/golden_corpus_test.dart
    ```
    Analyze clean; the seed fixture 001 test PASSES; harness handles the 1-fixture corpus.
  </verify>
  <done>1 fixture seeded; harness passes; adding a broken `expected_ways.json` visibly fails the test.</done>
</task>

<task type="auto">
  <name>Task 2: save_trip_fixture CLI + check_matcher_coverage script</name>
  <files>
    tool/osm_pipeline/bin/save_trip_fixture.dart
    tool/check_matcher_coverage.dart
  </files>
  <intent>Fixture generator + CI coverage-gate enforcer.</intent>
  <action>
    **`tool/osm_pipeline/bin/save_trip_fixture.dart`:**
    ```dart
    // Phase 5 (Plan 05-08): CLI that reads a GPS trace JSON, computes its
    // bbox, calls the live Overpass API for the ways in that bbox, and
    // writes ways.json.gz next to the trace.
    //
    // Usage:
    //   dart run osm_pipeline:save_trip_fixture --trace path/to/gps_trace.json
    //
    // Requires an internet connection (hits the primary Overpass endpoint).

    import 'dart:convert';
    import 'dart:io';

    Future<void> main(List<String> argv) async {
      final traceArg = argv.indexOf('--trace');
      if (traceArg == -1 || traceArg + 1 >= argv.length) {
        stderr.writeln('Usage: save_trip_fixture --trace <path>');
        exit(2);
      }
      final tracePath = argv[traceArg + 1];
      final traceFile = File(tracePath);
      if (!traceFile.existsSync()) {
        stderr.writeln('Trace file not found: $tracePath');
        exit(2);
      }
      final list = (jsonDecode(traceFile.readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      var minLat = 90.0, minLon = 180.0, maxLat = -90.0, maxLon = -180.0;
      for (final m in list) {
        final lat = (m['lat'] as num).toDouble();
        final lon = (m['lon'] as num).toDouble();
        if (lat < minLat) minLat = lat;
        if (lat > maxLat) maxLat = lat;
        if (lon < minLon) minLon = lon;
        if (lon > maxLon) maxLon = lon;
      }
      // Small padding to catch ways along the boundary.
      const pad = 0.001;
      minLat -= pad; maxLat += pad; minLon -= pad; maxLon += pad;

      final query = '[out:json][timeout:60];'
          '(way[highway](${minLat},${minLon},${maxLat},${maxLon}););'
          'out body geom;';
      const endpoint = 'https://overpass-api.de/api/interpreter';
      stderr.writeln('Fetching Overpass for bbox '
          '($minLat, $minLon, $maxLat, $maxLon) ...');
      final httpClient = HttpClient();
      final req = await httpClient.postUrl(Uri.parse(endpoint));
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      req.write('data=${Uri.encodeComponent(query)}');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        stderr.writeln('Overpass returned ${resp.statusCode}');
        exit(1);
      }
      final body = await resp.transform(utf8.decoder).join();

      final outPath = tracePath.replaceAll(RegExp(r'gps_trace\.json$'), 'ways.json.gz');
      final gz = gzip.encode(utf8.encode(body));
      File(outPath).writeAsBytesSync(gz);
      stderr.writeln('Wrote $outPath (${gz.length} bytes)');
      httpClient.close();
    }
    ```
    Add an entry to `tool/osm_pipeline/pubspec.yaml`'s `executables:` (if that pattern is used in this project — check other bin/*.dart entries for reference). If not, users invoke as `dart run tool/osm_pipeline/bin/save_trip_fixture.dart`.

    **`tool/check_matcher_coverage.dart`:**
    ```dart
    // Phase 5 (Plan 05-08): Coverage-gate script for QUA-02.
    //
    // Reads coverage/lcov.info (post-`remove_from_coverage`), computes line
    // coverage for the matcher module, prints the percentage, exits 1 when
    // < 90%.

    import 'dart:io';

    const List<String> kIncludePatterns = [
      'lib/features/matching/domain/',
      'lib/core/db/daos/driven_way_intervals_dao.dart',
    ];
    const double kMinCoveragePct = 90.0;

    Future<void> main() async {
      final lcov = File('coverage/lcov.info');
      if (!lcov.existsSync()) {
        stderr.writeln('coverage/lcov.info not found — run flutter test --coverage first');
        exit(2);
      }
      final lines = lcov.readAsLinesSync();
      var currentFile = '';
      var include = false;
      var totalLF = 0;
      var totalLH = 0;
      var fileLF = 0;
      var fileLH = 0;

      for (final l in lines) {
        if (l.startsWith('SF:')) {
          currentFile = l.substring(3);
          include = kIncludePatterns.any(currentFile.contains);
          fileLF = 0;
          fileLH = 0;
          continue;
        }
        if (!include) continue;
        if (l.startsWith('LF:')) {
          fileLF = int.parse(l.substring(3));
        } else if (l.startsWith('LH:')) {
          fileLH = int.parse(l.substring(3));
        } else if (l == 'end_of_record') {
          if (fileLF > 0) {
            stdout.writeln('  $currentFile: $fileLH/$fileLF');
          }
          totalLF += fileLF;
          totalLH += fileLH;
        }
      }
      if (totalLF == 0) {
        stderr.writeln('No matcher files found in coverage output');
        exit(2);
      }
      final pct = totalLH * 100.0 / totalLF;
      stdout.writeln('Matcher coverage: ${pct.toStringAsFixed(1)}% ($totalLH/$totalLF lines)');
      if (pct < kMinCoveragePct) {
        stderr.writeln('FAIL: coverage ${pct.toStringAsFixed(1)}% < required ${kMinCoveragePct}%');
        exit(1);
      }
      stdout.writeln('PASS: coverage >= ${kMinCoveragePct}%');
    }
    ```

    Run manually to check:
    ```bash
    flutter test --coverage
    dart pub run remove_from_coverage -f coverage/lcov.info -r '\.g\.dart$' -r '\.freezed\.dart$' -r '\.drift\.dart$' -r 'test/generated_migrations'
    dart run tool/check_matcher_coverage.dart
    ```
    Expected: prints the percentage; passes if ≥ 90 %.
  </action>
  <verify>
    ```bash
    dart run tool/osm_pipeline/bin/save_trip_fixture.dart 2>&1 | head -5
    dart run tool/check_matcher_coverage.dart 2>&1 | tail -5
    ```
    First: shows usage message on no args (exit 2). Second: prints coverage percentage.
  </verify>
  <done>Both tools runnable from the CLI; check_matcher_coverage exits 0 when coverage ≥ 90%.</done>
</task>

<task type="auto">
  <name>Task 3: CI coverage-gate step wiring</name>
  <files>
    .github/workflows/ci.yml
  </files>
  <intent>Insert the coverage-gate step in the existing workflow.</intent>
  <action>
    Read the current `ci.yml` (already loaded during planning — steps: checkout → flutter → pub get → build_runner → drift schema → format → analyze → test --coverage → remove_from_coverage → codecov).

    Insert a new step BETWEEN `Strip generated files from coverage` and `Upload coverage to Codecov`:
    ```yaml
          - name: Enforce matcher coverage >= 90% (QUA-02)
            run: dart run tool/check_matcher_coverage.dart
    ```

    That's the only edit. No other CI changes.

    Grep-verify:
    ```bash
    grep -c "check_matcher_coverage" .github/workflows/ci.yml
    ```
    Returns 1.
  </action>
  <verify>
    ```bash
    grep -A1 "Enforce matcher coverage" .github/workflows/ci.yml
    ```
    Prints the new step. `flutter analyze` still clean (yaml is not analyzed but no breakage).
  </verify>
  <done>CI step inserted; step will fail the CI job if coverage < 90%.</done>
</task>

<task type="auto">
  <name>Task 4: Record deferred-drive-batch follow-up in README + STATE.md</name>
  <files>
    test/fixtures/golden_trips/README.md
    .planning/STATE.md
  </files>
  <intent>
    Overnight-execution mode: the 4 real-drive fixtures required by roadmap
    SC3 (≥ 5 seeds at Phase 5 close-out) cannot be recorded during unattended
    execution. Capture them as a documented follow-up drive-batch — same
    pattern the project used for Phase 3 in-car verification and Phase 4
    combined close-out drive.
  </intent>
  <action>
    **1) Append to `test/fixtures/golden_trips/README.md`:**

    Add a new section at the END of the file (below any existing content
    Task 1 wrote):

    ```markdown

    ## Phase 5 close-out follow-up drives (deferred)

    Phase 5 SC3 requires ≥ 5 seed fixtures at close-out. Task 1 shipped
    fixture `001_synthetic_straight_east/` (synthetic). The remaining 4
    real-drive fixtures are deferred to an out-of-band drive-batch so
    Phase 5 could run end-to-end unattended (overnight execution).

    Scenarios to record (one fixture each — bring corpus to 5 total):

    | Slug | Scenario | Estimated drive |
    |------|----------|-----------------|
    | `002_autobahn_forward` | Autobahn forward, ≥ 5 min at ≥ 100 km/h | A3 or A45 nearest ramp |
    | `003_kreisel_entry_exit` | Kreisverkehr entry + full-loop + exit | Any nearby Kreisel; loop twice |
    | `004_city_grid` | Dense city grid (≥ 20 turns) | Aschaffenburg / Frankfurt centre |
    | `005_bundesstrasse_mixed` | Bundesstraße with mixed class transitions | B26 or B469 |

    For each fixture, follow the "Adding a new fixture" workflow above.
    Once all 4 land, Phase 5 SC3 (≥ 5 seeds) is satisfied. Corpus growth
    to ≥ 20 continues in Phase 6+ per roadmap.
    ```

    **2) Append a follow-up entry to `.planning/STATE.md`:**

    Locate the "## Follow-ups / Deferred" section (or the "## Current
    Position" block if no dedicated deferred-work section exists), and add
    a bullet:

    ```markdown
    - **Phase 5 golden-corpus real-drive batch (deferred 2026-07-08):**
      4 real-drive fixtures needed to bring corpus from 1 synthetic seed
      to 5 seeds (Phase 5 SC3). Scenarios + workflow documented in
      `test/fixtures/golden_trips/README.md` "Phase 5 close-out follow-up
      drives" section. Batch alongside pending Phase 4 combined close-out
      drive. Does NOT block Phase 6 planning (Phase 6 inherits corpus
      expansion to ≥ 20 per roadmap SC3 amendment 2026-07-08).
    ```

    If STATE.md has no such section, add it near the top under "## Current
    Position" as a new `### Deferred / Follow-ups` heading.

    **3) Grep-verify:**
    ```bash
    grep -c "Phase 5 close-out follow-up drives" test/fixtures/golden_trips/README.md
    grep -c "Phase 5 golden-corpus real-drive batch" .planning/STATE.md
    ```
    Both return 1.
  </action>
  <verify>
    ```bash
    grep -A2 "Phase 5 close-out follow-up drives" test/fixtures/golden_trips/README.md
    grep -A2 "Phase 5 golden-corpus real-drive batch" .planning/STATE.md
    ```
    Both print the appended sections. `flutter analyze` still clean
    (markdown files aren't analyzed).
  </verify>
  <done>Deferral documented in both README.md and STATE.md; Phase 5 close-out is code-complete with 1 seed shipped and 4 real drives queued for the next drive-batch.</done>
</task>

## Success Criteria

- `flutter analyze` clean.
- `flutter test test/features/matching/golden_corpus_test.dart` passes on the 1 synthetic seed fixture (post-Task 1).
- `dart run tool/check_matcher_coverage.dart` prints a percentage and exits 0 when the matcher domain files have ≥ 90 % coverage.
- CI workflow contains the `Enforce matcher coverage` step.
- 1 fixture directory (`001_synthetic_straight_east/`) exists under `test/fixtures/golden_trips/` at plan close (Task 1); the 4 real-drive follow-ups are documented as a deferred drive-batch in README + STATE.md (Task 4).

## Ralph Loop

- Tight loop: `flutter analyze` (Tasks 1–4).
- Behavior-sensitive: `flutter test test/features/matching/golden_corpus_test.dart` after Task 1.
- Task 4 is markdown-only (no Dart change) — analyze is sufficient.

## Deviations

- If the seed fixture (001) fails the harness on first run, DO NOT modify `expected_ways.json` to match the output — first check the fixture data (gzipped JSON contents, node order, way tags). The seed is designed to be trivial (single east-bound way) so any failure indicates a real regression in 05-05.
- If `remove_from_coverage` in CI accidentally strips the matcher domain files, the coverage script will exit 2 ("No matcher files found") — that must not silently pass CI. The script correctly exits 2 (fail) in that case; the CI step will fail.
- If the corpus test performance is problematic (e.g. each fixture takes > 30 s due to large way lists), add per-fixture timeouts and log elapsed time. Do NOT parallelize (Flutter tests are single-VM).

## Commit Strategy

- Task 1 commit: `feat(05-08): golden corpus scaffolding + first synthetic seed`
- Task 2 commit: `feat(05-08): save_trip_fixture CLI + check_matcher_coverage script`
- Task 3 commit: `ci(05-08): enforce matcher coverage >= 90% on CI`
- Task 4 commit: `docs(05-08): defer 4 real-drive fixtures to follow-up drive-batch`
- Phase close-out commit (after Task 4): `docs(05-08): Phase 5 code-complete — 1 synthetic seed + 4 drives deferred`
