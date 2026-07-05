---
phase: 04-osm-pipeline
plan: 01
subsystem: infra
tags: [dart-cli, osm, pipeline, sub-package, args-parser, requirements-reconciliation]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: CONTEXT.md Highway filter decision (14-tag Kfz allowlist, service excluded)
  - phase: 04-osm-pipeline
    provides: RESEARCH.md §0.1 OSM-02 vs CONTEXT reconciliation flag
provides:
  - "OSM-02 service exclusion reconciled in REQUIREMENTS.md + STATE.md decision log"
  - "tool/osm_pipeline path-imported Dart sub-package skeleton"
  - "pipelineSchemaVersion = 1 canonical version stamp constant"
  - "PipelineError sealed hierarchy (pipeline-side DomainError shape)"
  - "ParsedArgs.parse validating --pbf + --bbox with 9 unit tests"
  - "CLI stub exits 0 on success and 2 on PipelineError"
  - "README documenting WSL2 tippecanoe prereq + dart-test-in-subpackage workflow"
affects: [04-02, 04-03, 04-04, 04-05, 04-06, 04-07, 04-08, 04-09, 04-10, 05-osm-db, 10-settings]

# Tech tracking
tech-stack:
  added:
    - "args ^2.5.0 (CLI parsing in tool/osm_pipeline)"
    - "test ^1.25.0 (pipeline unit tests, sub-package dev_dep)"
    - "very_good_analysis ^7.0.0 (pipeline lints, matches app-side ruleset family)"
  patterns:
    - "Path-imported Dart sub-package under tool/ with own pubspec + analysis_options"
    - "PipelineError sealed hierarchy mirrors app-side DomainError (message + cause + stackTrace)"
    - "Testable run() extracted from main() so unit tests can invoke without calling exit()"
    - "pipelineSchemaVersion = const int in lib/schema.dart — bump-triggers-redownload contract"

key-files:
  created:
    - "tool/osm_pipeline/pubspec.yaml"
    - "tool/osm_pipeline/analysis_options.yaml"
    - "tool/osm_pipeline/README.md"
    - "tool/osm_pipeline/bin/osm_pipeline.dart"
    - "tool/osm_pipeline/lib/schema.dart"
    - "tool/osm_pipeline/lib/cli/args.dart"
    - "tool/osm_pipeline/lib/cli/errors.dart"
    - "tool/osm_pipeline/lib/cli/logger.dart"
    - "tool/osm_pipeline/test/cli/args_test.dart"
  modified:
    - ".planning/REQUIREMENTS.md (OSM-02 rewrite)"
    - ".planning/STATE.md (Plan 04-01 decision block)"
    - "pubspec.yaml (osm_pipeline dev_dep via path)"
    - ".gitignore (pipeline scratch + *.osm.pbf)"

key-decisions:
  - "OSM-02 service exclusion locked — CONTEXT wins, requirements match code"
  - "tool/osm_pipeline is a path-imported sub-package (not in lib/, not a Flutter package)"
  - "PipelineError is a local sealed hierarchy (mirrors DomainError shape, no cross-package import)"
  - "pipelineSchemaVersion = 1 as const int in lib/schema.dart (Phase 5 reads via PRAGMA user_version)"
  - "Pipeline tests run via `dart test` inside sub-package, not via `flutter test` at repo root"
  - "Windows tippecanoe = WSL2 (documented in README; Stage D subprocess in later plans)"

patterns-established:
  - "Path-imported sub-package: root pubspec dev_dep osm_pipeline: {path: tool/osm_pipeline}; own analysis_options; own pubspec.lock committed"
  - "Testable CLI entrypoint: split main() (calls exit) from run() (returns int) so tests can drive run() directly"
  - "Pipeline-side error shape: sealed PipelineError + PipelineArgsError + PipelineIoError; boundary discipline matches app-side DomainError.wrap"

# Metrics
duration: 11min
completed: 2026-07-05
---

# Phase 4 Plan 01: Reconciliation + CLI Scaffold Summary

**OSM-02 `service` exclusion reconciled in docs; `tool/osm_pipeline/` sub-package scaffolded with `pipelineSchemaVersion = 1`, a validating `--pbf/--bbox` args parser, `PipelineError` boundary shape, and 9 passing unit tests — every Phase 4 downstream plan now has a working CLI to extend.**

## Performance

- **Duration:** ~11 min
- **Started:** 2026-07-05T16:45:43Z
- **Completed:** 2026-07-05T16:56:53Z
- **Tasks:** 3
- **Files created:** 9 (7 source + README + args_test)
- **Files modified:** 4 (REQUIREMENTS.md, STATE.md, pubspec.yaml, .gitignore)
- **Tests added:** 9 (all green)

## Accomplishments

- Closed the OSM-02 vs CONTEXT `service` divergence flagged by 04-RESEARCH §0.1. REQUIREMENTS.md now lists the 14-tag Kfz allowlist verbatim, points at the decision log via "excluded per Phase 4 CONTEXT §Highway filter", and STATE.md carries a dated decision entry.
- Stood up `tool/osm_pipeline/` as a self-contained Dart sub-package (own pubspec, own analysis_options with `very_good_analysis`, own pubspec.lock committed). Root pubspec registers it under `dev_dependencies` via `path: tool/osm_pipeline` so `dart run tool/osm_pipeline` and `flutter pub get` both work from the repo root.
- Shipped `pipelineSchemaVersion = 1` as a `const int` in `lib/schema.dart` — the canonical version stamp that Phase 5 will read from `PRAGMA user_version` and Phase 10 from pmtiles metadata.
- Defined `PipelineError` as a sealed hierarchy (`PipelineArgsError`, `PipelineIoError`) mirroring the app-side `DomainError` shape. Cannot import `DomainError` directly (pipeline is outside `lib/`), so we ported the pattern.
- Wired `ParsedArgs.parse` to validate `--pbf` (must exist on disk) and `--bbox` (four comma-separated doubles inside [-180,180] × [-90,90], min < max on both axes). CLI stub in `bin/osm_pipeline.dart` prints a one-line summary and exits 0 on success, 2 on `PipelineError`.
- Wrote 9 unit tests covering the parser's happy path and every rejection path (missing --pbf, nonexistent file, arity, out-of-range longitude, non-numeric fields, inverted min/max on lat and lng). All green.
- `flutter analyze` clean at repo root; `dart analyze` clean inside `tool/osm_pipeline/`. No pre-push hook regressions expected.

## Task Commits

Each task committed atomically, no `git add -A`:

1. **Task 1: Reconcile OSM-02 + log decision** — `054dae9` (docs)
   - REQUIREMENTS.md OSM-02 rewrite
   - STATE.md decision block (dated 2026-07-05, references 04-CONTEXT + 04-RESEARCH §0.1)
2. **Task 2: Scaffold sub-package + CLI stub** — `a8ae6e6` (feat)
   - tool/osm_pipeline/{pubspec.yaml, analysis_options.yaml, pubspec.lock}
   - lib/schema.dart, lib/cli/{args.dart, errors.dart, logger.dart}
   - bin/osm_pipeline.dart
   - Root pubspec.yaml + pubspec.lock, .gitignore
3. **Task 3: Args parser tests + README** — `40085c3` (test)
   - test/cli/args_test.dart (9 tests)
   - README.md

**Plan metadata commit:** to be created after this summary lands.

## Files Created/Modified

**Created:**
- `tool/osm_pipeline/pubspec.yaml` — plain Dart package manifest, name `osm_pipeline`, alphabetized deps (args, path) + dev_deps (test, very_good_analysis)
- `tool/osm_pipeline/analysis_options.yaml` — includes `package:very_good_analysis/analysis_options.yaml`
- `tool/osm_pipeline/README.md` — WSL2 tippecanoe prereq, invocation examples, stage map, dart-test workflow, skipped-log convention
- `tool/osm_pipeline/bin/osm_pipeline.dart` — CLI entrypoint: `main` calls `exit(await run(argv))`; `run` wraps `PipelineError` catches
- `tool/osm_pipeline/lib/schema.dart` — `pipelineSchemaVersion = 1`, `pipelineName = 'trailblazer-osm-pipeline'`
- `tool/osm_pipeline/lib/cli/errors.dart` — `sealed PipelineError` + `PipelineArgsError`, `PipelineIoError`; file-level `no_runtimetype_tostring` ignore mirroring app-side DomainError pattern
- `tool/osm_pipeline/lib/cli/args.dart` — `ParsedArgs.parse` + `BoundingBox.parse`, validates arity + lat/lng range + min<max
- `tool/osm_pipeline/lib/cli/logger.dart` — abstract-final stderr logger with `info/warn/error` static methods
- `tool/osm_pipeline/test/cli/args_test.dart` — 9 args tests (using tempfile PBF fixtures)

**Modified:**
- `.planning/REQUIREMENTS.md` — OSM-02 rewrite: 14-tag Kfz allowlist, decision-log pointer, Feldweg carve-out reference to RESEARCH §4
- `.planning/STATE.md` — 6 new decision entries under Plan 04-01 (service exclusion; sub-package shape; pipelineSchemaVersion=1; PipelineError; WSL2 prereq; dart-test-in-subpackage)
- `pubspec.yaml` — added `osm_pipeline: {path: tool/osm_pipeline}` under dev_dependencies (alphabetized between mocktail and remove_from_coverage)
- `pubspec.lock` — regenerated by `flutter pub get`
- `.gitignore` — pipeline scratch dirs (`tool/osm_pipeline/{.dart_tool,build,out}`) + `tool/osm_pipeline/**/*.osm.pbf`

## Decisions Made

See STATE.md "Plan 04-01" decision block (6 entries) for the full rationale. Key highlights:

- **OSM-02 `service` exclusion locked** — CONTEXT wins over REQUIREMENTS' original wording. Service-way sprawl (parking lots, driveways) blows the 200 MB budget; drivable-experience value is marginal. `service=driveway|alley` re-enters via the Feldweg side-door (04-RESEARCH §4), not the Kfz allowlist.
- **Sub-package shape** — path-imported plain Dart package at `tool/osm_pipeline/`. Own `pubspec.yaml`, own `analysis_options.yaml`, own `pubspec.lock` committed. Root `pubspec.yaml` gains `osm_pipeline` under `dev_dependencies` via `path:` (Flutter tooling accepted it without needing `dependency_overrides`).
- **`PipelineError` is local, not shared** — the pipeline lives outside `lib/`, so it cannot import `package:auto_explore/core/errors/domain_error.dart`. Local sealed hierarchy mirrors the same shape. Boundary discipline (`wrap on entry, unwrap at CLI edge with exit code 2`) is preserved.
- **`pipelineSchemaVersion = 1` in code from day one** — Phase 5 reads it via `PRAGMA user_version`; Phase 10 reads it from pmtiles metadata. Bumping this constant triggers Phase 5's "you need to redownload" flow.
- **Windows tippecanoe = WSL2** — no first-party Windows binary. README documents the install path; Stage D (plan 04-07) shells out via `wsl tippecanoe ...`.
- **Pipeline tests run via `dart test` inside `tool/osm_pipeline/`** — not `flutter test`. Pre-push hook still covers the app-side test suite. Pipeline CI is a follow-up.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] CLI exit code was 0 even on `PipelineError`**

- **Found during:** Task 2 (smoke-test the CLI stub after wiring)
- **Issue:** `Future<int> main(argv)` in Dart does not use the returned int as the process exit code — Dart CLI programs must call `exit(code)` explicitly. First smoke run returned exit=0 despite printing "PBF file not found".
- **Fix:** Split `main` into two functions: `main` (calls `exit(await run(argv))`) and `run` (returns `Future<int>`). Bonus: `run` is now unit-test-friendly — a future plan can invoke it directly without process-exit side effects.
- **Files modified:** `tool/osm_pipeline/bin/osm_pipeline.dart`
- **Verification:** Re-ran with `--pbf=nonexistent.pbf` → exit=2. Re-ran with a valid tempfile PBF + Berlin bbox → exit=0 + parsed-args summary printed.
- **Committed in:** `a8ae6e6` (Task 2 commit, inside the same task boundary)

**2. [Rule 2 - Missing Critical] Analyzer info-level lints on new pipeline files (public_member_api_docs, prefer_constructors_over_static_methods, no_runtimetype_tostring, dangling_library_doc_comments, document_ignores)**

- **Found during:** Task 2 (running `dart analyze` in the sub-package and `flutter analyze` at repo root)
- **Issue:** Sub-package uses `very_good_analysis` which enforces `public_member_api_docs`, `prefer_constructors_over_static_methods`, and `document_ignores`. Root repo tolerates info-level warnings, but the pre-push hook runs `flutter analyze --fatal-infos`, so info-level issues would block push. First pass produced 17 analyzer notices.
- **Fix:**
  - Added doc comments to all public members of `ParsedArgs`, `BoundingBox`, `PipelineError`, `PipelineArgsError`, `PipelineIoError`, `Logger`.
  - Reordered `parse` static methods above field declarations so their doc comments are contiguous with their signature.
  - Suppressed `prefer_constructors_over_static_methods` at each `parse` call site with an inline `// ignore:` — the static-method shape is deliberate (validates + throws before construction).
  - File-level `ignore_for_file: no_runtimetype_tostring` in `errors.dart` (matches app-side `DomainError` convention captured in STATE.md 01-04), with a documenting comment immediately above to satisfy `document_ignores`.
- **Files modified:** `tool/osm_pipeline/lib/cli/args.dart`, `tool/osm_pipeline/lib/cli/errors.dart`, `tool/osm_pipeline/lib/cli/logger.dart`
- **Verification:** `dart analyze` in `tool/osm_pipeline/` → "No issues found!"; `flutter analyze` at repo root → "No issues found!".
- **Committed in:** `a8ae6e6` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 bug, 1 missing critical / lint hygiene)
**Impact on plan:** Both essential. The exit-code bug would have silently broken every downstream verification. The lint cleanup keeps the pre-push hook green and preserves the tiered Ralph-Loop invariant. No scope creep.

## Issues Encountered

- **Git-Bash path munging on Windows** — `dart run ... --pbf=/nonexistent.pbf` gets rewritten to `C:/Program Files/Git/nonexistent.pbf` by MSYS path translation. Not a code bug; just a Git-Bash artifact. Test file avoids the issue by using `Directory.systemTemp.createTempSync` + `path` join; command-line invocations use relative paths or `--pbf=nonexistent.pbf` (no leading slash).

## User Setup Required

None — no external service configuration required. The tippecanoe/WSL2 install is documented in `tool/osm_pipeline/README.md` and is only exercised by Stage D (plan 04-07); no runtime dependency for this plan.

## Next Phase Readiness

**Ready:**
- CLI skeleton in place — plans 04-02..04-10 extend `ParsedArgs`, wire additional stages into `run(argv)`, and drop code under `tool/osm_pipeline/lib/`.
- `pipelineSchemaVersion` is available as a Dart constant from day one — every stage that writes a version stamp reads it here.
- OSM-02 doc consistency: REQUIREMENTS.md, CONTEXT.md, RESEARCH.md, STATE.md all agree on the 14-tag Kfz allowlist.
- Test harness proven via 9 args tests — future stage tests use the same sub-package `dart test` entrypoint.

**Blockers / concerns:**
- None new. WSL2 tippecanoe install is a known Windows prereq surfaced in the README; the actual install can wait until plan 04-07 (Stage D) starts.
- Phase 3 in-car verification remains deferred (unchanged).

---
*Phase: 04-osm-pipeline*
*Completed: 2026-07-05*
