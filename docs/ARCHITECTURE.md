# Architecture

Trailblazer (Dart package `auto_explore`) is a single-user Flutter app. All persistence is local; there is no server. This document captures the high-level layer conventions and the **locked decisions from Phase 1 (Scaffolding)** so future phases don't accidentally regress them.

For phase-by-phase context, see [`.planning/ROADMAP.md`](../.planning/ROADMAP.md).

## Layers

Feature-first, three-layer per feature:

```
lib/
├── main.dart                # WidgetsFlutterBinding, setupLogging, ProviderScope, error hooks
├── app.dart                 # MaterialApp.router (wired to appRouterProvider)
│
├── core/                    # Cross-cutting infrastructure
│   ├── db/                  # Drift App DB + tables
│   │   ├── app_database.dart
│   │   └── tables/
│   │       ├── trips.dart
│   │       ├── trip_points.dart
│   │       ├── driven_intervals.dart
│   │       ├── vehicles.dart
│   │       ├── bt_fingerprints.dart
│   │       ├── coverage_cache.dart
│   │       └── app_prefs.dart
│   ├── logging/             # AppLogger (logging package, debug-vs-release gate)
│   │   └── app_logger.dart
│   ├── errors/              # sealed DomainError + Result<T>
│   │   ├── domain_error.dart
│   │   └── result.dart
│   └── routing/             # go_router config (splash -> onboarding -> home)
│       └── app_router.dart
│
└── features/                # One folder per feature (feature-first)
    ├── map/                 # Placeholder in Phase 1; real map lands in Phase 2
    ├── trips/
    ├── vehicles/
    ├── regions/
    ├── settings/
    └── onboarding/          # Real content from Plan 01-03 (SplashScreen + OnboardingScreen)
```

Supporting directories:

```
drift_schemas/               # Committed Drift schema snapshots (drift_schema_v1.json today)
test/generated_migrations/   # Drift SchemaVerifier helpers — GITIGNORED, generated at build time
tool/                        # Dev-machine CLIs (empty in Phase 1; OSM pipeline lands here in Phase 4)
android/ + ios/              # Native platform config (permissions, foreground service skeleton)
.github/workflows/           # ci.yml (main + PRs) + ios-build.yml (manual)
```

### Layering rules

1. `presentation/` depends on `domain/`, never directly on `data/` — repositories are injected through Riverpod providers.
2. `domain/` is **pure Dart**. No `package:flutter/*` imports, no plugin imports. Testable without any binding.
3. `data/` implements repositories against Drift, plugins, or HTTP clients.
4. Cross-feature dependencies go through `core/` or through public repository / use-case types exported from a feature — never reach into another feature's `data/` or `presentation/`.
5. All imports use `package:auto_explore/…` prefix — enforced by `very_good_analysis`'s `always_use_package_imports`. Relative imports are a lint error.

## Locked decisions (Phase 1)

The following decisions are frozen for Phase 1 and inform every downstream phase. If a future plan needs to deviate, it must call out the deviation explicitly.

### Toolchain

- **Flutter 3.44.4 (stable)** minimum — `pubspec.yaml` pins `sdk: '>=3.44.0'`.
- **Dart 3.10+** (bundled with Flutter 3.44).
- **iOS + Android only** — no web, macOS, Windows, Linux targets.

### Dependencies

- **State:** `flutter_riverpod ^3.3.2`. Providers are plain `Provider<T>` in Phase 1 (no `@Riverpod` codegen yet). No singletons, no `.instance` shortcuts.
- **Routing:** `go_router ^17.3.0` exposed via `appRouterProvider` (plain `Provider`).
- **Local DB:** `drift ^2.34.0` + `drift_flutter ^0.3.0` (NOT `sqlite3_flutter_libs` — EOL). Foreign keys ON, WAL mode ON — re-applied in `beforeOpen` because SQLite `foreign_keys` is per-connection.
- **Logging:** `logging ^1.3.0`. Debug uses `dart:developer.log()` at `Level.ALL`; release uses `debugPrint` at `Level.WARNING`. Plain-text format, no remote crash sink (dev-only per CONTEXT.md).
- **Lints:** `very_good_analysis ^10.3.0`.
- **Alphabetized `pubspec.yaml`** — enforced via `sort_pub_dependencies` lint.
- **Dropped:** `custom_lint` + `riverpod_lint`. Analyzer conflict with `drift_dev 2.34` (`analyzer ^13` vs `^8`). Re-adopt when upstream `custom_lint` supports analyzer 13. `analysis_options.yaml` therefore has no `analyzer.plugins:` entry.

### Errors & logging

- Sealed **`DomainError`** hierarchy covers four required categories (DB / Storage / Permission / Network) plus an `UnknownError` catch-all. Repositories wrap driver exceptions via `DomainError.wrap(...)` at the boundary.
- **`Result<T>` (`Ok` / `Err`)** is the return type for repositories / use-cases where failure is data rather than an exception. Use `when()` for exhaustive fold. Reserved for expected failures — programmer errors still throw.
- **`FlutterError.onError`** and **`PlatformDispatcher.instance.onError`** both funnel through `DomainError.wrap` and log at `severe`. `PlatformDispatcher.onError` returns `true` to prevent OS-level crash (dev-only behavior).
- `DomainError.toString()` retains `runtimeType` — the required `no_runtimetype_tostring` ignore is documented inline.

### App DB (Drift v1)

- Seven tables: `trips`, `trip_points`, `driven_intervals`, `vehicles`, `bt_fingerprints`, `coverage_cache`, `app_prefs`.
- FK cascade policies:
  - `trip_points -> trips` → **CASCADE** (points are worthless without their trip)
  - `driven_intervals -> trips` → **SET NULL** (coverage survives trip loss)
  - `bt_fingerprints -> vehicles` → **CASCADE**
- `coverage_cache` and `app_prefs` use **business-key PKs** (`region_id`, `key`) — no synthetic `id`, no extra index.
- `AppDatabase` constructor accepts an optional `QueryExecutor` so tests can inject `NativeDatabase.memory()`.
- **Migration tests:** Drift `SchemaVerifier` compares runtime schema against `drift_schemas/drift_schema_v1.json`. That JSON is committed; `test/generated_migrations/` is gitignored and regenerated by `dart run drift_dev schema generate drift_schemas/ test/generated_migrations/`.
- CI runs `build_runner build` **and** `drift_dev schema generate` before `flutter analyze` / `flutter test` — analyzer needs the generated files.

### Routing & onboarding

- Onboarding is shown once, gated by a `SharedPreferencesAsync` flag `onboarding_done` (repository key exposed as public `OnboardingFlagRepository.prefsKey` for test/debug parity).
- Gating lives **inside `SplashScreen`** (microtask reads the prefs then `context.go`), NOT a top-level `GoRouter.redirect`. Rationale: keeps the router synchronous, avoids re-reads on every navigation.
- `shared_preferences_platform_interface ^2.4.2` is a **dev_dependency** so tests can install `InMemorySharedPreferencesAsync` without hitting a platform channel.

### Native platform config

- **iOS Info.plist:** 6 purpose strings — Location Always + WhenInUse, Motion, Bluetooth Always + Central — plus `UIBackgroundModes = [location, bluetooth-central]`. `NSBluetoothPeripheralUsageDescription` is intentionally omitted (deprecated; app is Bluetooth-central-only).
- **AndroidManifest:** 10 permissions declared — `ACCESS_FINE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, `ACTIVITY_RECOGNITION`, `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, plus companions. No `minSdkVersion` bump — permissions are gated with `maxSdkVersion` attributes; runtime prompts will arrive in Phase 3.
- **Foreground service skeleton:** `<service android:name=".LocationRecordingService" android:foregroundServiceType="location">` — placeholder class name. Phase 3 must rebind `android:name` to `flutter_background_geolocation`'s real service class before the FGS starts.
- `permission_handler` is **not** yet a dependency — declarations are static in Phase 1; runtime prompt code lands in Phase 3+.

### CI

- **`ci.yml`** runs on push to `main` and PRs targeting `main`. Steps: checkout → Flutter setup → `pub get` → `build_runner build` → `drift_dev schema generate` → `dart format --set-exit-if-changed` → `flutter analyze --fatal-infos` → `flutter test --coverage` → strip generated files via `remove_from_coverage` → Codecov upload. **Codegen runs before format/analyze** because those steps need the generated files.
- **`ios-build.yml`** is **manual-trigger only** (`workflow_dispatch`) — saves macOS runner minutes. Artifact is `build/ios/archive/*.xcarchive` (unsigned builds don't produce a real `.ipa`).
- **Android debug** builds happen **locally on the dev machine** (`flutter build apk --debug`), not in CI.
- **Codecov:** repo has `CODECOV_TOKEN` registered; reports at <https://app.codecov.io/github/robin13901/trailblazer>. No hard coverage gate.

## Anti-patterns to avoid (vs prior Flutter projects)

| Anti-pattern                          | Trailblazer replacement                              | Reason                                     |
|---------------------------------------|------------------------------------------------------|--------------------------------------------|
| `provider` + singleton `.instance`    | Riverpod 3.x providers                               | Testability, no static coupling            |
| Flat `screens/` folder                | `features/{feature}/{data,domain,presentation}`      | Scales to 6+ features cleanly              |
| Empty `analysis_options.yaml`         | `include: package:very_good_analysis/analysis_options.yaml` | Catch bugs at lint time             |
| `sqlite3_flutter_libs` direct         | `drift_flutter`                                      | Former is EOL                              |
| Relative imports (`../../core/...`)   | `package:auto_explore/core/...`                      | Enforced by `always_use_package_imports`   |
| Repositories throwing raw exceptions  | `DomainError.wrap()` at boundary + `Result<T>`       | Failure is data, not surprises             |

## Next phases

See [`.planning/ROADMAP.md`](../.planning/ROADMAP.md) for the full 11-phase plan. Immediate handoffs:

- **Phase 2 (Map foundation):** replace `PlaceholderHomeScreen` at `/` with `StatefulShellRoute` + MapLibre view + Liquid Glass chrome. Splash/onboarding stay untouched. Spike gate **G1** validates `BackdropFilter` over MapLibre platform view on real iOS + Android.
- **Phase 3 (Background GPS):** wire `flutter_background_geolocation` and rebind the AndroidManifest foreground-service class from `.LocationRecordingService` to the plugin's real service class. Add `permission_handler` and drive runtime prompts.
- **Phase 4 (OSM pipeline):** dev-machine CLIs land in `tool/`.
- **Phase 5 (Map matching):** custom HMM (Newson-Krumm) in an isolate; ≥ 20-trip golden corpus required before CI regression.
- **Phase 7 (Coverage rendering):** spike gate **G2** validates `maplibre_gl` `setFeatureState` support; sharded-GeoJSON fallback documented.

## Chore backlog

- Re-add `custom_lint` + `riverpod_lint` once a `custom_lint` release supports `analyzer ^13.0.0`; restore `analyzer.plugins: - custom_lint` in `analysis_options.yaml`.
- Confirm `flutter build apk --debug` on a Windows host with `cmdline-tools` + Android SDK licenses accepted.
- Consider adding an on-demand Android CI job (`workflow_dispatch`) if the solo-dev workflow shifts.
