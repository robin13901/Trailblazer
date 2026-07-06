---
id: 03-1-01
phase: 03-1-tracking-fixes
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - lib/features/trips/domain/tracking_diagnostics.dart
  - lib/features/trips/domain/tracking_service.dart
  - lib/features/trips/data/fgb_background_geolocation_facade.dart
  - lib/features/trips/data/background_geolocation_facade.dart
  - lib/features/trips/presentation/providers/tracking_diagnostics_provider.dart
  - lib/features/onboarding/data/permission_service.dart
  - lib/features/settings/presentation/tracking_diagnostics_screen.dart
  - lib/features/settings/presentation/settings_screen.dart
  - lib/core/routing/app_router.dart
  - test/features/trips/tracking_diagnostics_test.dart
  - test/features/settings/tracking_diagnostics_screen_test.dart
autonomous: true
requirements: []

must_haves:
  truths:
    - "Every failure surface identified in 03-1-RESEARCH (FGB ready outcome, fix arrival, activity classification, ingestor reject reasons, battery-opt grant on Android) is observable on-device without a rebuild"
    - "A dev-only route `/settings/diagnostics` exists, gated by kDebugMode, reachable from a DEV section on the Settings screen"
    - "TrackingService exposes a public `diagnostics` getter returning a TrackingDiagnostics DTO snapshot; no private fields leak"
    - "Diagnostics DTO includes: facadeReadyOutcome (pending/success/failed(message)), facadeCurrentState (FgbState? — enabled + isMoving), lastAcceptedFix (ts/lat/lon/accuracy/speedKmh), lastRejected (reason + ts), lastActivityType + lastActivityAt, acceptCount, rejectCount, gapCount, splitCount, currentTripId"
    - "PermissionService exposes statusWhenInUse(), statusActivityRecognition(), and (Android-only) statusIgnoreBatteryOptimizations() so the HUD can show every rung of the ladder"
    - "HUD screen polls Timer.periodic(500ms) + setState — no new stream infrastructure, no domain-layer changes beyond the counters + getter"
    - "flutter analyze and flutter test both green after Wave 1 lands (behavior-sensitive change: counters + diagnostics getter, so flutter test runs inside the tight loop)"
  artifacts:
    - path: "lib/features/trips/domain/tracking_diagnostics.dart"
      provides: "TrackingDiagnostics DTO + FacadeReadyOutcome sealed type — the read-only snapshot shape the HUD consumes"
    - path: "lib/features/trips/domain/tracking_service.dart"
      provides: "Added public `TrackingDiagnostics get diagnostics`, private counters (accept/reject/gap/split), reject-reason tracking, facade-ready outcome tracking"
    - path: "lib/features/trips/presentation/providers/tracking_diagnostics_provider.dart"
      provides: "Provider<TrackingDiagnostics> or plain read-through Provider exposing TrackingService.diagnostics — no new stream"
    - path: "lib/features/settings/presentation/tracking_diagnostics_screen.dart"
      provides: "kDebugMode-gated Scaffold rendering the diagnostics snapshot, refreshed via Timer.periodic(500ms)"
    - path: "lib/features/onboarding/data/permission_service.dart"
      provides: "New methods statusWhenInUse(), statusActivityRecognition(), statusIgnoreBatteryOptimizations() (Android-only)"
  key_links:
    - from: "lib/features/settings/presentation/tracking_diagnostics_screen.dart"
      to: "lib/features/trips/domain/tracking_service.dart"
      via: "ref.read(trackingServiceProvider).diagnostics — one poll every 500 ms"
      pattern: "diagnostics"
    - from: "lib/features/settings/presentation/settings_screen.dart"
      to: "/settings/diagnostics route"
      via: "kDebugMode-gated ListTile → context.push('/settings/diagnostics')"
      pattern: "kDebugMode"
    - from: "lib/features/trips/domain/tracking_service.dart"
      to: "lib/features/trips/domain/tracking_diagnostics.dart"
      via: "TrackingDiagnostics constructor call inside the `diagnostics` getter"
      pattern: "TrackingDiagnostics("
    - from: "lib/features/trips/data/fgb_background_geolocation_facade.dart"
      to: "lib/features/trips/data/background_geolocation_facade.dart"
      via: "New abstract getter `currentReadyOutcome` on the facade interface, implemented by the FGB facade — lets TrackingService surface ready() success/failure without importing bg.*"
      pattern: "currentReadyOutcome"
---

## Goal

Ship an on-device debug HUD and the underlying diagnostic plumbing so every fix in Wave 2 becomes observable without a fresh drive. This plan blocks all Wave 2 work — without it, every hypothesis-fix cycle costs a real drive.

## Context

- 03-1-RESEARCH §7 enumerates every field the HUD needs and identifies exactly which are already readable (via existing provider/getter surfaces) vs which need new public API. This plan implements only the "new" column.
- 03-1-RESEARCH §7.1 recommends the DTO shape (`TrackingDiagnostics`) and pushes counters to `TrackingService` (not into the 22-test `TripFixIngestor` — keeps ingestor pure).
- 03-1-RESEARCH §7.2 recommends polling over a broadcast stream (HUD is dev-only, no need to over-engineer).
- 03-1-RESEARCH §7.3 identifies the settings-screen stub (`settings_screen.dart:14-38`) as the entry point and the router as the mount point (kDebugMode-gated GoRoute).
- Ralph-Loop tiering: `flutter analyze` in the tight loop; because this change touches `TrackingService` (behavior-sensitive per project CLAUDE.md), also run `flutter test` inside the tight loop, not just at push boundary.
- Riverpod codegen OFF (STATE decision Plan 01-01) — use plain `Provider<T>` / `Notifier`.
- Package imports only — `package:auto_explore/…`.
- `withValues(alpha:)` — never `withOpacity()`.
- `DomainError.wrap` boundary — `_ensureFacadeReady()` and the widened `showIgnoreBatteryOptimizations()` catch belong to plan 03-1-02, NOT this plan. This plan only records the ready outcome; wrapping the exception is Wave 2's job.
- Do NOT touch `bg.Config` — 03-1-RESEARCH §2.2 confirms config is complete. Do NOT touch AndroidManifest — 03-1-RESEARCH §2.3 confirms it is correct.

## Tasks

<task type="auto">
  <name>Task 1: Diagnostic plumbing (DTO + counters + getter + facade signal)</name>
  <files>
    lib/features/trips/domain/tracking_diagnostics.dart
    lib/features/trips/domain/tracking_service.dart
    lib/features/trips/data/background_geolocation_facade.dart
    lib/features/trips/data/fgb_background_geolocation_facade.dart
    test/features/trips/tracking_diagnostics_test.dart
  </files>
  <intent>Expose every private field the HUD needs as a single read-only snapshot getter, and add counters that don't exist yet.</intent>
  <action>
    **Step 1 — DTO.** Create `lib/features/trips/domain/tracking_diagnostics.dart`:

    ```dart
    // Immutable snapshot of every private observability field on TrackingService.
    // Consumed by the debug HUD (kDebugMode-only) at ~2 Hz.
    // Do NOT expose FGB or Drift types through this DTO — it must stay
    // domain-pure so the HUD can render on any platform without native deps.
    import 'package:auto_explore/features/trips/data/background_geolocation_facade.dart'
        show FgbState;

    sealed class FacadeReadyOutcome {
      const FacadeReadyOutcome();
    }
    final class FacadeReadyPending extends FacadeReadyOutcome { const FacadeReadyPending(); }
    final class FacadeReadySuccess extends FacadeReadyOutcome { const FacadeReadySuccess(); }
    final class FacadeReadyFailed extends FacadeReadyOutcome {
      const FacadeReadyFailed(this.message);
      final String message;
    }

    class LastFixSample {
      const LastFixSample({
        required this.ts,
        required this.lat,
        required this.lon,
        required this.accuracyMeters,
        required this.speedKmh,
      });
      final DateTime ts;
      final double lat;
      final double lon;
      final double accuracyMeters;
      final double speedKmh;
    }

    class TrackingDiagnostics {
      const TrackingDiagnostics({
        required this.facadeReadyOutcome,
        required this.facadeCurrentState,
        required this.lastAcceptedFix,
        required this.lastRejectedReason,
        required this.lastRejectedAt,
        required this.lastActivityType,
        required this.lastActivityAt,
        required this.acceptCount,
        required this.rejectCount,
        required this.gapCount,
        required this.splitCount,
        required this.currentTripId,
      });
      final FacadeReadyOutcome facadeReadyOutcome;
      final FgbState? facadeCurrentState;
      final LastFixSample? lastAcceptedFix;
      final String? lastRejectedReason;
      final DateTime? lastRejectedAt;
      final String lastActivityType;   // 'unknown' when never fired
      final DateTime? lastActivityAt;
      final int acceptCount;
      final int rejectCount;
      final int gapCount;
      final int splitCount;
      final int? currentTripId;
    }
    ```

    **Step 2 — Facade signal.** Extend `background_geolocation_facade.dart` (abstract) with:

    ```dart
    /// Latest outcome of the most recent `ready()` invocation.
    /// Starts as [FacadeReadyPending] before the first call.
    FacadeReadyOutcome get currentReadyOutcome;
    ```

    Add to `fgb_background_geolocation_facade.dart`:

    ```dart
    FacadeReadyOutcome _readyOutcome = const FacadeReadyPending();

    @override
    FacadeReadyOutcome get currentReadyOutcome => _readyOutcome;

    @override
    Future<void> ready() async {
      try {
        await bg.BackgroundGeolocation.ready(_buildConfig());
        _readyOutcome = const FacadeReadySuccess();
      } on Object catch (e) {
        _readyOutcome = FacadeReadyFailed(e.toString());
        rethrow;
      }
    }
    ```

    (Note: `on Object` widens beyond `Exception` per 03-1-RESEARCH §9 Risk 6. The rethrow preserves current caller behavior — the exception still bubbles; we merely record it. The actual try/catch guard around `_ensureFacadeReady()` belongs to plan 03-1-02.)

    Also add to the abstract interface + fake:
    - Fake facade default: `FacadeReadyOutcome get currentReadyOutcome => _readyOutcome;` with the same field wired identically to prod, so tests can assert outcome transitions.

    **Step 3 — TrackingService counters + getter.** In `lib/features/trips/domain/tracking_service.dart`:

    Add private fields:
    ```dart
    int _acceptCount = 0;
    int _rejectCount = 0;
    int _gapCount = 0;
    int _splitCount = 0;
    String? _lastRejectedReason;
    DateTime? _lastRejectedAt;
    LastFixSample? _lastAcceptedFix;
    ```

    In `_onLocation`'s outcome switch:
    - `FixAccepted`: increment `_acceptCount`, set `_lastAcceptedFix = LastFixSample(ts: outcome.ts, lat: outcome.lat, lon: outcome.lon, accuracyMeters: outcome.accuracyMeters, speedKmh: outcome.speedKmh)`.
    - `FixRejected`: increment `_rejectCount`, set `_lastRejectedReason = outcome.reason` (or whatever the field is called on FixRejected — check 03-02 SUMMARY), set `_lastRejectedAt = DateTime.now()`.
    - `GapObserved`: increment `_gapCount`.
    - `SplitRequired`: increment `_splitCount`.

    Add getter:
    ```dart
    TrackingDiagnostics get diagnostics {
      final st = _currentState;
      final currentTripId = st is TrackingRecording ? st.tripId : null;
      return TrackingDiagnostics(
        facadeReadyOutcome: _facade.currentReadyOutcome,
        facadeCurrentState: null,  // hydrated lazily by HUD via facade.currentState() if desired
        lastAcceptedFix: _lastAcceptedFix,
        lastRejectedReason: _lastRejectedReason,
        lastRejectedAt: _lastRejectedAt,
        lastActivityType: _lastActivityType ?? 'unknown',
        lastActivityAt: _lastActivityAt,
        acceptCount: _acceptCount,
        rejectCount: _rejectCount,
        gapCount: _gapCount,
        splitCount: _splitCount,
        currentTripId: currentTripId,
      );
    }
    ```

    Do NOT modify `TripFixIngestor` — counters live on TrackingService per 03-1-RESEARCH §7.1.

    **Step 4 — Test.** `test/features/trips/tracking_diagnostics_test.dart`:
    - Construct a TrackingService with FakeBackgroundGeolocationFacade.
    - Assert `diagnostics.facadeReadyOutcome is FacadeReadyPending` before first `_ensureFacadeReady` call.
    - Simulate three accepted fixes → assert `acceptCount == 3`, `lastAcceptedFix` matches last fix.
    - Simulate one rejected fix (accuracy > threshold) → assert `rejectCount == 1`, `lastRejectedReason` non-null.
    - Simulate an activity change → assert `lastActivityType` / `lastActivityAt` reflect it.
    - Simulate a fake `ready()` that throws → assert `facadeReadyOutcome is FacadeReadyFailed` with the message.
  </action>
  <verify>
    `flutter analyze` — zero errors.
    `flutter test test/features/trips/tracking_diagnostics_test.dart` — green.
    `flutter test` (full suite) — green, no regressions in the existing 141 tests.
    grep for `_acceptCount` in `tracking_service.dart` returns ≥ 1 hit; grep for `TrackingDiagnostics(` in `tracking_service.dart` returns exactly one call site (the getter body).
  </verify>
  <done>
    TrackingDiagnostics DTO exists, TrackingService exposes it via public getter, all four counters wired, facade records ready() outcome. Test file green. `flutter test` full suite green.
  </done>
</task>

<task type="auto">
  <name>Task 2: PermissionService extensions + diagnostics provider</name>
  <files>
    lib/features/onboarding/data/permission_service.dart
    lib/features/trips/presentation/providers/tracking_diagnostics_provider.dart
  </files>
  <intent>Expose the three permission rungs the HUD needs, plus a Riverpod seam to consume TrackingDiagnostics.</intent>
  <action>
    **Step 1 — PermissionService.** Extend the abstract interface:

    ```dart
    Future<PermissionStatus> statusWhenInUse();
    Future<PermissionStatus> statusActivityRecognition();
    Future<PermissionStatus> statusIgnoreBatteryOptimizations();   // Android only; iOS returns granted
    ```

    `PermissionHandlerService` impl (using the prefixed `as ph` import per STATE Plan 03-05):
    ```dart
    @override
    Future<PermissionStatus> statusWhenInUse() => ph.Permission.locationWhenInUse.status;

    @override
    Future<PermissionStatus> statusActivityRecognition() => ph.Permission.activityRecognition.status;

    @override
    Future<PermissionStatus> statusIgnoreBatteryOptimizations() async {
      if (Platform.isIOS) return PermissionStatus.granted;
      return ph.Permission.ignoreBatteryOptimizations.status;
    }
    ```

    Do NOT change how the onboarding ladder reads statuses — 03-1-02 owns extending TrackingCapability to consider the battery-opt grant. This plan is READ-ONLY exposure for the HUD.

    **Step 2 — Diagnostics provider.** Create `lib/features/trips/presentation/providers/tracking_diagnostics_provider.dart`:

    ```dart
    // Read-through provider — HUD calls .read() every ~500 ms; TrackingService's
    // `diagnostics` getter constructs a fresh snapshot each call.
    // No caching, no stream — the HUD's Timer.periodic drives the refresh.
    import 'package:auto_explore/features/trips/domain/tracking_diagnostics.dart';
    import 'package:auto_explore/features/trips/domain/tracking_service.dart';
    import 'package:auto_explore/features/trips/presentation/providers/tracking_service_provider.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';

    final trackingDiagnosticsProvider = Provider<TrackingDiagnostics>((ref) {
      return ref.watch(trackingServiceProvider).diagnostics;
    });
    ```

    Note: since `TrackingDiagnostics` is a plain snapshot constructed each call, watching this provider is fine for one-shot reads. The HUD does NOT `watch` — it `read`s inside the polling timer, so Riverpod does not thrash on rebuilds.
  </action>
  <verify>
    `flutter analyze` — zero errors.
    `flutter test test/features/onboarding/` — existing permission tests still green (no test added here since the new methods are trivial passthroughs; unit-testing PermissionHandlerService requires platform channel mocks, out of scope).
    grep for `ignoreBatteryOptimizations` in `lib/` returns ≥ 2 hits (facade prod call + new PermissionService method).
  </verify>
  <done>
    PermissionService has three new status methods; trackingDiagnosticsProvider exists and reads the getter. No production behavior change beyond the new read paths.
  </done>
</task>

<task type="auto">
  <name>Task 3: HUD screen + route + Settings entry</name>
  <files>
    lib/features/settings/presentation/tracking_diagnostics_screen.dart
    lib/features/settings/presentation/settings_screen.dart
    lib/core/routing/app_router.dart
    test/features/settings/tracking_diagnostics_screen_test.dart
  </files>
  <intent>Ship the on-device HUD so the drive tester can inspect every relevant state field live.</intent>
  <action>
    **Step 1 — Screen.** Create `lib/features/settings/presentation/tracking_diagnostics_screen.dart` as a `ConsumerStatefulWidget`:

    - `initState()`: start `Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}))`.
    - `dispose()`: cancel the timer.
    - `build()`:
      - `final diag = ref.read(trackingDiagnosticsProvider);`
      - Also read permission statuses via `FutureBuilder` (or cache them in state after Timer tick) — 4 rungs: whenInUse, always (existing), notification (existing), activityRecognition, ignoreBatteryOptimizations.
      - Optionally read `FgbState` via `ref.read(backgroundGeolocationFacadeProvider).currentState()` in the timer tick; store to state.
      - Render as a plain `Scaffold` with a `ListView` of `ListTile`s grouped into sections:
        - **FGB**: readyOutcome (color-coded — green success, red failed, grey pending), currentState.enabled, currentState.isMoving.
        - **Permissions**: 5 rungs with `.name` shown next to each (e.g., `granted`, `denied`, `permanentlyDenied`).
        - **Last accepted fix**: ts (formatted), lat, lon, accuracy, speedKmh — or `—` if null.
        - **Last rejected fix**: reason + relative time — or `—`.
        - **Last activity**: type + relative time.
        - **Counters**: accept, reject, gap, split.
        - **Current trip**: tripId or `idle`.
      - Use `withValues(alpha: …)` for any translucent colors (project rule).
      - No LiquidGlass — HUD is functional, not chrome.

    Guard the whole screen behind `assert(kDebugMode)` in the constructor and short-circuit-render an error card if the route is somehow reached in release mode.

    **Step 2 — Route.** In `lib/core/routing/app_router.dart`:
    - Add a GoRoute at `/settings/diagnostics` whose `builder` returns the new screen, only when `kDebugMode` — either wrap the route in `if (kDebugMode) ... else placeholder` inside the routes list, or use a redirect that rejects the path in release. Simplest: gate at route registration.

    **Step 3 — Settings entry.** In `lib/features/settings/presentation/settings_screen.dart`:
    - Add a `if (kDebugMode) ...` section at the bottom titled "Developer" (or "DEV") with a single `ListTile(title: Text('Tracking diagnostics'), trailing: Icon(Icons.chevron_right), onTap: () => context.push('/settings/diagnostics'))`.
    - Use `context.push` (not `context.go`) so the shell stays alive — matches STATE Plan 02-06 decision.

    **Step 4 — Widget test.** `test/features/settings/tracking_diagnostics_screen_test.dart`:
    - Pump the screen with an overridden trackingDiagnosticsProvider returning a fixed TrackingDiagnostics snapshot.
    - Assert the screen renders text for readyOutcome, acceptCount, rejectCount, and lastActivityType.
    - Do NOT test the polling Timer — pattern per STATE Plan 03-06 (TrackingDurationTicker) confirms the shape; a widget test that pumps 500 ms of fake time would add flakiness without value.
  </action>
  <verify>
    `flutter analyze` — zero errors.
    `flutter test test/features/settings/tracking_diagnostics_screen_test.dart` — green.
    `flutter test` (full suite) — green.
    Manual (in Wave 3's checkpoint drive, not this task): on device, open Settings → tap "Tracking diagnostics" → screen appears → start a manual trip → all counters increment in real time.
  </verify>
  <done>
    HUD screen exists, is reachable from Settings under a kDebugMode gate, polls at 2 Hz, and renders every field enumerated in must_haves.truths[3]. Widget test green. No release-mode entry point.
  </done>
</task>

## Verification

- `flutter analyze` clean at repo root.
- `flutter test` full suite green (behavior-sensitive change: TrackingService counters + diagnostics getter, so full test suite runs inside the tight loop per project CLAUDE.md).
- grep for `TrackingDiagnostics` in `lib/` returns ≥ 3 hits (DTO decl, getter body, provider read).
- grep for `/settings/diagnostics` in `lib/` returns exactly 2 hits (route decl + Settings ListTile onTap).
- grep for `ignoreBatteryOptimizations` in `lib/features/onboarding/` returns ≥ 1 hit (new PermissionService method).
- Release-build regression check: `flutter build apk --release` (or at minimum `flutter analyze --no-fatal-infos`) does not include the HUD screen entry point outside kDebugMode. Manual code inspection is sufficient — no need to actually run the release build in the tight loop.

## SC alignment

- **SC1 (Debug HUD shipped and shows all listed fields live):** SATISFIED by this plan in its entirety. Every field in CONTEXT §Suggested wave breakdown Wave 1 is rendered; every field in 03-1-RESEARCH §7 is either read from existing surfaces or exposed via the new getter + PermissionService methods.
- **SC2/3/4/5:** NOT touched by this plan — the HUD is observability, not fixes. Those SC land in Waves 2–3.
- **SC6:** BLOCKED on this plan. The Wave 3 in-car drive uses the HUD to verify Waves 2 fixes landed; without it, drive-time introspection is impossible.

## Deviation Handling

- If `FixRejected`'s reason field is named differently (e.g. `String reason` vs `RejectReason reason`), match the existing shape from 03-02 SUMMARY. Do NOT rename it — this plan additively consumes it.
- If `TripFixIngestor` outcome carries a numeric enum for reject reason instead of a String, use `.name` when storing to `_lastRejectedReason`. Keep the DTO field a `String?` — the HUD should display human-readable text, not enum ordinals.
- If `FakeBackgroundGeolocationFacade` (in `test/features/trips/`) doesn't yet expose a hook to force `ready()` to throw, add one — this is Wave 1's test infrastructure and must not block on Wave 2.
- If `flutter analyze` flags `unused_element` on `FacadeReadySuccess`/`FacadeReadyPending`, that's expected — Wave 1 tests only touch one branch, Wave 2 will cover the rest. Add `// ignore: unused_element` inline on the class decl and remove in Wave 2.
- Iterate up to 3 times per task; if `flutter analyze` still fires after 3 attempts, stop and report the exact analyzer output.
