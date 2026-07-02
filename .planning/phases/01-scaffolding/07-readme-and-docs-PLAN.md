---
plan: "07"
name: "readme-and-docs"
wave: 3
depends_on: ["01", "06"]
files_modified:
  - "README.md"
  - "docs/ARCHITECTURE.md"
autonomous: true
requirements: ["FND-06"]
must_haves:
  truths:
    - "Root `README.md` describes the project in one paragraph, lists the tech stack, shows CI + Codecov badges, and links to further docs."
    - "Badges render on GitHub (badge URLs use the correct owner/repo path)."
    - "`docs/ARCHITECTURE.md` documents the feature-first layout and locked Phase 1 decisions in one place."
  artifacts:
    - path: "README.md"
      provides: "Human-readable project entry point with badges + build/test/dev instructions"
      contains: "![CI]"
    - path: "docs/ARCHITECTURE.md"
      provides: "Architecture summary: layers, folders, key decisions"
  key_links:
    - from: "README.md"
      to: ".github/workflows/ci.yml"
      via: "CI badge references the workflow file"
      pattern: "workflows/ci\\.yml/badge\\.svg"
    - from: "README.md"
      to: "codecov.io"
      via: "Codecov badge references the repo"
      pattern: "codecov\\.io/gh"
---

<objective>
Write the project's `README.md` (with badges + quickstart) and `docs/ARCHITECTURE.md` (with layer overview + Phase 1 locked decisions). Delivers FND-06 and gives future contributors — or future-me — a landing page.
</objective>

<context>
- Open Question 1 from RESEARCH.md (lines 1108-1110): CONTEXT.md did not explicitly call out README but FND-06 requires it — this plan closes that gap.
- **GitHub repo path:** `I551358/Auto-Explore-App` (branch: `master`; note main workflows target `main` but the actual current branch may be `master` — badge URLs must use whatever the default branch is; use `master` for now, update after any rename).
- **Repository owner:** confirm at execution time by running `git remote get-url origin` and parsing the path segment.
- **Codecov badge format:** `https://codecov.io/gh/<owner>/<repo>/branch/<branch>/graph/badge.svg?token=<PUBLIC_UPLOAD_TOKEN>` — the graph badge does not require the private token (Codecov emits a separate badge-URL token in the repo settings). For a private-until-shipped project, using the default badge URL is fine — Codecov displays "unknown" until first upload.
- **Tech stack summary source:** PROJECT.md lines 122-138 (Key Decisions) + REQUIREMENTS.md Quality Bar.
</context>

<tasks>

<task id="7.1" type="auto">
  <name>Write README.md with badges + quickstart</name>
  <files>
    - `README.md`
  </files>
  <action>

    First, determine repo owner/name at execution time:

    ```bash
    git remote get-url origin
    # Expected: git@github.com:I551358/Auto-Explore-App.git  OR  https://github.com/I551358/Auto-Explore-App.git
    ```

    Determine the default branch:

    ```bash
    git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' \
      || git rev-parse --abbrev-ref HEAD
    ```

    If the remote is not I551358/Auto-Explore-App, substitute the real owner/repo below. Same for the branch name (`master` vs `main`).

    **Create `README.md`** using the template below, substituting `<OWNER>`, `<REPO>`, `<BRANCH>`:

    ```markdown
    # Auto-Explore

    [![CI](https://github.com/<OWNER>/<REPO>/actions/workflows/ci.yml/badge.svg?branch=<BRANCH>)](https://github.com/<OWNER>/<REPO>/actions/workflows/ci.yml)
    [![Builds](https://github.com/<OWNER>/<REPO>/actions/workflows/ios-build.yml/badge.svg?branch=<BRANCH>)](https://github.com/<OWNER>/<REPO>/actions/workflows/ios-build.yml)
    [![codecov](https://codecov.io/gh/<OWNER>/<REPO>/branch/<BRANCH>/graph/badge.svg)](https://codecov.io/gh/<OWNER>/<REPO>)
    [![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
    [![Dart](https://img.shields.io/badge/Dart-3.10-0175C2?logo=dart&logoColor=white)](https://dart.dev)
    [![Lints: very_good_analysis](https://img.shields.io/badge/lints-very__good__analysis-8B00FF)](https://pub.dev/packages/very_good_analysis)

    > **When I open the map, I immediately see the roads I've already driven, painted onto the world — and that view keeps pulling me back to explore more.**

    Auto-Explore (working title: *Trailblazer*) is a private Flutter app for iOS + Android that tracks which roads you have driven in which vehicle. Every trip is map-matched against OpenStreetMap **on-device** — no server, no ongoing cost — and driven road segments are permanently painted onto a Google-Maps-style base map. Coverage aggregates into a five-level admin hierarchy (Land → Bundesland → Landkreis → Gemeinde → Ortsteil) with a live focus-area pill that changes as you zoom.

    ## Status

    Phase 1 (Scaffolding) — CI, App DB, routing, permissions, error/logging. See [`.planning/ROADMAP.md`](./.planning/ROADMAP.md) for the 11-phase plan.

    ## Tech Stack

    | Layer | Choice |
    |-------|--------|
    | UI + platform | Flutter 3.44 / Dart 3.10 (iOS + Android only) |
    | State management | Riverpod 3.x (`flutter_riverpod`, `riverpod_annotation`) |
    | Routing | `go_router` 17.x |
    | Local DB | Drift 2.34 (`drift_flutter`) — SQLite with WAL + foreign keys |
    | Base map | MapLibre GL + PMTiles vector tiles (offline; Phase 2) |
    | Map matching | Custom HMM (Newson-Krumm 2009), on-device, isolate-based (Phase 5) |
    | GPS | `flutter_background_geolocation` (Phase 3) |
    | Lints | `very_good_analysis` 10.x |
    | Tests | `flutter_test` + `mocktail` + `SchemaVerifier` |
    | CI | GitHub Actions + Codecov |

    ## Quickstart

    ```bash
    # Get dependencies
    flutter pub get

    # Run codegen (Drift + Riverpod parts)
    dart run build_runner build --delete-conflicting-outputs

    # Regenerate Drift migration helpers (gitignored, produced from drift_schemas/)
    dart run drift_dev schema generate drift_schemas/ test/generated_migrations/

    # Lint + format
    flutter analyze --fatal-infos
    dart format --set-exit-if-changed .

    # Test with coverage
    flutter test --coverage

    # Run on a device
    flutter run
    ```

    ## Build

    ```bash
    # Android debug APK
    flutter build apk --debug

    # iOS (unsigned — same as CI)
    flutter build ios --release --no-codesign
    ```

    ## Architecture

    See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the feature-first layout and layer conventions.

    ## Documentation

    - [PROJECT.md](./.planning/PROJECT.md) — vision, decisions, constraints
    - [REQUIREMENTS.md](./.planning/REQUIREMENTS.md) — 119 v1 requirements
    - [ROADMAP.md](./.planning/ROADMAP.md) — 11-phase roadmap
    - [ARCHITECTURE.md](./docs/ARCHITECTURE.md) — layer + folder conventions
    - [.planning/research/](./.planning/research/) — domain research (OSM, HMM, MapLibre, etc.)

    ## License

    Private — not licensed for redistribution at this time.
    ```

    After writing, verify by opening the file and confirming all `<OWNER>`, `<REPO>`, `<BRANCH>` placeholders are replaced.
  </action>
  <verify>
    ```bash
    test -f README.md
    ! grep -q "<OWNER>\|<REPO>\|<BRANCH>" README.md    # placeholders must be substituted
    grep -q "very_good_analysis" README.md
    grep -q "codecov.io/gh" README.md
    grep -q "workflows/ci.yml/badge.svg" README.md
    ```
  </verify>
  <done>README.md exists, has no template placeholders, contains all four required badges + tech stack + quickstart.</done>
</task>

<task id="7.2" type="auto">
  <name>Write docs/ARCHITECTURE.md</name>
  <files>
    - `docs/ARCHITECTURE.md`
  </files>
  <action>

    **Create `docs/ARCHITECTURE.md`:**

    ```markdown
    # Architecture

    Auto-Explore is a single-user Flutter app. All persistence is local; there is no server. This document captures the high-level layer conventions and the locked decisions from Phase 1 (Scaffolding) so future phases don't accidentally regress them.

    ## Layers

    Feature-first, three-layer per feature:

    ```
    lib/
    ├── main.dart                # ProviderScope + error hooks
    ├── app.dart                 # MaterialApp.router
    │
    ├── core/                    # Cross-cutting infra
    │   ├── db/                  # Drift App DB + tables
    │   │   ├── app_database.dart
    │   │   └── tables/*.dart
    │   ├── logging/             # AppLogger (logging package)
    │   ├── errors/              # sealed DomainError hierarchy + Result<T>
    │   └── routing/             # go_router config
    │
    └── features/                # One folder per feature
        ├── map/
        │   ├── data/            # repositories, DAOs, remote clients
        │   ├── domain/          # use cases, pure types
        │   └── presentation/    # widgets, notifiers, screens
        ├── trips/
        ├── vehicles/
        ├── regions/
        ├── settings/
        └── onboarding/
    ```

    Rules:

    1. `presentation/` depends on `domain/`, never directly on `data/` (except via a provider that exposes a repository).
    2. `domain/` is pure Dart — no Flutter imports, no plugin imports. Testable without any binding.
    3. `data/` implements repositories against Drift / plugins / HTTP.
    4. Cross-feature dependencies go through `core/` or through public repository/use-case types exported from a feature.

    ## Locked decisions (Phase 1)

    - **State management:** Riverpod 3.x with `@riverpod` codegen. No singletons, no `.instance` shortcuts.
    - **Routing:** `go_router` inside a `@riverpod` provider (Pitfall 6 in [01-RESEARCH.md](../.planning/phases/01-scaffolding/01-RESEARCH.md)).
    - **App DB:** Drift 2.34 with `drift_flutter` (NOT `sqlite3_flutter_libs` — EOL). Foreign keys ON, WAL mode ON. Full v1 schema defined in Phase 1; DAOs added per-phase.
    - **Migration tests:** `SchemaVerifier` against `drift_schemas/drift_schema_vN.json` for every schema version.
    - **Logging:** `logging` package, plain-text sink. Debug = verbose, release = warnings + errors only. No remote crash reporter — diagnostics screen (Phase 10) surfaces logs locally.
    - **Errors:** sealed `DomainError` hierarchy. Repositories wrap driver exceptions via `DomainError.wrap(...)`. Use cases return `Result<T>` when failure is expected.
    - **Onboarding:** shown once, gated by `SharedPreferencesAsync` flag `onboarding_done`. SplashScreen reads flag and redirects to `/onboarding` or `/`.
    - **CI:** GitHub Actions on push to `main` only (solo dev). `dart format --set-exit-if-changed`, `flutter analyze --fatal-infos`, `flutter test --coverage`, generated files stripped via `remove_from_coverage`, uploaded to Codecov (no hard gate). iOS unsigned + Android debug builds in parallel.
    - **Permissions:** manifest entries declared in Phase 1; runtime prompts driven by Phase 3+ code (permission_handler is not yet a dependency).

    ## Anti-patterns to fix vs XFin reference

    | XFin pattern | Auto-Explore replacement | Reason |
    |--------------|--------------------------|--------|
    | `provider` + singleton `.instance` | Riverpod 3.x providers | Testability, no static coupling |
    | Flat `screens/` folder | `features/{feature}/{data,domain,presentation}` | Scales to 6+ features |
    | Empty `analysis_options.yaml` | `very_good_analysis` include | Catch bugs at lint time |
    | `sqlite3_flutter_libs` direct | `drift_flutter` | Former is EOL |

    ## Next phases

    See [`.planning/ROADMAP.md`](../.planning/ROADMAP.md). Phase 2 replaces the placeholder home with a MapLibre map + Liquid Glass chrome; Phase 3 wires background GPS.
    ```
  </action>
  <verify>
    ```bash
    test -f docs/ARCHITECTURE.md
    grep -q "feature-first" docs/ARCHITECTURE.md || grep -q "features/" docs/ARCHITECTURE.md
    grep -q "DomainError" docs/ARCHITECTURE.md
    grep -q "SchemaVerifier" docs/ARCHITECTURE.md
    ```
  </verify>
  <done>File exists, describes layers, and captures Phase 1 locked decisions.</done>
</task>

</tasks>

<verification>
```bash
test -f README.md docs/ARCHITECTURE.md
! grep -R "<OWNER>\|<REPO>\|<BRANCH>" README.md
```
After pushing to `main`, badges should render on the GitHub repo page.
</verification>

<must_haves>
Delivers FND-06 (README with project description, architecture summary, build/test/CI badges). Part of the Phase 1 quality bar — no direct Success Criterion, but required for FND-06 completeness in traceability.
</must_haves>
