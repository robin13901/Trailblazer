# Phase 1: Scaffolding - Research

**Researched:** 2026-07-02
**Domain:** Flutter project bootstrap, CI, Drift App DB, go_router, error/logging, permission plumbing
**Confidence:** HIGH (all package versions verified via pub.dev and official docs today)

---

## Summary

Phase 1 builds the production-quality foundation that all 10 downstream phases depend on. The work splits into four pillars: (1) project skeleton + folder structure, (2) CI pipeline (lint, test, coverage, builds), (3) App DB (Drift schema for all v1 tables + migration infrastructure), and (4) runtime scaffolding (routing, logging, error handling, permission manifest entries).

The most important finding is a **package discrepancy vs. STACK.md**: `sqlite3_flutter_libs` is now marked EOL (`0.6.0+eol`). The current path is to use `drift_flutter` ^0.3.0 as the Flutter-specific Drift companion, which bundles the right sqlite3 hooks internally. Also, `riverpod_annotation` is now at **^4.0.3** (not 3.3.2 as STACK.md stated) and `custom_lint` is at **0.8.1** (not 0.7.5). Flutter stable is now **3.44** with Dart **3.10**.

All five success criteria have clear artifact-to-command mappings (see §12).

**Primary recommendation:** Use `drift_flutter` (not bare `sqlite3_flutter_libs`) for the Drift setup. Every other STACK.md choice is confirmed correct at current versions.

---

## Standard Stack

### Core Dependencies

| Library | Verified Version | Purpose | Source |
|---------|-----------------|---------|--------|
| `flutter_riverpod` | ^3.3.2 | State management | pub.dev verified 2026-07-02 |
| `riverpod_annotation` | ^4.0.3 | Code-gen annotations | pub.dev (note: STACK.md had 3.3.2 — wrong) |
| `go_router` | ^17.3.0 | Typed declarative routing | pub.dev verified |
| `drift` | ^2.34.0 | Type-safe SQLite ORM | pub.dev verified |
| `drift_flutter` | ^0.3.0 | Flutter-specific Drift setup | pub.dev (replaces sqlite3_flutter_libs) |
| `path_provider` | ^2.1.6 | App directory paths | pub.dev verified |
| `logging` | ^1.3.0 | Core logging (dart.dev) | pub.dev verified |
| `shared_preferences` | ^2.5.5 | First-launch flag persistence | pub.dev verified |

### Dev Dependencies

| Library | Verified Version | Purpose | Source |
|---------|-----------------|---------|--------|
| `very_good_analysis` | ^10.3.0 | Lint rules | pub.dev verified |
| `drift_dev` | ^2.34.1+1 (use ^2.34.0) | Drift codegen + schema tools | pub.dev verified |
| `build_runner` | ^2.15.0 | Codegen orchestrator | pub.dev verified |
| `riverpod_generator` | ^4.0.4 | Riverpod codegen | pub.dev verified |
| `riverpod_lint` | ^3.1.4 | Riverpod-specific lint rules | pub.dev verified |
| `custom_lint` | ^0.8.1 | Plugin host for riverpod_lint | pub.dev verified |
| `mocktail` | ^1.0.5 | Test mocking (no codegen) | pub.dev verified |
| `remove_from_coverage` | ^2.0.0 | Strip generated files from lcov | pub.dev verified |

### Packages NOT in Phase 1 (added in later phases)

`freezed`, `json_serializable`, `maplibre_gl`, `pmtiles`, `flutter_background_geolocation`, `permission_handler`, `geobase`, `turf`, `r_tree`, `dart_earcut`, `flutter_blue_plus`, `liquid_glass_renderer`, `liquid_navbar`.

### CRITICAL DISCREPANCIES vs. STACK.md

| STACK.md stated | Verified correct | Impact |
|-----------------|-----------------|--------|
| `sqlite3_flutter_libs: ^0.5.24` | Use `drift_flutter: ^0.3.0` instead | sqlite3_flutter_libs is EOL (0.6.0+eol) |
| `riverpod_annotation: ^3.3.2` | `riverpod_annotation: ^4.0.3` | Major version bump — use 4.x |
| `custom_lint: ^0.7.5` | `custom_lint: ^0.8.1` | Minor bump |
| `Flutter: ">=3.24.0"` | Flutter 3.44 stable / Dart 3.10 | Use updated env constraints |
| `sdk: ^3.5.0` | `sdk: ">=3.10.0 <4.0.0"` | Current stable is Dart 3.10 |
| Codecov action v5 | `codecov/codecov-action@v5` still valid | v7 is latest but v5 works |

### Phase 1 pubspec.yaml snippet

```yaml
name: auto_explore
description: "GPS trip tracker — drive everywhere, color the roads."
publish_to: 'none'
version: 0.1.0+1

environment:
  sdk: ">=3.10.0 <4.0.0"
  flutter: ">=3.44.0"

dependencies:
  flutter:
    sdk: flutter

  # State management
  flutter_riverpod: ^3.3.2
  riverpod_annotation: ^4.0.3

  # Routing
  go_router: ^17.3.0

  # Database
  drift: ^2.34.0
  drift_flutter: ^0.3.0   # handles sqlite3 platform setup; DO NOT add sqlite3_flutter_libs

  # Filesystem
  path_provider: ^2.1.6
  path: ^1.9.0

  # Logging & preferences
  logging: ^1.3.0
  shared_preferences: ^2.5.5

  # Platform UI
  cupertino_icons: ^1.0.8

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter

  # Codegen
  build_runner: ^2.15.0
  drift_dev: ^2.34.0
  riverpod_generator: ^4.0.4

  # Lints
  very_good_analysis: ^10.3.0
  riverpod_lint: ^3.1.4
  custom_lint: ^0.8.1

  # Testing
  mocktail: ^1.0.5
  remove_from_coverage: ^2.0.0

flutter:
  uses-material-design: true
  generate: true
```

### Installation

```bash
flutter create \
  --org de.autoexplore \
  --platforms ios,android \
  --template app \
  auto_explore

cd auto_explore
# Then replace pubspec.yaml with above content
flutter pub get
```

---

## Architecture Patterns

### Recommended Project Structure (Phase 1 scope)

```
auto_explore/
├── lib/
│   ├── main.dart                   # ProviderScope, error hooks, runApp
│   ├── app.dart                    # MaterialApp.router wired to GoRouter
│   │
│   ├── core/
│   │   ├── db/
│   │   │   ├── app_database.dart   # @DriftDatabase class, schemaVersion, MigrationStrategy
│   │   │   ├── app_database.g.dart # generated
│   │   │   └── tables/            # one .dart file per table group
│   │   │       ├── trips_table.dart
│   │   │       ├── trip_points_table.dart
│   │   │       ├── driven_intervals_table.dart
│   │   │       ├── vehicles_table.dart
│   │   │       ├── bt_fingerprints_table.dart
│   │   │       ├── coverage_cache_table.dart
│   │   │       └── app_prefs_table.dart
│   │   │
│   │   ├── logging/
│   │   │   └── app_logger.dart     # Logger hierarchy setup, kDebugMode gate
│   │   │
│   │   ├── errors/
│   │   │   └── domain_error.dart   # sealed class DomainError, Result<T>
│   │   │
│   │   └── routing/
│   │       └── app_router.dart     # GoRouter config, splash/onboarding/main shell
│   │
│   └── features/
│       └── onboarding/
│           └── presentation/
│               ├── splash_screen.dart
│               └── onboarding_screen.dart   # first-launch only stub
│
├── test/
│   ├── helpers/
│   │   └── test_database.dart      # NativeDatabase.memory() helper
│   ├── core/
│   │   └── db/
│   │       └── migration_test.dart # SchemaVerifier test(s)
│   └── widget_test.dart            # Basic app smoke test
│
├── drift_schemas/                  # Schema JSON dumps — one per schemaVersion
│   └── drift_schema_v1.json        # generated by: dart run drift_dev schema dump
│
├── test/generated_migrations/      # generated by: dart run drift_dev schema generate
│
├── .github/
│   └── workflows/
│       ├── ci.yml                  # lint + test + coverage + Codecov
│       └── ios-build.yml          # unsigned iOS .ipa + Android debug APK (parallel)
│
├── ios/Runner/Info.plist           # All purpose strings + UIBackgroundModes
├── android/app/src/main/AndroidManifest.xml   # All permissions + foreground service skeleton
│
├── analysis_options.yaml
└── build.yaml                      # Codegen build ordering config
```

**Schema file organization decision (Claude's Discretion):** Use domain-split table files under `core/db/tables/`. Rationale: the full v1 schema covers 7 table groups; one 800-line file would be unmaintainable and trigger lint violations (`lines_longer_than_80_chars`). Each table file is a standalone Dart file that only `lib/core/db/app_database.dart` imports.

**Onboarding navigation (Claude's Discretion):** Implement as a separate GoRoute path (`/onboarding`) guarded by a `redirect` on the root GoRouter. The redirect reads the `onboarding_done` flag from `SharedPreferences`. If false → redirect to `/onboarding`. If true → pass through to `/`. This is simpler than a modal and survives deep links correctly.

### Pattern 1: Flutter project bootstrap

**Command:**
```bash
flutter create \
  --org de.autoexplore \
  --platforms ios,android \
  --template app \
  auto_explore
```

**Gotchas:**
- `--org` uses reverse-domain notation; becomes the iOS bundle ID prefix and Android applicationId.
- `--platforms ios,android` omits web/linux/windows boilerplate.
- Project name `auto_explore` (snake_case) → Dart package name. Use this, not `Auto-Explore-App` (hyphens forbidden in Dart package names).
- After create, immediately remove the generated default counter app code from `lib/main.dart` and `lib/` before any CI runs or the lint will fail on unused imports.

**Minimum SDK targets:**
- iOS: 13.0 (Flutter 3.44 minimum; set in Xcode target and `flutter.minSdkVersion`)
- Android: `minSdkVersion 24` (Flutter 3.44 minimum)
- Dart: `">=3.10.0 <4.0.0"`
- Flutter: `">=3.44.0"`

### Pattern 2: very_good_analysis setup

**File: `analysis_options.yaml`**

```yaml
include: package:very_good_analysis/analysis_options.yaml

analyzer:
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"
    - "**/*.drift.dart"
    - "test/generated_migrations/**"

linter:
  rules:
    # App-specific overrides (not a published library)
    public_member_api_docs: false
    # Drift table definitions exceed 80 chars routinely
    lines_longer_than_80_chars: false
```

**Gotchas:**
- Do NOT disable `avoid_print` — use the `logging` package instead; this is the intent of the rule.
- `public_member_api_docs` must be explicitly disabled for an app (very_good_analysis enables it for libraries; it's irrelevant here and will spam analyzer output).
- Generated files (`*.g.dart`, `*.freezed.dart`, `*.drift.dart`) must be excluded or analyzer will report thousands of errors on generated code.
- `custom_lint` requires a `analysis_options.yaml` plugin entry too:

```yaml
# In analysis_options.yaml, also add:
analyzer:
  plugins:
    - custom_lint
```

### Pattern 3: GitHub Actions CI workflow

**File: `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]

jobs:
  lint-and-test:
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
          fail_ci_if_error: false   # no hard gate per decision
```

**File: `.github/workflows/ios-build.yml`**

```yaml
name: Builds

on:
  push:
    branches: [main]

jobs:
  ios-build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - run: flutter pub get
      - name: Build iOS (unsigned)
        run: flutter build ios --release --no-codesign

  android-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - run: flutter pub get
      - name: Build Android debug APK
        run: flutter build apk --debug
```

**Key decisions reflected:**
- Trigger: `push` to `main` only (no PRs, no branches — solo dev).
- Failure mode: jobs are separate (lint-and-test / ios-build / android-build), so all report in one pass. No `fail-fast: false` needed since they're independent jobs not a matrix.
- iOS and Android builds run in parallel (separate jobs).
- Codecov has `fail_ci_if_error: false` — no hard gate.

**Gotchas:**
- `subosito/flutter-action@v2` with `channel: stable` picks the current stable (3.44). Do NOT pin `flutter-version: '3.44.0'` now — you'll need to update it on every Flutter release. Channel-pinning is lower maintenance for a solo project.
- iOS build **must** run on `macos-latest` (requires Xcode). Ubuntu cannot build iOS.
- `flutter build ios --release --no-codesign` produces an unsigned `.app` in `build/ios/iphoneos/Runner.app`. This satisfies success criterion 3 (build green, no crash) without requiring certificates.
- `secrets.CODECOV_TOKEN` must be added to the GitHub repo under Settings → Secrets → Actions.
- `dart format --set-exit-if-changed .` formats with the current stable Dart formatter. Do not use `--output write` in CI (it would silently modify and succeed).
- Add `build_runner` sanity check if you want to catch stale generated files: `dart run build_runner build --delete-conflicting-outputs 2>&1 | grep -c "^" || true` (optional, slows CI ~30-60s).

### Pattern 4: Drift App DB skeleton

**Full v1 schema — all tables, Phase 1**

The decision (from CONTEXT.md) is to define all Phase 1 tables now. The seven table groups cover every downstream feature's App DB needs.

```dart
// lib/core/db/tables/trips_table.dart
import 'package:drift/drift.dart';

class Trips extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  RealColumn get distanceMeters => real().nullable()();
  RealColumn get avgSpeedKmh => real().nullable()();
  RealColumn get maxSpeedKmh => real().nullable()();
  // status: 'pending' | 'confirmed' | 'rejected'
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get vehicleId => integer().nullable()();
  BoolColumn get manuallyStarted => boolean().withDefault(const Constant(false))();
  BoolColumn get autoStopped => boolean().withDefault(const Constant(false))();
  TextColumn get bluetoothHint => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
```

```dart
// lib/core/db/tables/trip_points_table.dart
class TripPoints extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tripId => integer().references(Trips, #id, onDelete: KeyAction.cascade)();
  IntColumn get seq => integer()();
  DateTimeColumn get ts => dateTime()();
  RealColumn get lat => real()();
  RealColumn get lon => real()();
  RealColumn get speedKmh => real().nullable()();
  RealColumn get accuracyMeters => real().nullable()();
  RealColumn get altitudeMeters => real().nullable()();
  TextColumn get motionType => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [{ tripId, seq }];
}
```

```dart
// lib/core/db/tables/driven_intervals_table.dart
class DrivenWayIntervals extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get wayId => integer()();     // OSM way ID
  IntColumn get tripId => integer().references(Trips, #id, onDelete: KeyAction.setNull).nullable()();
  RealColumn get startMeters => real()();
  RealColumn get endMeters => real()();
  // direction: 'forward' | 'backward' | 'both'
  TextColumn get direction => text().withDefault(const Constant('forward'))();
  DateTimeColumn get matchedAt => dateTime().withDefault(currentDateAndTime)();
}
```

```dart
// lib/core/db/tables/vehicles_table.dart
class Vehicles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get model => text().nullable()();
  TextColumn get colorHex => text().nullable()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  BoolColumn get countsForCoverage => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
```

```dart
// lib/core/db/tables/bt_fingerprints_table.dart
class BtFingerprints extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get vehicleId => integer().references(Vehicles, #id, onDelete: KeyAction.cascade)();
  TextColumn get macAddress => text()();
  TextColumn get deviceName => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
```

```dart
// lib/core/db/tables/coverage_cache_table.dart
class CoverageCache extends Table {
  TextColumn get regionId => text()();     // OSM relation ID as string
  RealColumn get drivenLengthM => real().withDefault(const Constant(0.0))();
  RealColumn get totalLengthM => real().withDefault(const Constant(0.0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get extractVersion => text().nullable()();
  IntColumn get invalidationGen => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => { regionId };
}
```

```dart
// lib/core/db/tables/app_prefs_table.dart
class AppPrefs extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();

  @override
  Set<Column> get primaryKey => { key };
}
```

**Main database class:**

```dart
// lib/core/db/app_database.dart
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'tables/trips_table.dart';
import 'tables/trip_points_table.dart';
import 'tables/driven_intervals_table.dart';
import 'tables/vehicles_table.dart';
import 'tables/bt_fingerprints_table.dart';
import 'tables/coverage_cache_table.dart';
import 'tables/app_prefs_table.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  Trips,
  TripPoints,
  DrivenWayIntervals,
  Vehicles,
  BtFingerprints,
  CoverageCache,
  AppPrefs,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // v1 → v2 migrations go here in future phases
        },
        beforeOpen: (details) async {
          // Enable foreign key enforcement
          await customStatement('PRAGMA foreign_keys = ON');
          // WAL mode for concurrent reads
          await customStatement('PRAGMA journal_mode = WAL');
        },
      );

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'app_db');
  }
}
```

**Schema export and migration test workflow:**

```bash
# Step 1: After defining the initial schema, export v1 JSON
dart run drift_dev schema dump lib/core/db/app_database.dart drift_schemas/

# Step 2: Generate migration test helpers
dart run drift_dev schema generate drift_schemas/ test/generated_migrations/

# Step 3: Run the generated migration test
flutter test test/core/db/migration_test.dart
```

**Migration test (Phase 1 has only v1, so test verifies onCreate):**

```dart
// test/core/db/migration_test.dart
import 'package:drift_dev/api/migrations_native.dart';
import 'package:test/test.dart';
import '../../generated_migrations/schema.dart';  // generated
import '../../../lib/core/db/app_database.dart';

void main() {
  test('v1 schema matches expected tables', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(1);
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 1);
    await db.close();
  });
}
```

**Gotchas:**
- `drift_flutter: ^0.3.0` provides `driftDatabase()`. Do NOT add `sqlite3_flutter_libs` directly — it is EOL.
- `drift_flutter` brings `sqlite3_flutter_libs` transitively but the EOL version is a stub that defers to `sqlite3` ^3.x. This is correct and intentional.
- `PRAGMA foreign_keys = ON` must be set in `beforeOpen` — Drift does NOT enable it by default, and SQLite does not enable it by default.
- `PRAGMA journal_mode = WAL` is important for concurrent reads (Drift isolate + OSM isolate added in Phase 5).
- Store all timestamps as UTC via `DateTimeColumn` — Drift stores them as Unix epoch integers. Always format to local time only in the UI layer (prevents DST bugs — PITFALLS L1).
- The `drift_dev` schema dump command requires the **exact path** to the file containing `@DriftDatabase` — it is NOT recursive.
- `part 'app_database.g.dart'` must be in the same file as `@DriftDatabase`. Do not split them.

### Pattern 5: go_router setup

**File: `lib/core/routing/app_router.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'app_router.g.dart';

@riverpod
GoRouter appRouter(Ref ref) {
  return GoRouter(
    initialLocation: '/splash',
    redirect: (context, state) async {
      // Guard: if navigating anywhere except splash/onboarding,
      // check onboarding completion.
      // Actual prefs check wired in Phase 2; placeholder here.
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      // Main shell — bottom nav with 4 tabs (Map, Trips, Regions, Settings)
      // Added in Phase 2; placeholder route keeps app launchable:
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('Auto-Explore')),
        ),
      ),
    ],
  );
}
```

**File: `lib/app.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/routing/app_router.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Auto-Explore',
      routerConfig: router,
    );
  }
}
```

**Onboarding guard logic (first-launch gate):**

```dart
// In app_router.dart redirect, replace placeholder with:
redirect: (context, state) async {
  final prefs = await SharedPreferencesAsync().getBool('onboarding_done');
  final onboardingDone = prefs ?? false;
  final goingToOnboarding = state.matchedLocation == '/onboarding';
  final goingToSplash = state.matchedLocation == '/splash';

  if (!onboardingDone && !goingToOnboarding && !goingToSplash) {
    return '/onboarding';
  }
  if (onboardingDone && goingToOnboarding) {
    return '/';
  }
  return null;
},
```

**Phase 2 StatefulShellRoute pattern (for planner awareness, not Phase 1 task):**

```dart
// Phase 2 adds this inside routes:
StatefulShellRoute.indexedStack(
  builder: (context, state, navigationShell) => MainShell(navigationShell: navigationShell),
  branches: [
    StatefulShellBranch(routes: [GoRoute(path: '/map', builder: ...)]),
    StatefulShellBranch(routes: [GoRoute(path: '/trips', builder: ...)]),
    StatefulShellBranch(routes: [GoRoute(path: '/regions', builder: ...)]),
    StatefulShellBranch(routes: [GoRoute(path: '/settings', builder: ...)]),
  ],
),
```

**Gotchas:**
- `GoRouter` constructed inside a Riverpod `@riverpod` provider so it can watch auth/onboarding state reactively. Do NOT create it as a top-level global — that breaks Riverpod scope and makes testing impossible.
- `SharedPreferencesAsync` (new async API) is preferred over `SharedPreferences.getInstance()` for new code per the shared_preferences docs.
- The `redirect` callback in GoRouter can be async (returns `Future<String?>`).
- `go_router` ^17 requires `MaterialApp.router(routerConfig: router)` — NOT the older `routeInformationParser`/`routerDelegate` split API.

### Pattern 6: Error & logging infrastructure

**File: `lib/core/logging/app_logger.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Call once in main() before runApp.
void setupLogging() {
  if (kDebugMode) {
    Logger.root.level = Level.ALL;   // verbose in debug
  } else {
    Logger.root.level = Level.WARNING;  // warnings + errors only in release
  }

  Logger.root.onRecord.listen((record) {
    // Plain text format — simple, no JSON overhead for local-dev-only logs
    final message = '${record.level.name}: '
        '[${record.loggerName}] '
        '${record.time.toIso8601String()} '
        '${record.message}';
    // ignore: avoid_print — this IS the logging sink
    // ignore: flutter_style_todos
    print(message);   // dev-only, no remote sink per decision
    if (record.error != null) {
      // ignore: avoid_print
      print('  ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('  STACK: ${record.stackTrace}');
    }
  });
}

/// Per-module loggers — usage: final _log = Logger('core.db');
```

**File: `lib/main.dart`**

```dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'app.dart';
import 'core/logging/app_logger.dart';

final _log = Logger('main');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  setupLogging();

  // Catch Flutter framework errors (build, layout, paint)
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _log.severe('FlutterError', details.exception, details.stack);
  };

  // Catch async errors outside Flutter's callback zone
  PlatformDispatcher.instance.onError = (error, stack) {
    _log.severe('PlatformDispatcher.onError', error, stack);
    return true; // prevent default crash
  };

  runApp(const ProviderScope(child: App()));
}
```

**Log format decision (Claude's Discretion):** Plain text, not JSON. Rationale: no remote sink means no structured query consumer; JSON adds visual noise for local development. The diagnostics screen (Phase 10) will surface these logs — plain text is more readable there too.

**Gotchas:**
- `WidgetsFlutterBinding.ensureInitialized()` must be called before any plugin or async work in `main()`.
- `FlutterError.onError` must call `FlutterError.presentError(details)` to preserve the red-screen-of-death in debug mode.
- `PlatformDispatcher.instance.onError` returns `bool` — return `true` to prevent the platform from crashing the app; return `false` to allow the OS to handle it (usually a crash).
- Using `print()` in the logging sink is intentional (it IS the sink) but will trigger the `avoid_print` lint. Add a `// ignore: avoid_print` comment on each print call inside `app_logger.dart`.
- The `kDebugMode` constant from `flutter/foundation.dart` is compile-time constant — the tree shaker removes the verbose path in release builds.

### Pattern 7: Permission manifest plumbing (iOS + Android)

**iOS `ios/Runner/Info.plist` additions:**

```xml
<!-- Location permissions — required before any location API call -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>Auto-Explore records your route while you drive to show which roads you've explored.</string>

<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Auto-Explore records trips in the background so you never miss a road you've driven.</string>

<key>NSLocationAlwaysUsageDescription</key>
<string>Auto-Explore needs Always location access to record trips while your phone is locked.</string>

<!-- Motion & fitness -->
<key>NSMotionUsageDescription</key>
<string>Auto-Explore uses motion sensors to detect when you start and stop driving.</string>

<!-- Bluetooth — modern key (iOS 13+) -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Auto-Explore can use your car's Bluetooth connection to automatically detect which vehicle you're driving.</string>

<!-- Bluetooth — legacy key (keep for pre-iOS 13 compatibility) -->
<key>NSBluetoothCentralUsageDescription</key>
<string>Auto-Explore can use Bluetooth to detect your vehicle.</string>

<!-- Background modes — must be declared for any background work -->
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
  <string>bluetooth-central</string>
</array>
```

**Gotchas for iOS:**
- `NSBluetoothPeripheralUsageDescription` (old key, from Apple docs example above) is NOT the right key. Use `NSBluetoothAlwaysUsageDescription` for iOS 13+ apps. The old peripheral key is deprecated.
- App Store review will **reject** the app if any `UIBackgroundModes` entry is declared without a corresponding `NS*UsageDescription` string.
- The `location` background mode is required for the two-step `whenInUse → Always` ladder (Phase 3). Setting it up in Phase 1 avoids a Xcode project reconfigure later.
- `NSLocationAlwaysUsageDescription` (the legacy key) must ALSO be present even though Apple deprecated it; older iOS 12 devices still use it and App Store validation flags its absence.

**Android `android/app/src/main/AndroidManifest.xml` additions:**

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- Location -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <!-- Background location — requires separate runtime prompt on Android 10+ -->
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />

    <!-- Foreground service -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <!-- Type-specific permission for Android 14+ -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />

    <!-- Activity recognition — Android 10+ (API 29+) -->
    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />

    <!-- Bluetooth Classic (legacy devices) -->
    <uses-permission android:name="android.permission.BLUETOOTH"
                     android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN"
                     android:maxSdkVersion="30" />

    <!-- Bluetooth modern (Android 12+ / API 31+) -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

    <!-- Notifications — Android 13+ (API 33+) — needed for foreground service notification -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <!-- Wake lock — needed by flutter_background_geolocation (Phase 3) -->
    <uses-permission android:name="android.permission.WAKE_LOCK" />

    <application ...>

        <!-- Foreground service skeleton for Phase 3 — declare now, implement in Phase 3 -->
        <service
            android:name=".LocationRecordingService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="location" />

    </application>
</manifest>
```

**Gotchas for Android:**
- `FOREGROUND_SERVICE_LOCATION` (the type-specific permission) is SEPARATE from `FOREGROUND_SERVICE` (the base permission). Both are required on Android 14+.
- The `<service>` declaration with `foregroundServiceType="location"` is mandatory for `startForeground(id, notification, FOREGROUND_SERVICE_TYPE_LOCATION)` call in Phase 3. Not having it causes a `SecurityException` at runtime.
- `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` are **runtime** permissions on Android 12+ (just as `ACCESS_FINE_LOCATION` is). Manifest declaration is necessary but not sufficient.
- `android:maxSdkVersion="30"` on the legacy BLUETOOTH permissions prevents them from appearing on modern devices (they were replaced by the granular permissions).

### Pattern 8: App shell / entry point

The Phase 1 app must launch without crashing with a minimal visible UI. The placeholder home route (defined in routing above) satisfies Success Criterion 5.

**`lib/app.dart`** (from Pattern 5 above) wires the GoRouter to `MaterialApp.router`. The placeholder route renders `Center(child: Text('Auto-Explore'))`.

This is intentionally minimal — no `AppBar`, no theming (added Phase 2), no navigation. Just enough that `flutter run` + `flutter build ios --no-codesign` + `flutter build apk --debug` all exit 0.

### Pattern 9: build.yaml for codegen

```yaml
# build.yaml
targets:
  $default:
    builders:
      drift_dev:
        options:
          databases:
            app_database: lib/core/db/app_database.dart
```

**Codegen run command:**
```bash
dart run build_runner build --delete-conflicting-outputs
```

**Codegen order:** build_runner handles ordering automatically for this phase. When Freezed and riverpod_generator are added in later phases, ordering becomes important. Add a `build.yaml` ordering directive at that point if conflicts arise.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SQLite platform setup | Custom FFI bindings, manual .so linking | `drift_flutter: ^0.3.0` | sqlite3_flutter_libs EOL; drift_flutter handles platform hooks |
| Coverage lcov manipulation | Shell sed/awk scripts | `remove_from_coverage: ^2.0.0` | Regex-based, reliable, idempotent, CI-safe |
| Persistent key-value store | A custom Drift table for simple flags | `shared_preferences: ^2.5.5` (for first-launch flag only) | SharedPreferencesAsync is right for a boolean; Drift is right for structured data |
| Flutter error catching | try/catch around runApp | `FlutterError.onError` + `PlatformDispatcher.instance.onError` | These catch async and framework errors that try/catch misses entirely |
| GoRouter inside StatelessWidget | `final router = GoRouter(...)` as class field | `@riverpod GoRouter appRouter(...)` | Must be in Riverpod scope to watch auth state; class field breaks hot reload |
| Drift DB migration tests | Manual SQL comparison | `SchemaVerifier` from `drift_dev/api/migrations_native.dart` | Generates typed helpers, catches column-type mismatches, validates each step |

---

## Common Pitfalls

### Pitfall 1: Using sqlite3_flutter_libs directly

**What goes wrong:** `sqlite3_flutter_libs: ^0.5.24` (STACK.md version) no longer exists at that version in a working state. Version `^0.6.0+eol` is a stub that does nothing; the package is end-of-life.

**Why it happens:** STACK.md research (same day) referenced 0.5.24 but the package was since EOL'd.

**How to avoid:** Use `drift_flutter: ^0.3.0`. Do NOT add `sqlite3_flutter_libs` to pubspec.yaml. It will arrive transitively via `drift_flutter` in its correct EOL/stub form, and `drift_flutter` adds the actual `sqlite3: ^3.x` dependency that does the real work.

**Warning signs:** `pub get` warns about deprecated package; `flutter run` crashes on Android with SQLite not found.

### Pitfall 2: Wrong riverpod_annotation version

**What goes wrong:** Using `riverpod_annotation: ^3.3.2` (STACK.md) instead of `^4.0.3` causes a pub constraint conflict with `riverpod_generator: ^4.0.4` which requires `riverpod_annotation >=4.0.0`.

**How to avoid:** Use `riverpod_annotation: ^4.0.3` in pubspec.yaml.

**Warning signs:** `flutter pub get` exits with version conflict error mentioning `riverpod_annotation`.

### Pitfall 3: Not excluding generated files from the analyzer

**What goes wrong:** `flutter analyze` reports hundreds of errors in `*.g.dart` and `*.drift.dart` files. These are codegen artifacts, not your code.

**How to avoid:** Add `exclude` section to `analysis_options.yaml` (see Pattern 2).

**Warning signs:** `flutter analyze` output is thousands of lines; none of the errors are in your source files.

### Pitfall 4: Missing PRAGMA foreign_keys = ON in Drift

**What goes wrong:** `tripId` foreign keys don't enforce referential integrity. Deleting a `Trip` leaves orphan `TripPoints` rows silently. Coverage bugs appear in Phase 6+.

**How to avoid:** Add `await customStatement('PRAGMA foreign_keys = ON');` in `MigrationStrategy.beforeOpen`.

**Warning signs:** Rows accumulate in `trip_points` after a trip is deleted. No error is thrown.

### Pitfall 5: flutter build ios --release --no-codesign failing on CI

**What goes wrong:** iOS build fails because the macOS runner doesn't have a valid development team set. The error is "Provisioning profile..." or "No signing certificate found".

**How to avoid:** Use `--no-codesign` flag explicitly. This disables ALL signing. Build still validates the Xcode project compiles without errors. Do NOT use `--release` without `--no-codesign` if no certificates are present.

**Warning signs:** CI fails with Xcode signing errors.

### Pitfall 6: GoRouter created as a global constant

**What goes wrong:** `final router = GoRouter(...)` at top-level means: (a) no Riverpod access in `redirect`; (b) GoRouter persists across test runs leaking navigation state.

**How to avoid:** Create GoRouter inside a `@riverpod` provider (see Pattern 5).

**Warning signs:** `redirect` can't access providers; navigation state bleeds between widget tests.

### Pitfall 7: Missing WidgetsFlutterBinding.ensureInitialized()

**What goes wrong:** Any `await` in `main()` before `runApp()` (e.g., SharedPreferences initialization, Drift open) crashes with "ServicesBinding is not initialized."

**How to avoid:** Call `WidgetsFlutterBinding.ensureInitialized()` as the first line in `main()`.

### Pitfall 8: CI triggered on all branches (not just main)

**What goes wrong:** CI runs on feature branches that don't exist (solo dev — no branches). For a solo developer, adding `branches: [main]` keeps the CI log clean and billing low.

**How to avoid:** Trigger only on `push: branches: [main]` (already in Pattern 3).

### Pitfall 9: dart format --output write in CI

**What goes wrong:** Using `dart format --output write .` in CI silently formats files and exits 0 even when files were reformatted, giving false pass.

**How to avoid:** Use `dart format --set-exit-if-changed .` in CI (exits non-zero if any file would change).

---

## Code Examples

### Verified: Drift MigrationStrategy with foreign keys and WAL

```dart
// Source: https://drift.simonbinder.eu/migrations/
@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (Migrator m) async {
    await m.createAll();
  },
  onUpgrade: (Migrator m, int from, int to) async {
    // future: if (from < 2) { await m.addColumn(trips, trips.newColumn); }
  },
  beforeOpen: (OpenedDatabase details) async {
    await customStatement('PRAGMA foreign_keys = ON');
    await customStatement('PRAGMA journal_mode = WAL');
  },
);
```

### Verified: SchemaVerifier test pattern

```dart
// Source: https://drift.simonbinder.eu/migrations/tests/
import 'package:drift_dev/api/migrations_native.dart';
import 'package:test/test.dart';
import 'generated_migrations/schema.dart';
import '../../lib/core/db/app_database.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  test('database at v1 has correct schema', () async {
    final connection = await verifier.startAt(1);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 1);
    await db.close();
  });
}
```

### Verified: FlutterError global handler

```dart
// Source: https://docs.flutter.dev/testing/errors
FlutterError.onError = (FlutterErrorDetails details) {
  FlutterError.presentError(details);
  _log.severe('FlutterError', details.exception, details.stack);
};

PlatformDispatcher.instance.onError = (error, stack) {
  _log.severe('PlatformDispatcher.onError', error, stack);
  return true;
};
```

### Verified: remove_from_coverage CI snippet

```bash
# Source: https://pub.dev/packages/remove_from_coverage
dart pub run remove_from_coverage \
  -f coverage/lcov.info \
  -r '\.g\.dart$' \
  -r '\.freezed\.dart$' \
  -r '\.drift\.dart$' \
  -r 'test/generated_migrations'
```

### Verified: logging setup with kDebugMode gate

```dart
// Source: https://pub.dev/packages/logging
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

void setupLogging() {
  Logger.root.level = kDebugMode ? Level.ALL : Level.WARNING;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: [${record.loggerName}] ${record.message}');
  });
}
```

### Verified: StatefulShellRoute for future Phase 2 awareness

```dart
// Source: https://pub.dev/documentation/go_router/latest/ (StatefulShellRoute)
StatefulShellRoute.indexedStack(
  builder: (context, state, navigationShell) =>
      ScaffoldWithBottomNavBar(navigationShell: navigationShell),
  branches: [
    StatefulShellBranch(routes: [GoRoute(path: '/map', builder: ...)]),
    StatefulShellBranch(routes: [GoRoute(path: '/trips', builder: ...)]),
  ],
)
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `sqlite3_flutter_libs: ^0.5.24` | `drift_flutter: ^0.3.0` + `sqlite3: ^3.x` | mid-2025 | `sqlite3_flutter_libs` EOL'd; use drift_flutter wrapper |
| `riverpod_annotation: ^3.x` | `riverpod_annotation: ^4.0.3` | 2025 | Major version bump; generator requires 4.x |
| `flutter_lints` | `very_good_analysis: ^10.3.0` | (user decision) | Stricter rules; better Riverpod alignment |
| `SharedPreferences.getInstance()` | `SharedPreferencesAsync` API | 2024 | New async API recommended for new projects |
| `codec/codecov-action@v4` | `codecov/codecov-action@v5` | 2025 | v5 still current; v7 exists but v5 works |
| Flutter `>=3.24.0` (STACK.md) | Flutter `>=3.44.0` | May 2026 (Flutter 3.44 release) | Current stable is 3.44 / Dart 3.10 |
| GoRouter `routeInformationParser`/`routerDelegate` | `MaterialApp.router(routerConfig: router)` | go_router 5+ | New unified API |

**Deprecated/outdated in Phase 1 context:**
- `sqflite` and `drift_sqflite`: removed in favor of `drift_flutter` + native `sqlite3`.
- `provider` package: user decided not to use; use `flutter_riverpod` only.
- `flutter_lints`: replaced by `very_good_analysis`.
- `sqlite3_flutter_libs ^0.5.x`: EOL'd.

---

## Success Criteria Mapping

| # | Success Criterion | Artifact That Proves It | Command |
|---|------------------|------------------------|---------|
| 1 | `flutter analyze` + `dart format` pass in CI | `.github/workflows/ci.yml` → lint-and-test job | `flutter analyze --fatal-infos && dart format --set-exit-if-changed .` |
| 2 | `flutter test --coverage` + generated-file strip + Codecov upload | ci.yml coverage steps + Codecov dashboard showing badge | ci.yml steps 3-5 in lint-and-test job |
| 3 | iOS unsigned `.ipa` + Android debug `.apk` build green | `.github/workflows/ios-build.yml` → ios-build + android-build jobs | `flutter build ios --release --no-codesign` and `flutter build apk --debug` |
| 4 | Drift migration infra + SchemaVerifier tests pass | `drift_schemas/drift_schema_v1.json` + `test/generated_migrations/` + `test/core/db/migration_test.dart` | `flutter test test/core/db/migration_test.dart` |
| 5 | Empty app launches on iOS + Android without crashing | `lib/main.dart` + `lib/app.dart` + `lib/core/routing/app_router.dart` + platform manifests | `flutter run` (device) or CI build exits 0 |

---

## Open Questions

1. **FND-06: README with CI badges** — the REQUIREMENTS.md lists this. Phase 1 scope includes creating a slim `README.md` with project description and badge placeholders (Codecov, CI). This was not explicitly called out in the CONTEXT.md phase boundary but is a FND requirement. Planner should include a task for it.

2. **`drift_dev schema dump` path for split-table file organization** — since tables are split across 7 files in `core/db/tables/*.dart`, the schema dump command targets `app_database.dart` (the `@DriftDatabase` class file), not the individual table files. This is correct because `@DriftDatabase(tables: [...])` references all tables from the single annotated class. No ambiguity.

3. **`riverpod_annotation: ^4.0.3` vs STACK.md `^3.3.2`** — this discrepancy needs to be corrected in STACK.md if it's used as a reference elsewhere. The correct constraint is `^4.0.3`. This is a hard incompatibility with `riverpod_generator: ^4.0.4`.

4. **GitHub Codecov token setup** — the first CI run will fail the Codecov upload step until `CODECOV_TOKEN` is added to GitHub repo secrets. This requires creating a Codecov account, connecting it to the repo, and copying the token. This is a one-time human action, not a code task, but the planner should include it as a setup step.

---

## Sources

### Primary (HIGH confidence — fetched today 2026-07-02)

- `pub.dev/packages/very_good_analysis` — version 10.3.0, analysis_options.yaml format
- `pub.dev/packages/drift` — version 2.34.0
- `pub.dev/packages/drift_dev` — version 2.34.1+1
- `pub.dev/packages/drift_flutter` — version 0.3.0; depends on sqlite3_flutter_libs (EOL) + sqlite3 ^3.x
- `pub.dev/packages/sqlite3_flutter_libs` — version 0.6.0+eol (explicitly EOL'd, use drift_flutter)
- `pub.dev/packages/sqlite3` — version 3.3.4
- `pub.dev/packages/flutter_riverpod` — version 3.3.2
- `pub.dev/packages/riverpod_annotation` — version 4.0.3
- `pub.dev/packages/riverpod_generator` — version 4.0.4
- `pub.dev/packages/riverpod_lint` — version 3.1.4
- `pub.dev/packages/custom_lint` — version 0.8.1
- `pub.dev/packages/go_router` — version 17.3.0; StatefulShellRoute.indexedStack confirmed
- `pub.dev/packages/logging` — version 1.3.0
- `pub.dev/packages/logger` — version 2.7.0 (considered; chose `logging` instead)
- `pub.dev/packages/shared_preferences` — version 2.5.5; SharedPreferencesAsync recommended
- `pub.dev/packages/build_runner` — version 2.15.0
- `pub.dev/packages/remove_from_coverage` — version 2.0.0; `-r` regex syntax confirmed
- `pub.dev/packages/permission_handler` — version 12.0.3
- `pub.dev/packages/mocktail` — version 1.0.5
- `pub.dev/packages/path_provider` — version 2.1.6; min Android SDK 24, iOS 13
- `docs.flutter.dev/release/whats-new` — Flutter 3.44 stable (May 2026), Dart 3.10
- `docs.flutter.dev/reference/supported-platforms` — iOS min 13, Android min SDK 24
- `docs.flutter.dev/release/release-notes/release-notes-3.44.0` — Dart 3.10 bundled
- `drift.simonbinder.eu/setup/` — driftDatabase() function, drift_flutter dependency list
- `drift.simonbinder.eu/migrations/` — MigrationStrategy API, make-migrations command
- `drift.simonbinder.eu/migrations/tests/` — SchemaVerifier API, schema generate command, startAt/migrateAndValidate
- `drift.simonbinder.eu/migrations/exports/` — `dart run drift_dev schema dump <db_file> <dir>/` command
- `docs.flutter.dev/testing/errors` — FlutterError.onError + PlatformDispatcher.instance.onError pattern
- `developer.apple.com/documentation/bundleresources/information_property_list` — iOS plist keys
- `developer.android.com/develop/sensors-and-location/location/permissions` — Android location permissions + foregroundServiceType
- `developer.android.com/develop/connectivity/bluetooth/bt-permissions` — Android 12+ Bluetooth permissions
- `developer.android.com/develop/sensors-and-location/sensors/sensors_motion` — ACTIVITY_RECOGNITION permission
- `github.com/marketplace/actions/flutter-action` — subosito/flutter-action@v2 usage
- `github.com/marketplace/actions/codecov` — codecov/codecov-action@v5 (v7 is latest)
- `pub.dev/documentation/go_router/latest/topics/Configuration-topic.html` — ShellRoute + StatefulShellRoute API

### Secondary (MEDIUM confidence)

- `docs.flutter.dev/deployment/cd` — `flutter build ios --release --no-codesign --config-only` confirmation

---

## Metadata

**Confidence breakdown:**
- Standard stack (versions): HIGH — all versions fetched from pub.dev today
- Architecture patterns: HIGH — based on official Drift + go_router + Flutter docs
- Drift schema (table definitions): HIGH — Drift table DSL is stable; column types verified
- Permission manifest entries: HIGH — Apple and Android official docs fetched today
- CI workflow shape: HIGH — GitHub Actions + flutter-action + codecov patterns fetched today
- Pitfalls: HIGH — most derived from official EOL notices and API docs

**Research date:** 2026-07-02
**Valid until:** 2026-08-01 (packages are actively releasing; re-verify drift/riverpod versions before execution)
