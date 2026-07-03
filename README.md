<h1 align="center">
  <img src="assets/icons/app_icon.jpg" alt="Trailblazer app icon" width="128" height="128" style="border-radius:24px" /><br />
  Trailblazer
</h1>

<p align="center">
  <a href="https://github.com/robin13901/Trailblazer/actions/workflows/ci.yml"><img src="https://github.com/robin13901/Trailblazer/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI" /></a>
  <a href="https://github.com/robin13901/Trailblazer/actions/workflows/ios-build.yml"><img src="https://github.com/robin13901/Trailblazer/actions/workflows/ios-build.yml/badge.svg?branch=main" alt="iOS Build" /></a>
  <a href="https://app.codecov.io/github/robin13901/trailblazer"><img src="https://codecov.io/gh/robin13901/Trailblazer/branch/main/graph/badge.svg" alt="codecov" /></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter&logoColor=white" alt="Flutter" /></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3.10%2B-0175C2?logo=dart&logoColor=white" alt="Dart" /></a>
  <a href="https://pub.dev/packages/very_good_analysis"><img src="https://img.shields.io/badge/lints-very__good__analysis-8B00FF" alt="Lints: very_good_analysis" /></a>
</p>

> **When I open the map, I immediately see the roads I've already driven, painted onto the world — and that view keeps pulling me back to explore more.**

Trailblazer is a private Flutter app for iOS + Android that tracks which roads you have driven in which vehicle. Every trip is map-matched against OpenStreetMap **on-device** — no server, no ongoing cost — and driven road segments are permanently painted onto a Google-Maps-style base map. Coverage aggregates into a five-level admin hierarchy (Land → Bundesland → Landkreis → Gemeinde → Stadtteil/Ortsteil) with a live focus-area pill that changes as you zoom.

The Dart package name in `pubspec.yaml` remains `auto_explore` (legacy working title) — the product-facing name is **Trailblazer**.

## Status

Phase 1 (Scaffolding) — CI, App DB, routing, permissions, error/logging, docs. See [`.planning/ROADMAP.md`](./.planning/ROADMAP.md) for the full 11-phase plan.

## App Icon

The launcher icon lives at [`assets/icons/app_icon.jpg`](./assets/icons/app_icon.jpg) — a 1024×1024 Liquid Glass rendering of a cartoon map with an orange driven-road trail (a visual preview of the app's core value). Platform icon sets are generated from it with [`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons):

```bash
# Regenerate after editing assets/icons/app_icon.jpg
dart run flutter_launcher_icons
```

Outputs land in `android/app/src/main/res/mipmap-*/ic_launcher.png` (all densities) and `ios/Runner/Assets.xcassets/AppIcon.appiconset/` (all sizes 20×20 → 1024×1024, alpha stripped for App Store compliance). See the `flutter_launcher_icons:` block in [`pubspec.yaml`](./pubspec.yaml) for config.

## Tech Stack

| Layer            | Choice |
|------------------|--------|
| UI + platform    | Flutter 3.44 (stable) / Dart 3.10 (iOS + Android only) |
| State management | Riverpod 3.x (`flutter_riverpod ^3.3.2`) |
| Routing          | `go_router ^17.3.0` |
| Local DB         | Drift 2.34 (`drift_flutter ^0.3.0`) — SQLite with WAL + foreign keys |
| Logging          | `logging ^1.3.0` (debug=verbose, release=warnings+) |
| Base map         | MapLibre GL + PMTiles vector tiles (offline; Phase 2) |
| Map matching     | Custom HMM (Newson-Krumm 2009), on-device, isolate-based (Phase 5) |
| Background GPS   | `flutter_background_geolocation` (Phase 3) |
| Lints            | `very_good_analysis ^10.3.0` |
| Tests            | `flutter_test` + `mocktail` + Drift `SchemaVerifier` |
| CI               | GitHub Actions + Codecov |

> **Known lint gap:** `custom_lint` + `riverpod_lint` are **not** currently enabled — irresolvable analyzer conflict with `drift_dev 2.34` (analyzer `^13` vs `^8`). Will be re-adopted once upstream `custom_lint` supports analyzer 13. See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md#locked-decisions-phase-1).

## Prerequisites

- **Flutter 3.44.4** (stable channel) or newer — `pubspec.yaml` pins `>=3.44.0`.
- **Dart 3.10** or newer (bundled with Flutter 3.44+).
- iOS: Xcode 15+ (for local iOS builds).
- Android: Android SDK + `cmdline-tools` with licenses accepted (for local Android debug builds).

## Quickstart

```bash
# 1. Get dependencies
flutter pub get

# 2. Run codegen (Drift + any Riverpod parts).
#    Required BEFORE analyze/test — the generated files are gitignored.
dart run build_runner build --delete-conflicting-outputs

# 3. Regenerate Drift migration helpers.
#    These land in test/generated_migrations/ (gitignored) and back the SchemaVerifier tests.
dart run drift_dev schema generate drift_schemas/ test/generated_migrations/

# 4. Lint + format
flutter analyze --fatal-infos
dart format --set-exit-if-changed .

# 5. Test with coverage
flutter test --coverage

# 6. Run on a device / simulator
flutter run
```

> **Why codegen runs first:** `.g.dart` (Drift/Riverpod) files and `test/generated_migrations/` are gitignored to keep diffs clean. A fresh checkout will fail `flutter analyze` and `flutter test` until steps 2 + 3 have been run. CI runs both before analyze/test — see [`.github/workflows/ci.yml`](./.github/workflows/ci.yml).

## Git hooks

The repo ships a tracked `pre-push` hook that runs `flutter analyze --fatal-infos && flutter test` before every push and blocks the push on failure. Wire it once per clone:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/*   # macOS/Linux only
```

Bypass in an emergency with `git push --no-verify` or `TRAILBLAZER_SKIP_PREPUSH=1 git push`. See [`.githooks/README.md`](./.githooks/README.md) for details and the Ralph Loop tiering rationale.

## Build

```bash
# Android debug APK (run locally — Android is NOT built in CI)
flutter build apk --debug

# iOS unsigned archive (matches CI ios-build.yml)
flutter build ipa --no-codesign
```

## Continuous Integration

| Workflow | Trigger | Runs |
|----------|---------|------|
| [`ci.yml`](./.github/workflows/ci.yml) | push to `main`, PRs targeting `main` | codegen → format → analyze → test with coverage → Codecov upload |
| [`ios-build.yml`](./.github/workflows/ios-build.yml) | **manual only** (`workflow_dispatch`) | codegen → `flutter build ipa --no-codesign` → upload `build/ios/archive/*.xcarchive` artifact |

Android debug builds run **locally on the dev machine** (`flutter build apk --debug`) — not in CI. Coverage reports are uploaded to [Codecov](https://app.codecov.io/github/robin13901/trailblazer) with no hard gate.

## Architecture

See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the feature-first layout, layer conventions, and Phase 1 locked decisions.

## Documentation

- [`.planning/PROJECT.md`](./.planning/PROJECT.md) — vision, decisions, constraints
- [`.planning/REQUIREMENTS.md`](./.planning/REQUIREMENTS.md) — v1 requirements
- [`.planning/ROADMAP.md`](./.planning/ROADMAP.md) — 11-phase roadmap
- [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) — layer + folder conventions
- [`.planning/phases/01-scaffolding/`](./.planning/phases/01-scaffolding/) — Phase 1 plans + summaries
- [`.planning/research/`](./.planning/research/) — domain research (OSM, HMM, MapLibre, etc.)

## License

Private — not licensed for redistribution at this time.
