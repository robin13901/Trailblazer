---
plan: "06"
name: "github-actions-ci"
wave: 3
depends_on: ["01", "02", "03", "04", "05"]
files_modified:
  - ".github/workflows/ci.yml"
  - ".github/workflows/ios-build.yml"
  - "codecov.yml"
autonomous: false
requirements: ["FND-03", "FND-04", "FND-05", "QUA-05"]
must_haves:
  truths:
    - "CI workflow on push to main runs `dart format --set-exit-if-changed .` and `flutter analyze --fatal-infos` — both must exit 0."
    - "CI runs `flutter test --coverage`, strips `.g.dart`/`.freezed.dart`/`.drift.dart`/`generated_migrations` from `lcov.info`, and uploads to Codecov."
    - "iOS unsigned build (`flutter build ios --release --no-codesign`) exits 0 on macos-latest."
    - "Android debug build (`flutter build apk --debug`) exits 0 on ubuntu-latest."
    - "Codecov upload succeeds once `CODECOV_TOKEN` is added to the repository secrets by the user."
  artifacts:
    - path: ".github/workflows/ci.yml"
      provides: "lint + test + coverage + Codecov upload"
      contains: "codecov/codecov-action@v5"
    - path: ".github/workflows/ios-build.yml"
      provides: "iOS unsigned build (macos-latest) + Android debug build (ubuntu-latest) as parallel jobs"
      contains: "flutter build ios --release --no-codesign"
    - path: "codecov.yml"
      provides: "Codecov project config: no hard gate, ignore generated files"
  key_links:
    - from: ".github/workflows/ci.yml"
      to: "coverage/lcov.info"
      via: "remove_from_coverage strips generated files pre-upload"
      pattern: "remove_from_coverage"
    - from: ".github/workflows/ci.yml"
      to: "test/generated_migrations/"
      via: "Regenerates migration helpers before running tests"
      pattern: "drift_dev schema generate"
---

<objective>
Wire GitHub Actions CI: a `ci.yml` workflow (lint + test + coverage + Codecov) and a `ios-build.yml` workflow (iOS unsigned + Android debug builds in parallel). Both trigger on push to `main` only. The plan is NOT autonomous because it requires a human action step at the end — adding `CODECOV_TOKEN` to the GitHub repo secrets.
</objective>

<context>
- **CONTEXT.md decisions:** trigger on `push: main` only; failure mode = full run (no fail-fast); iOS + Android builds parallel; Codecov upload but no hard gate; strip generated files before upload.
- **`ci.yml` snippet:** RESEARCH.md lines 272-317.
- **`ios-build.yml` snippet:** RESEARCH.md lines 321-352.
- **CI gotchas:** RESEARCH.md lines 361-366 (channel:stable, macos-latest for iOS, secrets, dart format flag).
- **Pitfall 5:** RESEARCH.md lines 938-943 — `--no-codesign` is mandatory on unsigned CI runners.
- **Pitfall 8:** RESEARCH.md lines 960-964 — trigger `push: main` only.
- **Open question 4:** RESEARCH.md lines 1114-1115 — Codecov token is a one-time human action step.
- **Drift generated_migrations note:** Plan 02 established that `test/generated_migrations/` is `.gitignore`d and CI must regenerate it before `flutter test`. Do this in `ci.yml`.
</context>

<tasks>

<task id="6.1" type="auto">
  <name>Write ci.yml + codecov.yml</name>
  <files>
    - `.github/workflows/ci.yml`
    - `codecov.yml`
  </files>
  <action>

    **`.github/workflows/ci.yml`:**

    ```yaml
    name: CI

    on:
      push:
        branches: [main]
      workflow_dispatch:

    jobs:
      lint-and-test:
        name: Lint + Test + Coverage
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4

          - uses: subosito/flutter-action@v2
            with:
              channel: stable
              cache: true

          - name: Install dependencies
            run: flutter pub get

          - name: Verify formatting
            run: dart format --set-exit-if-changed .

          - name: Analyze
            run: flutter analyze --fatal-infos

          # Codegen (drift + riverpod parts) — must exist before tests import them.
          - name: Run build_runner
            run: dart run build_runner build --delete-conflicting-outputs

          # Regenerate migration helpers (gitignored per Plan 02).
          - name: Generate Drift migration helpers
            run: |
              mkdir -p test/generated_migrations
              dart run drift_dev schema generate drift_schemas/ test/generated_migrations/

          - name: Run tests with coverage
            run: flutter test --coverage

          - name: Strip generated files from coverage
            run: |
              dart pub run remove_from_coverage \
                -f coverage/lcov.info \
                -r '\.g\.dart$' \
                -r '\.freezed\.dart$' \
                -r '\.drift\.dart$' \
                -r 'test/generated_migrations'

          - name: Upload coverage to Codecov
            uses: codecov/codecov-action@v5
            with:
              files: ./coverage/lcov.info
              token: ${{ secrets.CODECOV_TOKEN }}
              fail_ci_if_error: false
    ```

    **`codecov.yml`:**

    ```yaml
    # Codecov project config — no hard gate per CONTEXT.md decision.
    coverage:
      status:
        project:
          default:
            target: auto
            threshold: 100%   # Effectively disables the project gate.
        patch:
          default:
            target: auto
            threshold: 100%

    ignore:
      - "**/*.g.dart"
      - "**/*.freezed.dart"
      - "**/*.drift.dart"
      - "test/generated_migrations/**"
      - "lib/**/*.g.dart"
    ```
  </action>
  <verify>
    ```bash
    # Local YAML sanity check:
    python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); yaml.safe_load(open('codecov.yml'))"
    # Or, if python missing:
    dart pub global activate yaml_action_validator 2>/dev/null || true
    ```

    Actual CI verification happens on the first push to main after this plan lands (see 6.3 checkpoint).
  </verify>
  <done>Both files exist and are valid YAML.</done>
</task>

<task id="6.2" type="auto">
  <name>Write ios-build.yml with iOS + Android jobs in parallel</name>
  <files>
    - `.github/workflows/ios-build.yml`
  </files>
  <action>

    **`.github/workflows/ios-build.yml`:**

    ```yaml
    name: Builds

    on:
      push:
        branches: [main]
      workflow_dispatch:

    jobs:
      ios-build:
        name: iOS (unsigned)
        runs-on: macos-latest
        steps:
          - uses: actions/checkout@v4
          - uses: subosito/flutter-action@v2
            with:
              channel: stable
              cache: true
          - run: flutter pub get
          - name: Codegen (build_runner)
            run: dart run build_runner build --delete-conflicting-outputs
          - name: Build iOS (release, unsigned)
            run: flutter build ios --release --no-codesign

      android-build:
        name: Android (debug APK)
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - uses: subosito/flutter-action@v2
            with:
              channel: stable
              cache: true
          - run: flutter pub get
          - name: Codegen (build_runner)
            run: dart run build_runner build --delete-conflicting-outputs
          - name: Build Android debug APK
            run: flutter build apk --debug
    ```

    Notes:
    - iOS build must be macos-latest (Xcode requirement). Ubuntu cannot build iOS.
    - Both jobs regenerate `.g.dart` before building — the codegen artifacts are gitignored (Plan 01) but referenced from source files. Without this step, the build fails on missing `part 'foo.g.dart'` files.
    - `flutter build ios` produces an `.app` at `build/ios/iphoneos/Runner.app` (not a `.ipa`, but that's fine — success criterion is "builds green", not artifact upload). If a `.ipa` is truly required later, add `flutter build ipa --no-codesign` as a follow-up.
  </action>
  <verify>
    ```bash
    python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ios-build.yml'))"
    ```
    Real verification comes with 6.3.
  </verify>
  <done>File exists and is valid YAML with two jobs.</done>
</task>

<task id="6.3" type="checkpoint:human-action" gate="blocking">
  <what-built>
    CI workflows are in place, but the Codecov upload step in `ci.yml` will fail (`fail_ci_if_error: false` so it won't red-X the build, but coverage will not be tracked) until `CODECOV_TOKEN` is registered as a GitHub Actions secret.
  </what-built>
  <how-to-verify>
    ONE-TIME human action — no CLI substitute available for creating a Codecov account and copying the token.

    1. Go to https://about.codecov.io and sign in with the GitHub account that owns this repo.
    2. Add this repository from the Codecov dashboard (Codecov will show a "Not yet setup" entry for `Auto-Explore-App`).
    3. Copy the "Repository Upload Token" shown in the Codecov settings for this repo.
    4. In GitHub → this repo → Settings → Secrets and variables → Actions → New repository secret:
        - Name: `CODECOV_TOKEN`
        - Value: (paste the token from step 3)
    5. Push a trivial commit to `main` (e.g., add a newline to `README.md` — will exist after Plan 07).
    6. Watch the Actions tab:
        - `CI / Lint + Test + Coverage` job → green.
        - `Builds / iOS (unsigned)` → green.
        - `Builds / Android (debug APK)` → green.
        - Codecov badge appears on the repo home page after Plan 07's README lands.

    If the Codecov step logs "no token" but the rest is green, that's still acceptable — the run does not fail — but coverage tracking will not work until the token is added.
  </how-to-verify>
  <resume-signal>Type "codecov-token added and CI green" or describe any failing job.</resume-signal>
</task>

</tasks>

<verification>
Local (before push):
```bash
python -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); yaml.safe_load(open('.github/workflows/ios-build.yml')); yaml.safe_load(open('codecov.yml'))"
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
flutter analyze --fatal-infos
dart format --set-exit-if-changed .
flutter test --coverage
```

Remote (after push):
- All three CI jobs green.
- Codecov dashboard shows initial coverage report.
</verification>

<must_haves>
Delivers FND-03, FND-04, FND-05, QUA-05. Directly satisfies phase Success Criteria 1 (analyze + format in CI), 2 (test with coverage upload), and 3 (iOS unsigned + Android debug builds green in CI).
</must_haves>
