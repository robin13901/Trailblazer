---
id: 03-06
phase: 03-tracking-mvp
plan: 06
type: execute
wave: 3
depends_on: [03-04, 03-05]
files_modified:
  - lib/features/map/presentation/widgets/trip_fab.dart
  - lib/features/trips/presentation/widgets/live_tracking_panel.dart
  - lib/features/trips/presentation/widgets/tracking_duration_ticker.dart
  - lib/features/map/presentation/map_screen.dart
  - lib/features/trips/presentation/providers/tracking_state_provider.dart
  - test/features/map/trip_fab_morph_test.dart
  - test/features/trips/presentation/live_tracking_panel_test.dart
autonomous: false
requirements_addressed: [TRK-02, TRK-03, TRK-09, TRK-11]

must_haves:
  truths:
    - "TripFab reads trackingStateProvider and shows the P2 red-dot glass FAB when Idle, and a solid red circular Stop button (white square icon) when Recording — same 64 dp size, same location"
    - "Tapping the FAB in Idle calls TrackingNotifier.startManual(); tapping in Recording calls stopActive()"
    - "LiveTrackingPanel is visible on the map (above the bottom-nav pill, below FAB) ONLY when state is TrackingRecording"
    - "Panel text renders as `Recording · MM:SS · X.X km · N km/h`, updates every 1 s via a widget-owned Timer that cancels on state change"
    - "During recording, TrackingNotifier updates the Android FGS notification text via facade.setNotificationText(...) every ~30 s"
    - "AnimatedSwitcher smoothly cross-fades between Start/Stop FAB variants (~200 ms)"
    - "Semantics label flips: 'Start trip' (idle) → 'Stop trip' (recording)"
    - "iOS blue-bar 'location in use' indicator does its default thing — no custom text (platform limit, documented)"
  artifacts:
    - path: "lib/features/map/presentation/widgets/trip_fab.dart"
      provides: "Morphing FAB that reads trackingStateProvider"
      contains: "ref.watch(trackingStateProvider)"
    - path: "lib/features/trips/presentation/widgets/live_tracking_panel.dart"
      provides: "Glass panel with live stats"
      contains: "class LiveTrackingPanel"
    - path: "lib/features/trips/presentation/widgets/tracking_duration_ticker.dart"
      provides: "1-second widget-owned Timer.periodic"
      contains: "Timer.periodic"
  key_links:
    - from: "trip_fab.dart"
      to: "trackingStateProvider"
      via: "ref.watch → switch on TrackingIdle/TrackingRecording"
      pattern: "TrackingIdle|TrackingRecording"
    - from: "live_tracking_panel.dart"
      to: "trackingStateProvider + trackingDurationTicker"
      via: "watch state for visibility + distance, ticker for MM:SS"
      pattern: "trackingStateProvider"
    - from: "TrackingNotifier"
      to: "facade.setNotificationText"
      via: "Timer.periodic(Duration(seconds: 30)) started in startManual/auto-start; cancelled in stopActive/idle"
      pattern: "setNotificationText"
---

<objective>
Wire the P2 static FAB to the notifier so it morphs Start↔Stop, insert the LiveTrackingPanel into the map's bottom chrome, and light up the persistent Android notification with 30 s live-updates. This is the entire user-visible surface of Phase 3 recording.

Purpose: TRK-02 (manual start via FAB), TRK-03 (manual trip only ends on Stop button), TRK-09 (live-tracking overlay), TRK-11 (persistent notification with live stats — Android).

Output: Two new widgets + FAB rewrite + map_screen slot + 30 s notification updater in the notifier + 2 widget tests. Ends with a real-device visual checkpoint (75 min per RESEARCH.md estimate).
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@.planning/phases/03-tracking-mvp/03-CONTEXT.md
@.planning/phases/03-tracking-mvp/03-RESEARCH.md
@.planning/phases/03-tracking-mvp/03-04-SUMMARY.md

# Existing chrome
@lib/features/map/presentation/widgets/trip_fab.dart
@lib/features/map/presentation/widgets/glass_pill.dart
@lib/features/map/presentation/map_screen.dart

# Package name is `auto_explore`.
</context>

<tasks>

<task type="auto">
  <name>Task 1: FAB morph + duration ticker + live panel widgets</name>
  <files>
    - lib/features/map/presentation/widgets/trip_fab.dart
    - lib/features/trips/presentation/widgets/tracking_duration_ticker.dart
    - lib/features/trips/presentation/widgets/live_tracking_panel.dart
    - test/features/map/trip_fab_morph_test.dart
    - test/features/trips/presentation/live_tracking_panel_test.dart
  </files>
  <action>
    1. Rewrite `lib/features/map/presentation/widgets/trip_fab.dart`:
       ```dart
       class TripFab extends ConsumerWidget {
         const TripFab({super.key});
         @override
         Widget build(BuildContext context, WidgetRef ref) {
           final state = ref.watch(trackingStateProvider);
           final onTap = switch (state) {
             TrackingIdle() =>
                 () => ref.read(trackingStateProvider.notifier).startManual(),
             TrackingRecording() =>
                 () => ref.read(trackingStateProvider.notifier).stopActive(),
           };
           final child = switch (state) {
             TrackingIdle() => const _StartVariant(key: ValueKey('start')),
             TrackingRecording() => const _StopVariant(key: ValueKey('stop')),
           };
           return Semantics(
             button: true,
             label: state is TrackingIdle ? 'Start trip' : 'Stop trip',
             child: GestureDetector(
               onTap: onTap,
               child: AnimatedSwitcher(
                 duration: const Duration(milliseconds: 200),
                 child: child,
               ),
             ),
           );
         }
       }
       ```
       - `_StartVariant`: PRESERVE the P2 look — reuse the existing GlassCircle idiom from `trip_fab.dart` v2 (STATE.md 02-05). If the file currently returns a `LiquidGlass`-wrapped 64 dp circle with the red-dot record icon, extract that into `_StartVariant`.
       - `_StopVariant`: solid red filled circle, NO LiquidGlass wrapper:
         ```dart
         Container(
           width: 64, height: 64,
           decoration: const BoxDecoration(
             color: Color(0xFFD32F2F), // Material red 700
             shape: BoxShape.circle,
             boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0,2))],
           ),
           child: const Center(
             child: Icon(Icons.stop, color: Colors.white, size: 28),
           ),
         )
         ```
       - Keep the 64 dp size CONSTANT — STATE.md 02-05 mentions `_fabSize` in `map_screen.dart`; match it exactly.

    2. `lib/features/trips/presentation/widgets/tracking_duration_ticker.dart`:
       - A tiny `StatefulWidget` that owns a `Timer.periodic(Duration(seconds: 1))` and a `DateTime.now()` re-read. Exposes its child via a builder pattern that receives `DateTime now`:
         ```dart
         class TrackingDurationTicker extends StatefulWidget {
           const TrackingDurationTicker({required this.builder, super.key});
           final Widget Function(BuildContext, DateTime now) builder;
           @override State<TrackingDurationTicker> createState() =>
               _TrackingDurationTickerState();
         }
         class _TrackingDurationTickerState extends State<TrackingDurationTicker> {
           late Timer _t;
           DateTime _now = DateTime.now();
           @override void initState() {
             super.initState();
             _t = Timer.periodic(const Duration(seconds: 1), (_) {
               if (!mounted) return;
               setState(() => _now = DateTime.now());
             });
           }
           @override void dispose() { _t.cancel(); super.dispose(); }
           @override Widget build(BuildContext context) => widget.builder(context, _now);
         }
         ```
       - This is the RESEARCH.md Pitfall 4 mitigation — timer lives inside a widget, cancels on dispose.

    3. `lib/features/trips/presentation/widgets/live_tracking_panel.dart`:
       ```dart
       class LiveTrackingPanel extends ConsumerWidget {
         const LiveTrackingPanel({super.key});
         @override Widget build(BuildContext context, WidgetRef ref) {
           final state = ref.watch(trackingStateProvider);
           if (state is! TrackingRecording) return const SizedBox.shrink();
           return TrackingDurationTicker(
             builder: (context, now) {
               final d = state.duration(now);
               final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
               final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
               final km = (state.distanceMeters / 1000).toStringAsFixed(1);
               final spd = state.currentSpeedKmh?.round().toString() ?? '—';
               final text = 'Recording · $mm:$ss · $km km · $spd km/h';
               // Reuse the P2 GlassPill idiom (STATE.md 02-05 — GlassPill exposed public).
               return GlassPill(
                 child: Padding(
                   padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                   child: Text(text, style: /*theme titleSmall*/),
                 ),
               );
             },
           );
         }
       }
       ```
       - If `GlassPill` requires a `hasFallback` branching (P2 pattern), reuse both variants exactly as the existing FocusAreaPill does.

    4. `test/features/map/trip_fab_morph_test.dart`:
       - `ProviderContainer` overriding `trackingStateProvider` with a fixture Notifier that lets the test flip state.
       - Cases:
         - Initial idle → find red-dot icon by type/key `ValueKey('start')`; Semantics label == 'Start trip'
         - Flip state to TrackingRecording → find `ValueKey('stop')`; Semantics label == 'Stop trip'; find red container decoration color == 0xFFD32F2F
         - Tap in idle → `notifier.startManualCalled == 1`
         - Tap in recording → `notifier.stopActiveCalled == 1`

    5. `test/features/trips/presentation/live_tracking_panel_test.dart`:
       - Override trackingStateProvider with TrackingIdle → assert `SizedBox.shrink` (or `find.byType(GlassPill), findsNothing`).
       - Override with TrackingRecording(startedAt=1 min ago, distance=1500, speed=42) → assert `find.textContaining('Recording ·')` and `find.textContaining('1.5 km')`.
       - `pump(Duration(seconds:2))` twice → duration text advances (`00:59` → `01:01`).

    Anti-patterns to avoid:
    - Do NOT wrap `_StopVariant` in `LiquidGlass` — it must read as an emergency-action affordance (CONTEXT + RESEARCH decision).
    - Do NOT recompute the duration in the notifier — it's a UI clock; the notifier only exposes `startedAt` + `distanceMeters` + `currentSpeedKmh`.
    - Do NOT put the Timer inside the LiveTrackingPanel's ConsumerWidget without a State — that WILL leak on rebuild (Pitfall 4).
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test test/features/map/trip_fab_morph_test.dart test/features/trips/presentation/live_tracking_panel_test.dart` green
  </verify>
  <done>
    FAB morphs, panel renders + ticks, Timer is safely widget-owned.
  </done>
</task>

<task type="auto">
  <name>Task 2: Slot LiveTrackingPanel into map_screen + 30 s notification updater in notifier</name>
  <files>
    - lib/features/map/presentation/map_screen.dart
    - lib/features/trips/presentation/providers/tracking_state_provider.dart
  </files>
  <action>
    1. Edit `lib/features/map/presentation/map_screen.dart`:
       - Locate `_BottomChrome` (or equivalent bottom Column per STATE.md 02-05: "Chrome layout spec ... Column above FAB").
       - Insert `LiveTrackingPanel` above the recenter/FAB row and below any other above-nav chrome. Concretely: within the bottom Column, put `LiveTrackingPanel` first, then the existing row of RecenterButton + TripFab, then the BottomNavShell.
       - Match Phase 2's `visibility on Map tab only` rule (STATE.md 02-06): `if (currentIndex > 0) return SizedBox.shrink()` for the panel too.
       - Do NOT touch the Stack ordering, the Positioned attribution offset, or the RecenterButton column pattern.

    2. Edit `lib/features/trips/presentation/providers/tracking_state_provider.dart` (from Plan 03-04):
       - Add a `Timer? _notificationTicker` field.
       - When the state transitions from Idle → Recording (or is Recording on init), start:
         ```dart
         _notificationTicker?.cancel();
         _notificationTicker = Timer.periodic(const Duration(seconds: 30), (_) {
           final s = state;
           if (s is TrackingRecording) {
             final now = DateTime.now();
             final d = s.duration(now);
             final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
             final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
             final km = (s.distanceMeters / 1000).toStringAsFixed(1);
             final spd = s.currentSpeedKmh?.round().toString() ?? '—';
             ref.read(backgroundGeolocationFacadeProvider)
                 .setNotificationText('Recording · $mm:$ss · $km km · $spd km/h');
           }
         });
         ```
       - Cancel on Recording → Idle transition and via `ref.onDispose`.
       - Alternatively (cleaner): move this whole ticker into `TrackingService` itself, so it lives alongside dwell/resume timers. Prefer this — keeps the notifier a pure adapter.
       - Wire choice: **implement inside `TrackingService`** — add a `_notificationTicker` field there, start it in the same places `_openTrip(...)` runs, stop it in `_closeTrip(...)` / `stopActive`. This localizes lifecycle. Update Plan 03-04's file if needed — but do NOT re-run Plan 03-04's tests: they use FakeBackgroundGeolocationFacade which records `lastNotificationText`; the tests already have an assertion hook.
       - Extend the Fake in `test/helpers/fake_background_geolocation_facade.dart`: track a list `List<String> notificationTexts` and assert in Plan 03-04's tests that the list receives entries when running through recording with fake_time or manual test-driven timer advance. (This test enhancement is optional if fake_async isn't in devDeps; document as "verified on-device only" in that case.)

    Anti-patterns to avoid:
    - Do NOT update the notification on every fix (RESEARCH.md: "1 Hz updates would waste battery").
    - Do NOT tie the 30 s timer to a widget lifecycle — the trip may run while no widget is watching (Android background).
    - Do NOT move the FAB/Recenter positioning — STATE.md flags the 15-commit iteration behind the P2 chrome layout; don't re-open that fight.
  </action>
  <verify>
    - `flutter analyze` clean
    - `flutter test` full suite green (Phase 2 map layout tests still pass)
  </verify>
  <done>
    LiveTrackingPanel slots in above the FAB row; 30 s notification updater lives inside TrackingService.
  </done>
</task>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 3: End-to-end trip lifecycle on device</name>
  <what-built>
    Full P3 recording UI: morphing FAB, live panel, live-updating Android notification, capable of running through a real short drive.
  </what-built>
  <how-to-verify>
    Do a short drive (or a walk if driving is not feasible right now) with the S24 device:
    1. `flutter run --debug` on Samsung Galaxy S24.
    2. Open the app → land on the map. FAB shows the P2 red-dot glass circle.
    3. Tap FAB. Verify:
       - FAB morphs to a red circle with a white square icon (200 ms fade)
       - LiveTrackingPanel appears above the FAB row: `Recording · 00:00 · 0.0 km · — km/h`
       - Android notification appears with the same text
    4. Wait/drive 30 s. Verify:
       - Panel text updates every second (MM:SS advances)
       - Notification text updates within 30 s
    5. Drive/walk ~200 m. Verify distance climbs realistically (should be < GPS-perfect but sane).
    6. Lock the screen for 60 s. Confirm the notification stays visible.
    7. Tap the notification → verify the app foregrounds to the map with the overlay still showing.
    8. Tap the red Stop FAB. Verify:
       - Panel disappears
       - FAB morphs back to the P2 look
       - Notification disappears (or Android may keep it a moment; that's OS-side)
       - A `pending` trip row exists in the DB (verify via a debug print in the notifier's `stopActive`, or by leaving a debug log at info level in `TripsRepository.closeTrip`).
    9. Repeat with a sub-30 s stop (walk 5 s, tap Stop) → verify NO trip row is created (keeper threshold).

    Optional stretch: kill the app process mid-drive (Force Stop from Recent Apps), then re-open — verify overlay reconstructs from the in-flight trip row. This is the cold-start hydration flow.
  </how-to-verify>
  <resume-signal>
    Type "approved" if the full manual round-trip works cleanly. If auto-tracking is not yet observable (the drive is short), that's OK — the 60-min baseline in Plan 03-07 exercises the auto path.
  </resume-signal>
</task>

</tasks>

<verification>
- `flutter analyze` clean
- `flutter test` full suite green
- On-device checkpoint approved
- Commit: `feat(03-06): FAB morph + live tracking panel + 30s notification updater`
</verification>

<success_criteria>
- Manual trip lifecycle is fully user-visible on Android
- iOS has the equivalent visual (blue bar automatic + panel + FAB morph) — deferred device test
- 60-min drive in Plan 03-07 exercises the auto path + notification longevity
</success_criteria>

<output>
After completion, create `.planning/phases/03-tracking-mvp/03-06-SUMMARY.md`
</output>
