# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-02)

**Core value:** When I open the map, I immediately see the roads I've already driven, painted onto the world — and that view keeps pulling me back to explore more.
**Current focus:** Phase 1 — Scaffolding

## Current Position

Phase: 1 of 11 (Scaffolding)
Plan: Plans 01, 02, 03, 04, 05, 06 committed (6 of 7 in current phase)
Status: In progress (Plan 07 remaining in phase)
Last activity: 2026-07-03 — Completed 01-06 github-actions-ci; CI run 28650295975 green (1m 47s); Codecov upload accepted

Progress: [█░░░░░░░░░] ~7.8% (6/77 est. plans overall — Phase 1 sizing: 7 plans; other phases TBD)

## Performance Metrics

**Velocity:**
- Total plans completed: 6 (01-01, 01-02, 01-03, 01-04, 01-05, 01-06)
- Average duration: ~21 min
- Total execution time: ~2.1 hours (est.)

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-scaffolding | 6 | ~127 min | ~21 min |

**Recent Trend:**
- Last 6 plans: 01-01 (18 min), 01-05 (~2 min), 01-02, 01-03 (parallel Wave 2), 01-04 (25 min), 01-06 (~17 min: 7 min exec + ~10 min interactive checkpoint)
- Trend: infra plans on target; checkpoint-heavy plans still land under 20 min

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Key locked-in decisions affecting current work:

- Roadmap: `flutter_background_geolocation` chosen; accept future Android release-license cost (~USD 400–1200) if App Store publication happens.
- Roadmap: OSM admin levels 2/4/6/8/9/10 (including Stadtteil + Ortsteil) in scope for v1.
- Roadmap: OSM extract delivered via first-launch Wi-Fi download (~200 MB) — no bundling.
- Roadmap: Two spike gates open — G1 (P2 Liquid Glass over MapLibre) and G2 (P7 `feature-state` availability).
- **Plan 01-01 (2026-07-03):** Dropped `custom_lint ^0.8.1` and `riverpod_lint ^3.1.4` from pubspec — irresolvable analyzer conflict with `drift_dev 2.34` (analyzer ^13 vs ^8). Re-introduce once upstream custom_lint releases analyzer 13-compatible build.
- **Plan 01-01 (2026-07-03):** Local Flutter toolchain upgraded 3.38.1 → 3.44.4 (stable channel) to satisfy pubspec constraint `>=3.44.0`.
- **Plan 01-01 (2026-07-03):** All imports use `package:auto_explore/…` prefix (very_good_analysis `always_use_package_imports`). Pubspec deps alphabetized (`sort_pub_dependencies`).
- **Plan 01-02 (2026-07-03):** FK cascade policies locked: `trip_points -> trips` CASCADE; `driven_intervals -> trips` SET NULL (coverage survives trip loss); `bt_fingerprints -> vehicles` CASCADE.
- **Plan 01-02 (2026-07-03):** `AppDatabase` constructor takes optional `QueryExecutor` for test-time `NativeDatabase.memory()` injection.
- **Plan 01-02 (2026-07-03):** `test/generated_migrations/` stays gitignored; `drift_schemas/drift_schema_v1.json` is the committed source of truth. CI (Plan 06) must run `dart run drift_dev schema generate drift_schemas/ test/generated_migrations/` before `flutter test`.
- **Plan 01-02 (2026-07-03):** MigrationStrategy PRAGMAs (`foreign_keys=ON`, `journal_mode=WAL`) live in `beforeOpen` — SQLite `foreign_keys` is per-connection and must be re-applied on every open.
- **Plan 01-02 (2026-07-03):** `coverage_cache` and `app_prefs` use business-key PKs (`region_id`, `key`) — no synthetic `id`. Domain uniqueness makes an extra index wasteful.
- **Plan 01-05 (2026-07-03):** Foreground-service class in AndroidManifest is `.LocationRecordingService` (placeholder). Phase 3 must rebind `android:name` to `flutter_background_geolocation`'s real service class before the FGS starts.
- **Plan 01-05 (2026-07-03):** Skipped `NSBluetoothPeripheralUsageDescription` — deprecated; app is central-only.
- **Plan 01-05 (2026-07-03):** No `minSdkVersion` bump — permissions are gated via `maxSdkVersion` attributes + runtime prompts (Phase 3).
- **Plan 01-04 (2026-07-03):** `FlutterError.onError` + `PlatformDispatcher.instance.onError` both funnel through `DomainError.wrap` and log `severe`. `PlatformDispatcher` returns `true` to prevent OS-level crash (dev-only; matches CONTEXT.md "no remote crash reporting").
- **Plan 01-04 (2026-07-03):** Sealed `DomainError` covers four required categories (DB / Storage / Permission / Network) + `UnknownError` catch-all. Downstream phases must wrap non-DomainError throwables at boundaries via `DomainError.wrap()`.
- **Plan 01-04 (2026-07-03):** `Result<T>` (Ok/Err) is the return type for repositories/use-cases where failure is data, not an exception. Use `when()` fold for exhaustive pattern matching.
- **Plan 01-04 (2026-07-03):** Logger level gate: `Level.ALL` in debug via `dart:developer.log()`, `Level.WARNING` in release via `debugPrint`. Plain-text format. No remote sink (dev-only per CONTEXT.md).
- **Plan 01-04 (2026-07-03):** `DomainError.toString()` retains `runtimeType` for diagnostic clarity in logs; the required `no_runtimetype_tostring` ignore is documented inline.
- **Plan 01-03 (2026-07-03):** `appRouterProvider` and `onboardingFlagRepositoryProvider` shipped as plain `Provider<T>` — no `@Riverpod` codegen. Consistent with the Plan 01-01 codegen-off decision.
- **Plan 01-03 (2026-07-03):** Onboarding gating implemented inside `SplashScreen` (microtask reads `SharedPreferencesAsync`, then `context.go`), NOT a top-level `GoRouter.redirect`. Rationale: keeps the router synchronous, prevents re-reads on every navigation.
- **Plan 01-03 (2026-07-03):** Added `shared_preferences_platform_interface: ^2.4.2` as `dev_dependency` so tests can install `InMemorySharedPreferencesAsync` without hitting a platform channel.
- **Plan 01-03 (2026-07-03):** `onboarding_done` prefs key exposed as public `OnboardingFlagRepository.prefsKey` for future test/debug parity.
- **Plan 01-06 (2026-07-03):** CI codegen (build_runner + drift_dev schema generate) runs BEFORE `dart format` and `flutter analyze` — analyzer needs `.g.dart` and migration helpers, which are gitignored and don't exist on fresh CI checkouts.
- **Plan 01-06 (2026-07-03):** iOS build (`flutter build ipa --no-codesign`) is manual-trigger only (`workflow_dispatch`) — saves macOS runner minutes. Android debug builds happen locally on the dev machine, not in CI.
- **Plan 01-06 (2026-07-03):** iOS artifact is `build/ios/archive/*.xcarchive`, not `.ipa` — unsigned builds don't produce a real .ipa.

### Pending Todos

- **Chore (post-Phase 1):** Re-add `custom_lint` + `riverpod_lint` when a `custom_lint` release supports `analyzer ^13.0.0`. Also restore `analyzer.plugins: - custom_lint` in `analysis_options.yaml`.
- **Optional:** Confirm `flutter build apk --debug` on a Windows box that has `cmdline-tools` + Android SDK licenses accepted (Plan 06 chose to leave Android build local rather than CI-gated; developer validates locally).
- **Post-01-06 follow-up:** Consider adding an on-demand Android CI job (`workflow_dispatch`) later if solo-dev workflow changes.
- **Post-01-06 follow-up:** Watch the first real PR — the `dart format` file-exclusion glob has never been exercised on a `pull_request` ref.
- **Phase 2 handoff (from Plan 01-03):** Replace `/` (`PlaceholderHomeScreen`) with a `StatefulShellRoute` + real map view; keep splash/onboarding untouched.

### Blockers/Concerns

- **G1 (P2):** `BackdropFilter` behavior over MapLibre platform view on Impeller must be validated on real iOS + Android before full glass commitment. Fallback path documented.
- **G2 (P7):** `maplibre_gl` ^0.26.2 `setFeatureState` support unverified. Sharded-GeoJSON fallback stands by.
- **HMM accuracy (P5):** Requires ≥ 20-trip golden corpus recorded in real driving before matcher can pass CI regression.
- **Lint gap (P1):** `custom_lint` + `riverpod_lint` temporarily out (see decisions). Regular analyzer + `very_good_analysis` still enforce style + correctness; Riverpod-specific misuse detection is on hold.
- **Wave-2 hygiene (2026-07-03):** During Wave-2 parallel execution, sibling agent Plan 04 commit `3341081` inadvertently captured Plan 02's Task 2.3 test files. Files are correctly tracked and tests pass, but attribution is off. Future waves: subagents must stage individual files only, no `git add -A` / `git commit -a`.

## Session Continuity

Last session: 2026-07-03 (Plan 01-06 execution + checkpoint resolution)
Stopped at: Completed .planning/phases/01-scaffolding/06-github-actions-ci-PLAN.md
Resume file: None (Plan 07 is the last remaining plan in Phase 1)
