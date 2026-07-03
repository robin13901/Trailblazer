---
phase: 01
name: scaffolding
status: human_needed
verified_at: 2026-07-03
verifier: gsd-verifier
score: 5/5 automated must_haves verified; 2 items require human confirmation
human_verification:
  - test: "Real-device launch on physical iOS device and physical Android device"
    expected: "App boots, no permission-string related crash on first launch, splash to onboarding screen renders"
    why_human: "SC5 verbatim requires real device launch. The widget_test only runs in a Dart test VM (no platform channels, no real UIApplicationDelegate/MainActivity), so it cannot detect Info.plist purpose-string omissions or manifest FGS mis-declarations."
  - test: "Trigger the iOS unsigned build workflow at least once via workflow_dispatch"
    expected: "GitHub Actions iOS Build workflow completes green on main; ios-unsigned-build artifact is produced"
    why_human: "The ios-build.yml workflow is workflow_dispatch-only, so it does not run on push. Success is only observable after a human triggers it from the Actions tab."
---

# Phase 1 Verification: Scaffolding

## Summary

Phase 1 (Scaffolding) is structurally complete and automatically verifiable. All 5 success criteria are met at the artifact/wiring level, all 14 tests pass locally, flutter analyze --fatal-infos returns clean, and every one of the 13 mapped requirements (FND-01 through FND-11, QUA-03, QUA-05) has a concrete code artifact backing it. The two deviations from the original ROADMAP wording (iOS moved to workflow_dispatch; Android debug builds moved to the local dev machine) are cleanly documented in SUMMARY, README.md, docs/ARCHITECTURE.md, and STATE.md, and the phase goal (foundation is production-quality and blocks nothing downstream) is met by the delivered scaffolding.

Status is human_needed rather than passed because two items are inherently non-automatable in this environment: (1) real-device iOS + Android launch verification of SC5, and (2) at-least-one successful execution of the manually-triggered iOS build workflow. Neither is a code gap.

Score: 5/5 automated must-haves verified. 2 items awaiting physical/human confirmation.

## Success Criteria Results

### SC1 - flutter analyze (very_good_analysis) + dart format --set-exit-if-changed in CI

- Status: VERIFIED
- Evidence:
  - .github/workflows/ci.yml:3-8 - triggers on push:main, pull_request:main, workflow_dispatch.
  - .github/workflows/ci.yml:41-49 - dart format --set-exit-if-changed (excludes generated files).
  - .github/workflows/ci.yml:51-52 - flutter analyze --fatal-infos.
  - analysis_options.yaml:1 - includes package very_good_analysis/analysis_options.yaml.
  - analysis_options.yaml:3-8 - excludes generated files (.g.dart, .freezed.dart, .drift.dart, test/generated_migrations).
  - analysis_options.yaml does NOT declare an analyzer.plugins section (custom_lint deliberately absent - matches CONTEXT deviation note; pubspec.yaml:39-41 documents the constraint conflict with drift_dev 2.34).
  - Local run of flutter analyze --fatal-infos returned "No issues found! (ran in 106.6s)".
  - Local run of dart format --set-exit-if-changed on scoped lib/ + test/ files returned "Formatted 26 files (0 changed) in 0.19 seconds. exit=0".
- Notes: Both steps are wired to the correct triggers and both return green locally. Codegen (build_runner build --delete-conflicting-outputs and drift_dev schema generate) precedes analyze/format in CI (ci.yml:32-39) - matches the documented deviation about fresh-checkout codegen ordering.

### SC2 - flutter test --coverage, strip generated files, upload to Codecov

- Status: VERIFIED
- Evidence:
  - .github/workflows/ci.yml:54-55 - flutter test --coverage.
  - .github/workflows/ci.yml:57-64 - remove_from_coverage strips .g.dart, .freezed.dart, .drift.dart, and test/generated_migrations paths.
  - .github/workflows/ci.yml:66-71 - codecov/codecov-action@v5 with token from CODECOV_TOKEN secret and files ./coverage/lcov.info.
  - pubspec.yaml:33 - remove_from_coverage 2.0.0 in dev_dependencies.
  - codecov.yml - hard-gate disabled per CONTEXT decision; ignore list mirrors the strip regex.
  - Local run of flutter test returned "All tests passed!" (14 tests across 6 files).
- Notes: Presence of CODECOV_TOKEN secret cannot be inspected from the working tree; assumed to be configured in GitHub repo settings (README badge points to a live Codecov project, so token is presumed valid).

### SC3 - iOS unsigned .ipa + Android debug .apk builds green in CI [DEVIATED]

- Status: VERIFIED WITH DEVIATION (goal met via adjusted mechanism)
- Evidence for iOS branch:
  - .github/workflows/ios-build.yml:8-9 - trigger is workflow_dispatch only (per CONTEXT deviation - deliberate user-directed cost decision).
  - .github/workflows/ios-build.yml:29-30 - flutter build ipa --no-codesign.
  - .github/workflows/ios-build.yml:35-38 - uploads build/ios/archive/*.xcarchive (path change matches CONTEXT deviation - unsigned builds do not produce a real .ipa).
- Evidence for Android branch:
  - Android debug build is not run in CI - it runs locally on the dev machine per user directive.
  - README.md:75-76 - quickstart shows flutter build apk --debug under "Android debug APK (run locally - Android is NOT built in CI)".
  - README.md:89 - CI section explicitly documents the deviation.
  - docs/ARCHITECTURE.md:118 - same rationale documented in architecture doc.
  - docs/ARCHITECTURE.md:145 - includes "Confirm flutter build apk --debug on a Windows host..." as a smoke-test item.
  - README.md:42-43 - prerequisites list Xcode 15+ and Android SDK + cmdline-tools.
- Notes: The original SC3 wording (iOS unsigned .ipa and Android debug .apk build green in CI on the main branch) is technically NOT met verbatim - iOS is manual-trigger only and Android is not in CI at all. The phase goal (foundation is production-quality and blocks nothing downstream) IS met because both builds are demonstrably achievable via clean, documented paths. The deviation is a deliberate solo-dev / macOS-runner-cost decision, comprehensively documented in SUMMARY.md for phases 06 + 07, README.md, docs/ARCHITECTURE.md, and .planning/STATE.md. Execution of the manual iOS workflow needs a one-time human trigger (see human_verification item 2).

### SC4 - App DB opens with Drift migration infrastructure + SchemaVerifier tests pass

- Status: VERIFIED
- Evidence:
  - lib/core/db/app_database.dart:13-23 - DriftDatabase annotation with tables list [Trips, TripPoints, DrivenWayIntervals, Vehicles, BtFingerprints, CoverageCache, AppPrefs] - all 7 tables registered.
  - lib/core/db/tables/ - 7 table files present: trips_table.dart, trip_points_table.dart, driven_intervals_table.dart, vehicles_table.dart, bt_fingerprints_table.dart, coverage_cache_table.dart, app_prefs_table.dart.
  - lib/core/db/app_database.dart:28 - schemaVersion returns 1.
  - lib/core/db/app_database.dart:31-44 - MigrationStrategy with onCreate, onUpgrade (v1-to-v2 stub), and beforeOpen executing PRAGMA foreign_keys = ON and PRAGMA journal_mode = WAL.
  - drift_schemas/drift_schema_v1.json - schema snapshot present.
  - test/generated_migrations/schema.dart + schema_v1.dart - generated migration helpers (from drift_dev schema generate).
  - test/core/db/migration_test.dart:1-16 - uses SchemaVerifier(GeneratedHelper()), startAt(1), migrateAndValidate(db, 1).
  - test/core/db/app_database_open_test.dart - verifies all 7 table names in sqlite_master + PRAGMA foreign_keys = 1 post-beforeOpen.
  - Local flutter test test/core/db/ passed 3 tests: (a) AppDatabase opens in memory with all 7 tables, (b) database at v1 has correct schema, (c) foreign_keys pragma is ON after beforeOpen.
- Notes: Only one schema version exists (v1), so SchemaVerifier currently validates one step - this is correct for Phase 1. The plan explicitly reserves v1-to-v2 migration work for later phases. Framework is production-quality: every future migration will require a schema snapshot + SchemaVerifier test (locked in by QUA-03).

### SC5 - Empty app launches on iOS + Android with declared purpose strings and FGS type [POSSIBLY human_needed]

- Status: AUTOMATED CHECKS VERIFIED - real-device launch requires human confirmation
- Evidence (iOS):
  - ios/Runner/Info.plist:49-60 - 6 required NSUsageDescription keys:
    - NSLocationWhenInUseUsageDescription
    - NSLocationAlwaysAndWhenInUseUsageDescription
    - NSLocationAlwaysUsageDescription
    - NSMotionUsageDescription
    - NSBluetoothAlwaysUsageDescription
    - NSBluetoothCentralUsageDescription
  - ios/Runner/Info.plist:61-65 - UIBackgroundModes array with location + bluetooth-central.
- Evidence (Android):
  - android/app/src/main/AndroidManifest.xml:4-32 - 12 permissions present (exceeds the 10-permission floor in the plan): ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION, ACCESS_BACKGROUND_LOCATION, FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION, ACTIVITY_RECOGNITION, BLUETOOTH (maxSdk 30), BLUETOOTH_ADMIN (maxSdk 30), BLUETOOTH_SCAN, BLUETOOTH_CONNECT, POST_NOTIFICATIONS, WAKE_LOCK.
  - android/app/src/main/AndroidManifest.xml:69-73 - service element android:name=".LocationRecordingService" with android:foregroundServiceType="location" present in application block.
- Evidence (Flutter boot):
  - lib/main.dart:11-30 - WidgetsFlutterBinding.ensureInitialized(); setupLogging(); FlutterError.onError hook; PlatformDispatcher.instance.onError hook returning true; runApp(const ProviderScope(child: App())).
  - test/widget_test.dart:1-19 - boot smoke test: pumps ProviderScope(child: App()), waits for splash + async prefs read, asserts "Welcome to Auto-Explore" (onboarding first-launch screen) is visible.
  - Local flutter test test/widget_test.dart - passes.
- Notes: All manifest / plist / runtime-boot artifacts exist and are correctly wired. The widget test verifies "app builds a tree without throwing in a test VM" - it cannot exercise the real UIApplicationDelegate/MainActivity boot path, so an OS-level purpose-string or FGS-type mismatch would not surface here. See human_verification item 1 - a one-time real-device install (iOS + Android) is needed to close SC5 with certainty.

## Requirement Coverage (13 total)

| REQ-ID | Description | Primary artifact | Status |
|--------|-------------|------------------|--------|
| FND-01 | Flutter project skeleton (iOS + Android only), feature-first structure | lib/features/{map,onboarding,regions,settings,trips,vehicles}/, lib/core/{db,errors,logging,routing}/, tool/.gitkeep, pubspec.yaml | PASS |
| FND-02 | very_good_analysis + dart format --set-exit-if-changed enforced in CI | analysis_options.yaml:1, pubspec.yaml:38, .github/workflows/ci.yml:41-52 | PASS |
| FND-03 | GitHub Actions runs flutter analyze + flutter test --coverage on push/PR | .github/workflows/ci.yml:3-7, 51-55 | PASS |
| FND-04 | Codecov integration; generated files stripped before upload | .github/workflows/ci.yml:57-71, codecov.yml, pubspec.yaml:33 | PASS |
| FND-05 | GitHub Actions iOS build workflow produces installable .ipa (unsigned initially) | .github/workflows/ios-build.yml:1-39 (deviated to workflow_dispatch; artifact is .xcarchive - documented) | PASS (deviated) |
| FND-06 | README with project description, architecture summary, build/test/CI badges | README.md:1-8 (badges: CI, iOS Build, codecov, Flutter, Dart, very_good_analysis), docs/ARCHITECTURE.md | PASS |
| FND-07 | Riverpod 3.x sole state-management; DI via provider composition, no .instance singletons | pubspec.yaml:17 (flutter_riverpod 3.3.2), lib/main.dart:29 (ProviderScope), lib/app.dart:5-15 (ConsumerWidget + ref.watch), lib/core/routing/app_router.dart:20-38 (router as Provider of GoRouter) | PASS |
| FND-08 | Drift App DB scaffolded with migration infra + SchemaVerifier tests | lib/core/db/app_database.dart, drift_schemas/drift_schema_v1.json, test/core/db/migration_test.dart, test/generated_migrations/schema.dart | PASS |
| FND-09 | go_router configured for typed navigation | pubspec.yaml:18 (go_router 17.3.0), lib/core/routing/app_router.dart:20-38 (3 routes: /splash, /onboarding, /), lib/app.dart:11-14 (MaterialApp.router), test/core/routing/app_router_test.dart | PASS |
| FND-10 | Logging, error boundaries, typed exceptions in lib/core/ | lib/core/logging/app_logger.dart (setupLogging), lib/core/errors/domain_error.dart (sealed DomainError + 5 subtypes), lib/core/errors/result.dart, lib/main.dart:16-27 (FlutterError + PlatformDispatcher hooks) | PASS |
| FND-11 | iOS Info.plist purpose strings + Android manifest foregroundServiceType location from day one | ios/Runner/Info.plist:49-65, android/app/src/main/AndroidManifest.xml:4-32, 69-73 | PASS |
| QUA-03 | Drift migration tests use SchemaVerifier for every step | test/core/db/migration_test.dart:8-15 (uses SchemaVerifier(GeneratedHelper()) + startAt + migrateAndValidate) | PASS |
| QUA-05 | iOS + Android debug builds succeed in CI | Deviated - see SC3. iOS in CI (ios-build.yml, manual trigger); Android debug documented as local path (README.md:75-76, 89; docs/ARCHITECTURE.md:118, 145) | PASS (deviated) |

All 13 requirements have primary artifacts. FND-05 and QUA-05 are marked "deviated" because they meet the goal via the documented adjusted mechanism rather than the verbatim ROADMAP wording - the deviations are explicitly captured in SUMMARY.md for phases 06 + 07 and in .planning/STATE.md.

## Human Verification Checklist

The following two items cannot be verified from the working tree and require a one-time human action:

### 1. Real-device iOS + Android launch (SC5 / FND-11)

- Test: Install a debug build on a physical iOS device (flutter run from a Mac via Xcode) AND on a physical Android device (flutter install after flutter build apk --debug locally).
- Expected: App boots to splash then onboarding "Welcome to Auto-Explore" screen with no OS-level crash. No purpose-string or FGS-type mis-declaration is surfaced by the OS log (console.app on iOS, adb logcat on Android). Permission dialogs are not yet requested (permissions are wired in later phases), so the boot should be clean.
- Why human: The flutter_test VM does not execute real UIApplicationDelegate / MainActivity initialization, so it cannot detect Info.plist or AndroidManifest issues that manifest at OS load time.

### 2. iOS Build workflow - one-time workflow_dispatch execution (SC3 / FND-05)

- Test: From the GitHub Actions tab, click "Run workflow" on the iOS Build workflow against main.
- Expected: Workflow completes green; ios-unsigned-build artifact is uploaded and contains a *.xcarchive under build/ios/archive/.
- Why human: workflow_dispatch-only workflows do not run on push, so success is only observable after a human trigger. All local ingredients (Flutter version, plugin registration, plist purpose strings) look correct, so this is expected to pass on first trigger - but must be confirmed.

## Gaps

None - no code gaps were found.

The two human_needed items above are not gaps in delivered scaffolding; they are inherent limits of what static + widget-test verification can prove in a Windows working tree with no macOS build agent, no attached mobile device, and no live GitHub Actions run.

---

Verified: 2026-07-03
Verifier: Claude (gsd-verifier)
