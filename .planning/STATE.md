# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-02)

**Core value:** When I open the map, I immediately see the roads I've already driven, painted onto the world — and that view keeps pulling me back to explore more.
**Current focus:** Phase 2 — Map + Glass Shell (Phase 1 complete + verified)

## Current Position

Phase: 2 of 11 (Map + Glass Shell) — **IN PROGRESS**
Plan: 6/7 plans in Phase 2 done (02-06 router shell refactor — COMPLETE)
Status: StatefulShellRoute wired; 3-tab shell + /settings route + chrome hiding on non-map tabs; 64/64 tests green; Wave 7 smoke-test bugfixes applied
Last activity: 2026-07-04 — Wave 7 bugfixes: PMTiles loopback tile server + attribution button reposition

Progress: [█░░░░░░░░░] ~16% (13/77 est. plans overall — Phase 1: 7/7; Phase 2: 6/7)

## Performance Metrics

**Velocity:**
- Total plans completed: 7 (01-01, 01-02, 01-03, 01-04, 01-05, 01-06, 01-07)
- Average duration: ~19 min
- Total execution time: ~2.2 hours (est.)

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-scaffolding | 7 | ~135 min | ~19 min |

**Recent Trend:**
- Last 7 plans: 01-01 (18 min), 01-05 (~2 min), 01-02, 01-03 (parallel Wave 2), 01-04 (25 min), 01-06 (~17 min: 7 min exec + ~10 min interactive checkpoint), 01-07 (~8 min docs-only)
- Trend: infra plans on target; docs close-out fastest (no code = no Ralph Loop)

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
- **Plan 01-07 (2026-07-03):** README title uses the product name **Trailblazer**; Dart package name remains `auto_explore` in `pubspec.yaml` (legacy working title). One-liner in README calls this out to prevent import-path confusion.
- **Plan 01-07 (2026-07-03):** README + `docs/ARCHITECTURE.md` deliberately overrode 15 stale plan-template details to match actual Phase 1 state (repo slug, branch, dropped lints, iOS artifact type, iOS manual trigger, Android-local-only, codegen ordering, package imports, alphabetized deps, FK cascades, business-key PKs, `PlatformDispatcher` return value, onboarding-in-splash decision, `permission_handler` not-yet-added, FGS placeholder class, `NSBluetoothPeripheralUsageDescription` skip). All 15 sourced from prior SUMMARY files / STATE decisions.
- **Plan 01-07 (2026-07-03):** Anti-patterns table pattern established (vs prior projects) — reusable for future phase docs.
- **Phase 1 close-out (2026-07-03):** Real-device install smoke test confirmed by user on Android — SC5 fully verified. Widget test remains authoritative for CI regressions.
- **Phase 1 close-out (2026-07-03):** Display name rename Auto-Explore → Trailblazer applied to Dart layer (MaterialApp title, splash/onboarding/home screens, test assertions), iOS `CFBundleDisplayName` + 6 permission strings, Android `android:label`. Internal identifiers preserved: Dart package `auto_explore`, iOS bundle prefix `de.autoexplore`, Android applicationId `de.autoexplore.auto_explore` — those are stable IDs linked to Codecov/GitHub/future store listings.
- **Phase 1 close-out (2026-07-03):** Built-in Kotlin migration deferred. Flutter 3.44 auto-added `android.builtInKotlin=false` and `android.newDsl=false` to `gradle.properties`, silencing the deprecation warning. Full migration requires AGP 9.0+ (we're on 8.11.1); recipe documented inline in `gradle.properties` for when we bump AGP.
- **Plan 02-01 (2026-07-03):** G1 gate resolved — `LiquidGlassSettings.platformSupportsBlurOverMap = true` on both platforms. Android (SM S921B, Impeller) confirmed via SpikeG1Screen: `liquid_glass_renderer` shaders compile and render correctly; refraction visible in top pill. iOS: not device-tested, defaulted to `true` (`liquid_glass_renderer` is iOS-designed). BackdropFilter over PlatformView remains broken on Android (issue #185497) — confirmed via spike; unused going forward. Conditional PASS: full over-platform-view verification deferred to end of Plan 02-02 (real PMTiles-backed map). Fallback path in `LiquidGlassSettings` retained as defensive code. Full record: `docs/G1_SPIKE.md`. Downstream glass shell (02-05) branches on this flag.
- **Plan 02-01 (2026-07-03):** `LiquidGlassSettings` API deviated from plan sketch — the proposed `setPlatformSupportsBlurOverMap(value: ...)` method refactored to a public static field/getter pair `platformBlurEnabled` to satisfy the `very_good_analysis` `use_setters_to_change_properties` / `unnecessary_getters_setters` lint pair. Wire-up in `main.dart` is `LiquidGlassSettings.platformBlurEnabled = true;`. Instance reads still go through `LiquidGlassSettings.instance.platformSupportsBlurOverMap` (unchanged public surface for downstream widgets).
- **Plan 02-01 (2026-07-03):** `LiquidRoundedSuperellipse.borderRadius` is a plain `double` in `liquid_glass_renderer` 0.2.0-dev.4, not a `Radius`. Corrected in `spike_g1_screen.dart`; downstream 02-05 code must use the same signature.
  - **Plan 02-02 (2026-07-03):** `FakeMapLibrePlatform` pattern adopted for maplibre widget tests — replaces `MapLibrePlatform.createInstance` in test `setUp()` to avoid `MissingPluginException` on PlatformView. Helper lives at `test/helpers/fake_maplibre_platform.dart`; all future map widget tests reuse it.
- **Plan 02-02 (2026-07-03):** `maplibre_gl_platform_interface: ^0.26.2` added as `dev_dependency` so tests can subclass `MapLibrePlatform` directly (re-export from `maplibre_gl` is too limited); `depend_on_referenced_packages` lint satisfied.
- **Plan 02-02 (2026-07-03):** `MapWidget` states only `tiltGesturesEnabled: false` explicitly — all other `MapLibreMap` gesture flags are defaults and omitted per `avoid_redundant_argument_values`. `_controller` field removed from `_MapWidgetState` (unused in Phase 2); `onMapCreated` still forwarded inline via `widget.onMapCreated?.call(c)`.
- **Plan 02-02 (2026-07-03):** PMTiles style referenced via bare asset path string in `MapLibreMap.styleString` (e.g. `'assets/map_style_light.json'`) — NOT `asset://...`. PMTiles source declared in style JSON via `"pmtiles://assets/tiles/dev_berlin.pmtiles"` URL, NOT at runtime via `controller.addSource()` (Pitfall 1 avoided).
- **Plan 02-03 (2026-07-03):** `permission_handler: ^12.0.3` added. `meta: ^1.16.0` promoted to direct dep to satisfy `depend_on_referenced_packages` lint when using `@immutable` in `CameraState`.
- **Plan 02-03 (2026-07-03):** `MapControllerNotifier` exposes `controller` getter+setter (not `attach`/`detach` methods) to satisfy the `use_setters_to_change_properties` vs `avoid_setters_without_getters` lint cycle (same pattern as `LiquidGlassSettings.platformBlurEnabled` in Plan 02-01).
- **Plan 02-03 (2026-07-03):** `myLocationRenderMode` is gated on `isGranted`: `compass` only when `myLocationEnabled=true` — `MapLibreMap` asserts this constraint at construction time.
- **Plan 02-03 (2026-07-03):** Riverpod `ref` must NOT be used in `ConsumerStatefulWidget.dispose()` after unmount. Safe pattern: cache `ref.read(provider.notifier)` in `initState`, use cached reference in `dispose()`.
- **Plan 02-03 (2026-07-03):** `FakeLocationPermissionNotifier` pattern: `AsyncNotifier` stub injected via `ProviderScope.overrides` for all tests that use `OnboardingScreen` or `MapWidget`. Prevents `MissingPluginException` from `permission_handler` platform channel. Used in `app_router_test` and `map_widget_test`.
- **Plan 02-03 (2026-07-03):** `Logger('onboarding')` used directly — no `AppLogger.instance` class. Phase 1 logging API is `setupLogging()` + standard `logging.Logger` usage.
- **Plan 02-03 (2026-07-03):** `FollowMode.locationAndHeading` slot reserved for Phase 3 heading-lock. Phase 3 wires it to `MyLocationTrackingMode.trackingCompass`; no changes to `CameraState` or `CameraStateNotifier.setFollowMode` needed.
- **Plan 02-04 (2026-07-03):** `MapWidget.styleAsset` constructor param removed — `mapStyleAssetProvider` is the single source of truth for active style. Tests fix the style via `mapStyleAssetProvider.overrideWith` + `_FixedMapStyleNotifier` stub.
- **Plan 02-04 (2026-07-03):** Fade duration: 180 ms easeInOut for both the `AnimatedOpacity` and the pre-`setStyle` delay. `onStyleLoadedCallback` is the fade-back-in trigger — not a fixed timer.
- **Plan 02-04 (2026-07-03):** `themeMode: ThemeMode.system` omitted from `MaterialApp.router` (it is the default; `avoid_redundant_argument_values` lint). Intent documented in inline comment.
- **Plan 02-04 (2026-07-03):** `unawaited()` wrapper required for `Future`-returning call in `void` override (`didChangePlatformBrightness`) to satisfy `discarded_futures` lint.
- **Plan 02-05 (2026-07-03):** `GlassPillFallback` and `GlassCircleFallback` exposed as public types (not private `_Fallback*`) so widget tests can use `find.byType()` without private-type reflection workarounds.
- **Plan 02-05 (2026-07-03):** `LiquidGlass` must be wrapped in `LiquidGlassLayer` — confirmed from reading `liquid_glass_renderer-0.2.0-dev.4` pub-cache source. Each `GlassPill` / `GlassCircle` creates its own layer (simpler; performance acceptable for Phase 2; shared-layer optimization deferred to Phase 7 if needed).
- **Plan 02-05 (2026-07-03):** `MapScreen.bottomNav: Widget?` param allows Plan 02-06 to inject a `StatefulNavigationShell`-driven pill without API changes. `_LocalBottomNav` handles standalone/test operation.
- **Plan 02-05 (2026-07-03):** `SettingsGlassButton` tap uses SnackBar stub ("Settings coming in Phase 10") — matches `TripFab` pattern; avoids premature `/settings` route dependency before Plan 02-06.
- **Plan 02-05 (2026-07-03):** `RecenterButton` stays inside `MapWidget` (reads `mapControllerProvider` + `cameraStateProvider`); not duplicated in `MapScreen` Stack.
- **Plan 02-05 (2026-07-03):** `BottomNavShell` is a pure presentation widget (no state, no providers); `currentIndex + onTap` API; Plan 02-06 wires it to `StatefulNavigationShell.currentIndex` + `goBranch(i)`.
- **Plan 02-06 (2026-07-03):** `context.push('/settings')` used (not `context.go`) so the StatefulShellRoute stays alive when Settings is open. `context.go` dismounts MapWidget mid-frame triggering a Riverpod dispose-while-building assertion from `MapControllerNotifier`.
- **Plan 02-06 (2026-07-03):** `SettingsGlassButton` accepts `VoidCallback? onTap` (router-agnostic). `MapScreen` passes `() => context.push('/settings')` when shell is present; null when `navigationShell == null` (standalone widget tests — no-op, no crash).
- **Plan 02-06 (2026-07-03):** `_MapTabContent` sentinel class used for the Map branch (not SizedBox.shrink inline) — explicit named class signals to Phase 3+ that sub-routes under `/` belong as children of the Map branch.
- **Plan 02-06 (2026-07-03):** Chrome (FocusAreaPill, SettingsGlassButton, TripFab) hidden when `currentIndex > 0` (non-map tabs). BottomNavShell always visible.
- **Wave 7 bugfix (2026-07-04):** maplibre_gl 0.26.2 does not natively resolve `pmtiles://` URLs on Android. Added Dart loopback tile server (`TileServer` in `lib/features/map/data/tile_server.dart`) reading from bundled `assets/tiles/dev_berlin.pmtiles` via `pmtiles ^2.2.0` and `shelf ^1.4.2` + `shelf_router ^1.1.4`, serving on `http://127.0.0.1:7070/{z}/{x}/{y}.pbf`. Style JSONs (`assets/map_style_light.json`, `assets/map_style_dark.json`) changed from `pmtiles://` URL to XYZ `tiles:[]` array. This is the offline path on both platforms (iOS `pmtiles://` supported natively per 0.26.2 CHANGELOG, but unified code path is simpler).
- **Wave 7 bugfix (2026-07-04):** MapLibre native attribution button cannot be fully hidden via Flutter API (no `attributionEnabled: false` in maplibre_gl 0.26.2). Repositioned to `AttributionButtonPosition.bottomLeft` with `Point(8, 96)` margins to keep OSM/Protomaps license attribution visible but out of the way of the Liquid Glass FAB (bottom-right) and bottom nav pill. Fully custom attribution chip deferred to Phase 8+.

### Pending Todos

- **Chore (post-Phase 1):** Re-add `custom_lint` + `riverpod_lint` when a `custom_lint` release supports `analyzer ^13.0.0`. Also restore `analyzer.plugins: - custom_lint` in `analysis_options.yaml`.
- **Optional:** Confirm `flutter build apk --debug` on a Windows box that has `cmdline-tools` + Android SDK licenses accepted (Plan 06 chose to leave Android build local rather than CI-gated; developer validates locally).
- **Post-01-06 follow-up:** Consider adding an on-demand Android CI job (`workflow_dispatch`) later if solo-dev workflow changes.
- **Post-01-06 follow-up:** Watch the first real PR — the `dart format` file-exclusion glob has never been exercised on a `pull_request` ref.
- **Phase 2 handoff (from Plan 01-03):** Replace `/` (`PlaceholderHomeScreen`) with a `StatefulShellRoute` + real map view; keep splash/onboarding untouched. **DONE in Plan 02-06.**
- **Phase 2 handoff (post-close-out):** When we bump AGP to 9.0+, remove `kotlin-android` plugin + `kotlinOptions{}` block from `android/app/build.gradle.kts` and add top-level `kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }`. Then flip both flags in `android/gradle.properties` to `true` (or delete them). Recipe is inline in the file.
- **Phase 8+ or later:** Consider a fully custom OSM/Protomaps attribution chip (Liquid Glass-styled) to replace/hide the native MapLibre attribution button. Would require either patching the Android native binding or accepting the native button repositioned as a compromise.
- **Phase 2 handoff (post-close-out):** One-time manual `workflow_dispatch` trigger of `iOS Build` from GitHub Actions UI to observe a green macOS run.
- **Plan 02-02 (G1 re-verify):** At end of 02-02, visually verify LiquidGlass renders correctly over the real bundled-PMTiles MapLibre map on Android (SM S921B). If it fails, flip `LiquidGlassSettings.platformBlurEnabled` to `false` and document in `docs/G1_SPIKE.md` as a full G1 fallback.
- **Plan 02-02 status (2026-07-03):** CARRY-FORWARD — 02-02 code is complete; G1 re-verify requires installing debug build on device and opening MapScreen (temporarily via a route). Deferred to 02-07 end-to-end device test or whenever next debug build is installed.
- **Plan 02-02 (SkSL warnings + demotiles):** `demotiles.maplibre.org` URL did not load tiles during the G1 spike — verify that our bundled PMTiles + local style JSON pipeline works end-to-end (this is what 02-02 exists to do, but flag the G1 spike observation so we don't chase the wrong root cause). **STATUS (2026-07-03):** Code complete; end-to-end tile rendering verification requires device install — deferred to 02-07.

### Blockers/Concerns

- **G1 (P2):** **RESOLVED (conditional PASS) 2026-07-03** — `platformBlurEnabled = true` on both platforms. Android device-verified (SM S921B, Impeller); iOS defaulted to `true` (not device-tested). Full over-platform-view re-verification pending at end of Plan 02-02 — see `docs/G1_SPIKE.md`.
- **G2 (P7):** `maplibre_gl` ^0.26.2 `setFeatureState` support unverified. Sharded-GeoJSON fallback stands by.
- **HMM accuracy (P5):** Requires ≥ 20-trip golden corpus recorded in real driving before matcher can pass CI regression.
- **Lint gap (P1):** `custom_lint` + `riverpod_lint` temporarily out (see decisions). Regular analyzer + `very_good_analysis` still enforce style + correctness; Riverpod-specific misuse detection is on hold.
- **Wave-2 hygiene (2026-07-03):** During Wave-2 parallel execution, sibling agent Plan 04 commit `3341081` inadvertently captured Plan 02's Task 2.3 test files. Files are correctly tracked and tests pass, but attribution is off. Future waves: subagents must stage individual files only, no `git add -A` / `git commit -a`.

## Session Continuity

Last session: 2026-07-04 (Wave 7 smoke-test bugfixes)
Stopped at: Applied Wave 7 bugfixes — PMTiles loopback tile server + attribution reposition (64/64 tests green); ready for re-smoke-test then 02-07 close-out
Resume file: None — user to re-run device smoke test after this bugfix, then continue with 02-07 SUMMARY / VERIFICATION / ROADMAP updates
