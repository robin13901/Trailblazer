---
plan: "01"
name: "flutter-project-bootstrap"
wave: 1
depends_on: []
files_modified:
  - "pubspec.yaml"
  - "analysis_options.yaml"
  - "build.yaml"
  - ".gitignore"
  - "lib/main.dart"
  - "lib/app.dart"
  - "lib/core/routing/app_router.dart"      # stub, replaced by Plan 03
  - "lib/core/logging/app_logger.dart"      # stub, replaced by Plan 04
  - "lib/features/onboarding/.gitkeep"
  - "lib/features/map/.gitkeep"
  - "lib/features/trips/.gitkeep"
  - "lib/features/vehicles/.gitkeep"
  - "lib/features/regions/.gitkeep"
  - "lib/features/settings/.gitkeep"
  - "tool/.gitkeep"
autonomous: true
requirements: ["FND-01", "FND-02", "FND-07"]
must_haves:
  truths:
    - "`flutter analyze` exits 0 on a freshly-generated project with very_good_analysis lints."
    - "`dart format --set-exit-if-changed .` exits 0."
    - "`flutter run` (or `flutter build apk --debug`) produces a runnable empty app that mounts `ProviderScope` at the root."
    - "The lib/ tree follows feature-first layout (`lib/features/*`, `lib/core/*`) with placeholder directories in place."
  artifacts:
    - path: "pubspec.yaml"
      provides: "Pinned dependency set matching RESEARCH.md §Standard Stack"
      contains: "drift_flutter: ^0.3.0"
    - path: "analysis_options.yaml"
      provides: "very_good_analysis include + generated-file excludes + custom_lint plugin"
      contains: "package:very_good_analysis/analysis_options.yaml"
    - path: "lib/main.dart"
      provides: "Entry point with ProviderScope + WidgetsFlutterBinding.ensureInitialized + setupLogging() call + error hooks"
    - path: "lib/app.dart"
      provides: "MaterialApp.router wired to appRouterProvider"
    - path: "build.yaml"
      provides: "drift_dev codegen target for lib/core/db/app_database.dart"
  key_links:
    - from: "lib/main.dart"
      to: "lib/app.dart"
      via: "runApp(ProviderScope(child: App()))"
      pattern: "ProviderScope.*App\\(\\)"
    - from: "lib/app.dart"
      to: "lib/core/routing/app_router.dart"
      via: "ref.watch(appRouterProvider)"
      pattern: "appRouterProvider"
---

<objective>
Create the Flutter project skeleton for `auto_explore`: pinned `pubspec.yaml`, `very_good_analysis` lints, feature-first `lib/` tree, a runnable `main.dart` that mounts `ProviderScope` with logging + error hooks, and stub files that later plans in Wave 2 will replace. After this plan, `flutter analyze` + `dart format --set-exit-if-changed .` + `flutter build apk --debug` must all pass locally.
</objective>

<context>
- **Working directory:** `C:\SAPDevelop\Privat\Auto-Explore-App` (project root — git-initialized, empty except `.planning/`).
- **Flutter stable:** 3.44 / Dart 3.10. See `.planning/phases/01-scaffolding/01-RESEARCH.md` §Standard Stack (lines 22-63).
- **Full pubspec.yaml content:** RESEARCH.md lines 64-125.
- **analysis_options.yaml pattern:** RESEARCH.md lines 237-266.
- **main.dart wiring pattern:** RESEARCH.md lines 720-752.
- **app.dart pattern:** RESEARCH.md lines 621-639.
- **Folder structure:** RESEARCH.md lines 147-204.
- **CRITICAL — package version corrections vs STACK.md:** use `drift_flutter: ^0.3.0` (NOT `sqlite3_flutter_libs`), `riverpod_annotation: ^4.0.3` (NOT 3.3.2), `custom_lint: ^0.8.1` (NOT 0.7.5). RESEARCH.md lines 52-63 + Pitfall 1 (lines 903-912).
- **Naming:** Dart package name must be `auto_explore` (snake_case). The repo folder `Auto-Explore-App` stays as-is; only the pubspec `name:` matters.
- **Org id:** `de.autoexplore` (used as iOS bundle prefix + Android applicationId).
</context>

<tasks>

<task id="1.1" type="auto">
  <name>Run `flutter create` and reset the counter-app boilerplate</name>
  <files>
    - `pubspec.yaml` (overwritten in Task 1.2)
    - `ios/`, `android/` scaffolding (created by flutter create)
    - `lib/main.dart` (reset in Task 1.3)
    - `test/widget_test.dart` (reset in Task 1.3)
  </files>
  <action>
    Run from `C:\SAPDevelop\Privat\Auto-Explore-App`:

    ```bash
    flutter create \
      --org de.autoexplore \
      --platforms ios,android \
      --template app \
      --project-name auto_explore \
      .
    ```

    Note the `.` at the end — creates into the current directory. If `flutter create` refuses because the directory isn't empty (the `.planning/` folder and `.git/` are here), use `--overwrite` and answer any prompts to keep planning + git.

    After creation:
    - Delete the counter-app example code from `lib/main.dart` (Task 1.3 rewrites it).
    - Delete the default `test/widget_test.dart` content (Task 1.3 rewrites it).
    - Verify `ios/Runner.xcworkspace` and `android/app/build.gradle` exist.
  </action>
  <verify>
    ```bash
    test -f pubspec.yaml && \
    test -f ios/Runner.xcworkspace/contents.xcworkspacedata && \
    test -f android/app/build.gradle && \
    grep -q 'name: auto_explore' pubspec.yaml
    ```
  </verify>
  <done>iOS + Android platform folders exist; `pubspec.yaml` has `name: auto_explore`.</done>
</task>

<task id="1.2" type="auto">
  <name>Replace pubspec.yaml with the pinned Phase 1 dependency set</name>
  <files>
    - `pubspec.yaml`
  </files>
  <action>
    Overwrite `pubspec.yaml` with the following EXACT content (do not modify versions — they are verified in RESEARCH.md):

    ```yaml
    name: auto_explore
    description: "Trailblazer — GPS trip tracker that paints roads you have driven onto an offline map."
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

    Then run:

    ```bash
    flutter pub get
    ```

    If pub get fails on a version, DO NOT relax the constraint — instead read the error, and if truly needed re-check RESEARCH.md lines 22-63 for the corrected version.
  </action>
  <verify>
    ```bash
    flutter pub get
    grep -q "drift_flutter: \^0.3.0" pubspec.yaml
    grep -q "riverpod_annotation: \^4.0.3" pubspec.yaml
    grep -q "custom_lint: \^0.8.1" pubspec.yaml
    ! grep -q "sqlite3_flutter_libs" pubspec.yaml
    ```
  </verify>
  <done>`flutter pub get` exits 0; pubspec contains the corrected versions and does NOT list `sqlite3_flutter_libs` as a direct dep.</done>
</task>

<task id="1.3" type="auto">
  <name>Create analysis_options.yaml, build.yaml, folder skeleton, and wired lib/main.dart + lib/app.dart with stubs</name>
  <files>
    - `analysis_options.yaml`
    - `build.yaml`
    - `.gitignore` (append entries)
    - `lib/main.dart`
    - `lib/app.dart`
    - `lib/core/routing/app_router.dart` (stub — replaced by Plan 03)
    - `lib/core/logging/app_logger.dart` (stub — replaced by Plan 04)
    - `lib/features/{map,trips,vehicles,regions,settings,onboarding}/.gitkeep`
    - `tool/.gitkeep`
    - `test/widget_test.dart`
  </files>
  <action>

    **`analysis_options.yaml`:**

    ```yaml
    include: package:very_good_analysis/analysis_options.yaml

    analyzer:
      exclude:
        - "**/*.g.dart"
        - "**/*.freezed.dart"
        - "**/*.drift.dart"
        - "test/generated_migrations/**"
      plugins:
        - custom_lint

    linter:
      rules:
        # App (not published library): no public API docs required.
        public_member_api_docs: false
        # Drift table DSL lines exceed 80 chars routinely.
        lines_longer_than_80_chars: false
    ```

    **`build.yaml`:**

    ```yaml
    targets:
      $default:
        builders:
          drift_dev:
            options:
              databases:
                app_database: lib/core/db/app_database.dart
    ```

    **Append to `.gitignore`** (idempotent — only add lines not already present):

    ```
    # Generated code
    **/*.g.dart
    **/*.freezed.dart
    **/*.drift.dart
    /test/generated_migrations/

    # Coverage
    /coverage/

    # Flutter build artifacts (belt-and-braces; flutter create adds most)
    /build/
    .dart_tool/
    ```

    **`lib/core/logging/app_logger.dart`** (STUB — Plan 04 replaces this):

    ```dart
    /// Stub — real implementation added in Plan 04.
    void setupLogging() {
      // no-op stub. Plan 04 wires the real logger.
    }
    ```

    **`lib/core/routing/app_router.dart`** (STUB — Plan 03 replaces this):

    ```dart
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:go_router/go_router.dart';

    /// Stub — real implementation added in Plan 03.
    /// Riverpod provider so `lib/app.dart` can `ref.watch(appRouterProvider)`.
    final appRouterProvider = Provider<GoRouter>((ref) {
      return GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(
              body: Center(child: Text('Auto-Explore')),
            ),
          ),
        ],
      );
    });
    ```

    **`lib/app.dart`:**

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

    **`lib/main.dart`:**

    ```dart
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'app.dart';
    import 'core/logging/app_logger.dart';

    void main() {
      WidgetsFlutterBinding.ensureInitialized();
      setupLogging();
      runApp(const ProviderScope(child: App()));
    }
    ```

    (Plan 04 will add the `FlutterError.onError` and `PlatformDispatcher.instance.onError` hooks to this file.)

    **`test/widget_test.dart`:**

    ```dart
    import 'package:auto_explore/app.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:flutter_test/flutter_test.dart';

    void main() {
      testWidgets('App boots without crashing', (tester) async {
        await tester.pumpWidget(const ProviderScope(child: App()));
        await tester.pumpAndSettle();
        expect(find.text('Auto-Explore'), findsOneWidget);
      });
    }
    ```

    **Empty placeholder folders** — Flutter/Git ignore empty directories, so drop a `.gitkeep` in each:

    ```bash
    mkdir -p lib/features/map lib/features/trips lib/features/vehicles \
             lib/features/regions lib/features/settings lib/features/onboarding \
             lib/core/db lib/core/errors tool
    touch lib/features/map/.gitkeep lib/features/trips/.gitkeep \
          lib/features/vehicles/.gitkeep lib/features/regions/.gitkeep \
          lib/features/settings/.gitkeep lib/features/onboarding/.gitkeep \
          tool/.gitkeep
    ```
  </action>
  <verify>
    ```bash
    flutter analyze --fatal-infos
    dart format --set-exit-if-changed .
    flutter test test/widget_test.dart
    ```
    All three commands must exit 0.
  </verify>
  <done>
    - `flutter analyze` exits 0 with zero errors/warnings/infos.
    - `dart format --set-exit-if-changed .` exits 0.
    - `flutter test` passes the smoke test.
    - Directory tree matches RESEARCH.md §Recommended Project Structure.
  </done>
</task>

</tasks>

<verification>
Run at the project root and confirm all exit 0:

```bash
flutter pub get
flutter analyze --fatal-infos
dart format --set-exit-if-changed .
flutter test
flutter build apk --debug     # optional local sanity — CI will do this in Plan 06
```
</verification>

<must_haves>
Contributes to phase Success Criterion 1 (analyze + format pass — foundation only; CI enforcement lands in Plan 06). Provides the compilable Flutter shell that Plans 02–05 build on top of.
</must_haves>
