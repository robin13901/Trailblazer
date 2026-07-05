---
id: 04-01
phase: 04-osm-pipeline
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - .planning/REQUIREMENTS.md
  - .planning/STATE.md
  - pubspec.yaml
  - tool/osm_pipeline/README.md
  - tool/osm_pipeline/bin/osm_pipeline.dart
  - tool/osm_pipeline/lib/schema.dart
  - tool/osm_pipeline/lib/cli/args.dart
  - tool/osm_pipeline/lib/cli/logger.dart
  - tool/osm_pipeline/test/cli/args_test.dart
autonomous: true
requirements: [OSM-01]

must_haves:
  truths:
    - "REQUIREMENTS.md OSM-02 no longer lists highway=service; the exclusion is annotated with a decision-log pointer to Phase 4 CONTEXT §Highway filter"
    - "STATE.md carries an explicit decision entry recording the OSM-02 service exclusion (dated 2026-07-05, references 04-CONTEXT and 04-RESEARCH §0.1)"
    - "dart run tool/osm_pipeline --pbf=<path> --bbox=<minlng,minlat,maxlng,maxlat> exits 0 and prints a one-line summary with the parsed arguments"
    - "Missing/invalid --pbf or malformed --bbox exits non-zero with a DomainError-wrapped message"
    - "tool/osm_pipeline/lib/schema.dart exports a const int pipelineSchemaVersion = 1"
    - "tool/osm_pipeline/README.md documents the tippecanoe/WSL2 prerequisite for Windows dev boxes and the pure-Dart-plus-subprocess pipeline shape"
  artifacts:
    - path: "tool/osm_pipeline/bin/osm_pipeline.dart"
      provides: "CLI entrypoint that parses --pbf and --bbox and returns non-zero on validation failure"
    - path: "tool/osm_pipeline/lib/schema.dart"
      provides: "pipelineSchemaVersion constant consumed by every stage that writes a version stamp"
    - path: "tool/osm_pipeline/README.md"
      provides: "Developer-facing prereqs (tippecanoe/WSL2 on Windows), invocation examples, expected timings"
  key_links:
    - from: "REQUIREMENTS.md:OSM-02"
      to: ".planning/STATE.md decision log"
      via: "decision-log pointer sentence"
      pattern: "excluded per Phase 4"
    - from: "tool/osm_pipeline/bin/osm_pipeline.dart"
      to: "tool/osm_pipeline/lib/schema.dart"
      via: "import package:osm_pipeline (or path import) exposing pipelineSchemaVersion"
      pattern: "pipelineSchemaVersion"
---

## Goal

Reconcile the OSM-02 vs CONTEXT `service` divergence in the requirements/decision docs, stand up the `tool/osm_pipeline/` package skeleton, and ship a stub CLI entrypoint that parses `--pbf` and `--bbox` — so every downstream plan can extend a working command rather than build one.

## Context

- Phase 4 CONTEXT.md locks in a 14-tag Kfz allowlist that **excludes** `highway=service`; REQUIREMENTS.md:OSM-02 currently includes it. 04-RESEARCH.md §0.1 flags the divergence and recommends CONTEXT wins.
- Dev box is Windows. Ralph-Loop is tiered: `flutter analyze` in the tight loop; `flutter test` at push boundary via `.githooks/pre-push`. The pipeline lives under `tool/` (outside `lib/`), so Phase 4 tests need `dart test tool/osm_pipeline` — document this in the README.
- Package imports only (`package:auto_explore/...` in the app; the CLI can use path imports internally or become a sub-package — see decision below).
- `sort_pub_dependencies` lint applies to `pubspec.yaml`; any dep added here must be alphabetized.
- The pipeline uses `DomainError` idiomatically for boundary errors (parse failures, missing files) even though it is a CLI — matches Phase 1/2/3 pattern.
- The CLI is a monolithic single command (CONTEXT decision): only `--pbf` and `--bbox` flags in v1.

**Package-vs-in-repo decision (fixed now to unblock downstream):** the pipeline is a **path-imported sub-package** at `tool/osm_pipeline/` with its own `pubspec.yaml` — Dart's canonical shape for a CLI that ships alongside a Flutter app but is not part of the app's runtime. Root `pubspec.yaml` gets a `dev_dependencies` entry pointing at `tool/osm_pipeline` via `path:` so `dart test` and `dart run` from the repo root still work. Every subsequent plan puts its Dart code under `tool/osm_pipeline/lib/`.

## Tasks

<task type="auto">
  <name>Task 1: Reconcile OSM-02 in requirements + log decision in STATE</name>
  <files>
    .planning/REQUIREMENTS.md
    .planning/STATE.md
  </files>
  <intent>Close the OSM-02 vs CONTEXT `service` divergence in docs before any code goes in.</intent>
  <action>
    Edit REQUIREMENTS.md:OSM-02. Rewrite the Kfz tag list to strike `service` and append a decision-log pointer sentence. New text (verbatim structure):

    > **OSM-02**: Pipeline extracts only ways with `highway=motorway|trunk|primary|secondary|tertiary|residential|unclassified|living_street|road|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link` (14-tag Kfz allowlist — `service` excluded per Phase 4 CONTEXT §Highway filter, see decision log 2026-07-05) + `highway=track|path` filtered per Phase 4 RESEARCH §4 (Feldweg/Fußweg, stored `is_counting=0`, non-counting for coverage).

    Also update the traceability row for OSM-02 status if it currently reads "Pending" — leave it Pending (still not implemented) but the description must match the new tag set.

    Append a decision block in STATE.md under the "Phase 4 decisions" (or "Accumulated decisions") section:

    ```
    - 2026-07-05 — OSM-02 `service` exclusion locked. REQUIREMENTS.md updated
      to strike `highway=service` from the Kfz allowlist. Rationale: 04-CONTEXT.md
      Highway filter section + 04-RESEARCH.md §0.1. Service-way sprawl (parking
      lots, driveways, station forecourts) blows the 200 MB budget with minimal
      driven-experience value. `highway=service` re-enters ONLY via the Feldweg
      side-door for `service=driveway|alley` (see 04-RESEARCH §4).
    ```

    Do NOT touch OSM-01/03/04/05/06/07/08 in this task.
  </action>
  <verify>
    grep for `highway=service` in REQUIREMENTS.md OSM-02 returns no hits inside the Kfz enumeration (may still appear in the Feldweg carve-out narrative if you added one — that's fine).
    grep for `2026-07-05 — OSM-02` in STATE.md returns exactly one hit.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Scaffold tool/osm_pipeline/ sub-package + root pubspec wiring</name>
  <files>
    tool/osm_pipeline/pubspec.yaml
    tool/osm_pipeline/analysis_options.yaml
    tool/osm_pipeline/lib/schema.dart
    tool/osm_pipeline/lib/cli/args.dart
    tool/osm_pipeline/lib/cli/logger.dart
    tool/osm_pipeline/bin/osm_pipeline.dart
    pubspec.yaml
    .gitignore
  </files>
  <intent>Stand up the CLI sub-package so plans 04-02..04-10 have a home for their code.</intent>
  <action>
    Create `tool/osm_pipeline/pubspec.yaml` as a plain Dart package (NOT Flutter):
    - name: `osm_pipeline`
    - description: "Trailblazer OSM pipeline — dev-machine CLI that produces osm.sqlite and germany-base.pmtiles."
    - environment.sdk: `^3.5.0` (match root)
    - dependencies (alphabetized — `sort_pub_dependencies` applies):
      - `args: ^2.5.0`
      - `path: ^1.9.0`
    - dev_dependencies (alphabetized):
      - `test: ^1.25.0`
      - `very_good_analysis: ^7.0.0`
    - Do NOT add: sqlite3, protobuf, geometry libs — later plans own their own deps and alphabetized inserts.

    Create `tool/osm_pipeline/analysis_options.yaml` that includes `package:very_good_analysis/analysis_options.yaml` — same lints as the app.

    Create `tool/osm_pipeline/lib/schema.dart`:
    ```dart
    /// Version stamp constants for pipeline outputs.
    ///
    /// Bump [pipelineSchemaVersion] whenever the on-disk schema of osm.sqlite
    /// or the pmtiles layer inventory changes in a way that breaks Phase 5's
    /// integrity check. Phase 5 reads this value from `PRAGMA user_version`.
    const int pipelineSchemaVersion = 1;

    /// Semantic pipeline release marker (informational only).
    const String pipelineName = 'trailblazer-osm-pipeline';
    ```

    Create `tool/osm_pipeline/lib/cli/args.dart` — parses `--pbf` (required, must be an existing file) and `--bbox` (optional, four comma-separated doubles: `minLng,minLat,maxLng,maxLat`). Returns a `ParsedArgs` value class or throws a `DomainError`-shaped exception (define a small local `PipelineError` since we're outside the app package — same shape: sealed class, `message`, `cause?`, `stackTrace?`).

    Create `tool/osm_pipeline/lib/cli/logger.dart` — a bare-bones stderr logger with `info/warn/error` static methods. No dep on `logging` package for v1.

    Create `tool/osm_pipeline/bin/osm_pipeline.dart` — the entrypoint. Wire it up:
    ```dart
    import 'package:osm_pipeline/cli/args.dart';
    import 'package:osm_pipeline/cli/logger.dart';
    import 'package:osm_pipeline/schema.dart';

    Future<int> main(List<String> argv) async {
      try {
        final args = ParsedArgs.parse(argv);
        Logger.info('osm_pipeline v$pipelineSchemaVersion');
        Logger.info('  pbf : ${args.pbfPath}');
        Logger.info('  bbox: ${args.bbox ?? "(none — full extract)"}');
        Logger.info('Stages not implemented yet — plans 04-02..04-10 fill this in.');
        return 0;
      } on PipelineError catch (e, st) {
        Logger.error('${e.message}');
        if (e.cause != null) Logger.error('  cause: ${e.cause}');
        return 2;
      }
    }
    ```

    Root `pubspec.yaml`: add under `dev_dependencies` an alphabetized entry:
    ```yaml
    osm_pipeline:
      path: tool/osm_pipeline
    ```

    Root `.gitignore`: add
    ```
    # Phase 4 pipeline scratch + outputs
    tool/osm_pipeline/.dart_tool/
    tool/osm_pipeline/build/
    tool/osm_pipeline/out/
    tool/osm_pipeline/**/*.osm.pbf
    ```
    (Fixture PBFs committed by 04-02 live under `test/fixtures/` — do NOT gitignore that path pattern; keep the ignore scoped to `*.osm.pbf` extension in top-level pipeline dirs.)
  </action>
  <verify>
    Run `dart pub get` from `tool/osm_pipeline/` — succeeds.
    Run `dart pub get` from repo root — succeeds and resolves `osm_pipeline` via path.
    Run `dart run tool/osm_pipeline/bin/osm_pipeline.dart --pbf=/nonexistent.pbf` — exits with non-zero and a "PBF file not found" style error.
    Run `flutter analyze` from repo root — passes (or emits ONLY warnings scoped to the new pipeline package; zero errors).
  </verify>
</task>

<task type="auto">
  <name>Task 3: CLI args parser unit tests + README</name>
  <files>
    tool/osm_pipeline/test/cli/args_test.dart
    tool/osm_pipeline/README.md
  </files>
  <intent>Prove the args parser rejects malformed input; document how to run the CLI on Windows.</intent>
  <action>
    Write `tool/osm_pipeline/test/cli/args_test.dart` covering:
    - Missing `--pbf` → throws `PipelineError` with a message mentioning "--pbf required".
    - `--pbf=/does/not/exist` → throws `PipelineError` mentioning "not found".
    - `--bbox=1,2,3` (three fields) → throws `PipelineError` mentioning "four comma-separated".
    - `--bbox=200,50,210,55` (out-of-range longitude) → throws `PipelineError` mentioning "longitude".
    - Valid `--pbf` (use a tempfile) + valid `--bbox=13.0,52.3,13.8,52.7` (Berlin) → returns a `ParsedArgs` with `bbox.minLng == 13.0`.
    - Valid `--pbf` and NO `--bbox` → returns `ParsedArgs` with `bbox == null`.

    Run tests via `dart test` from `tool/osm_pipeline/`.

    Create `tool/osm_pipeline/README.md`:

    ```markdown
    # Trailblazer OSM Pipeline

    Dev-machine Dart CLI that turns a Geofabrik `germany-latest.osm.pbf` into two
    slim runtime artifacts:
    - `osm.sqlite` — Kfz + Feldweg way geometries, R-Tree, way_admin join, version stamp
    - `germany-base.pmtiles` — offline vector base map (roads, admin_boundaries, water, labels)

    ## Prerequisites

    - Dart SDK ≥ 3.5 (already installed for the app)
    - **tippecanoe** — required for pmtiles authoring (Stage D). See below for install.
    - ~30 GB free disk (scratch DB for full Germany run)
    - ~4 GB free RAM

    ### Installing tippecanoe

    | Platform | Install |
    |----------|---------|
    | macOS    | `brew install tippecanoe` |
    | Linux    | Distro package or build from source (github.com/felt/tippecanoe) |
    | **Windows (this dev box)** | Install under WSL2. The pipeline shells out to `wsl tippecanoe ...`. See `tippecanoe/README.md` (created by plan 04-09) for detailed steps. |

    ## Running

    Berlin smoke (fast dev iteration, ~60 s):
    ```bash
    dart run tool/osm_pipeline \
      --pbf=/path/to/berlin-latest.osm.pbf \
      --bbox=13.0,52.3,13.8,52.7
    ```

    Full Germany (~30–90 min):
    ```bash
    dart run tool/osm_pipeline --pbf=/path/to/germany-latest.osm.pbf
    ```

    ## Pipeline shape

    ```
    Stage A: PBF stream parse + filter          (pure Dart, plan 04-02/04-03/04-04)
    Stage B: segmented intersection + way_admin (pure Dart, plan 04-05)
    Stage C: osm.sqlite write + R-Tree build    (pure Dart, plan 04-06)
    Stage D: GeoJSONSeq emit + tippecanoe       (subprocess, plan 04-07)
    Stage E: pmtiles metadata + style rewrite   (pure Dart, plan 04-08)
    ```

    ## Testing

    The pipeline lives under `tool/` and is not part of the Flutter app package.
    Run its unit tests directly:

    ```bash
    cd tool/osm_pipeline
    dart test
    ```

    The repo's pre-push hook runs `flutter test` for the app package.
    Pipeline tests are run manually today; a CI job may pick them up later.

    ## Skipped-log

    Stages A–D write malformed geometries, orphan tags, and self-intersecting
    multipolygons to `<out-dir>/skipped.log` and continue. See 04-RESEARCH.md §12
    for the enumerated pitfalls.
    ```

    Save and commit.
  </action>
  <verify>
    `cd tool/osm_pipeline && dart test` — all args tests pass.
    `tool/osm_pipeline/README.md` exists and contains the string "wsl tippecanoe".
  </verify>
</task>

## Verification

- `flutter analyze` clean at repo root (or only pipeline-scoped warnings — zero errors).
- `cd tool/osm_pipeline && dart pub get && dart test` — green.
- `dart run tool/osm_pipeline --pbf=/nonexistent` exits with code 2.
- `dart run tool/osm_pipeline --pbf=<real file> --bbox=13.0,52.3,13.8,52.7` exits 0 and prints the parsed arguments.
- `grep 'highway=service' .planning/REQUIREMENTS.md | grep OSM-02` — no match.
- STATE.md contains the 2026-07-05 OSM-02 decision block.

## Deviation Handling

- If `very_good_analysis` produces lints that conflict with `args`/`path` package idioms, prefer `// ignore_for_file: <specific_rule>` at the top of the offending file over disabling the lint globally.
- If `dart pub get` from repo root refuses to resolve the path-imported sub-package (Flutter tooling can be strict about `path:` dev_deps in Flutter apps), move the sub-package registration under `dependency_overrides` — same effect, no Flutter-tooling friction.
- If any task fails, iterate up to 3 times, then stop and report the failure with the exact analyzer/test output.
