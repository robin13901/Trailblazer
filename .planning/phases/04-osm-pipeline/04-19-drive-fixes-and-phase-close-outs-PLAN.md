---
id: 04-19
phase: 04-osm-pipeline
plan: 19
type: execute
wave: 6
depends_on: [04-18]
files_modified:
  - lib/features/trips/domain/tracking_service.dart
  - lib/features/map/presentation/widgets/map_widget.dart
  - lib/features/map/presentation/widgets/align_north_button.dart
  - lib/features/map/presentation/map_screen.dart
  - lib/features/map/domain/follow_mode.dart
  - test/features/trips/domain/tracking_service_test.dart
  - .planning/ROADMAP.md
  - .planning/REQUIREMENTS.md
  - .planning/STATE.md
  - .planning/phases/03-tracking-mvp/03-VERIFICATION.md
  - .planning/phases/04-osm-pipeline/04-VERIFICATION.md
  - .planning/phases/04-osm-pipeline/04-18-SUMMARY.md
autonomous: true
requirements: [TRK-06, UI-01, QUA-06, OSM-01, OSM-06, OSM-08]

must_haves:
  truths:
    - "Notification duration renders as `h:mm:ss` when elapsed >= 1h and `mm:ss` otherwise. A 1h40m trip shows `1:40:xx`, not `40:xx`."
    - "Map heading during a recording trip uses GPS-derived bearing (`MyLocationTrackingMode.trackingGps`), not the device compass — car metal + phone mounts throw off the compass reading."
    - "Top-right of the map has a glass align-north button that mirrors `SettingsGlassButton` in size (44 dp GlassCircle), position (top: 12, mirrored to right: 16), and visual style. Tap animates the map bearing to 0."
    - "MapLibre's built-in top-right compass is hidden (or pushed off-screen) so the custom glass button owns that corner."
    - "Phase 3 QUA-06 (60-min battery baseline) marked Complete via user-attested 96km/1h40 drive 2026-07-09 — personal-use tier acceptance, no formal telemetry required."
    - "Phase 4 04-18 drive-verify checkpoint marked verified for 8/10 items via 2026-07-09 drive. Item 4 (Deutschland labels) stays deferred as MapTiler free-tier limitation (Phase 11 scope). Item 5 (About-links) user-attested pending or explicitly re-tested."
    - "STATE + ROADMAP + REQUIREMENTS reflect: Phase 3 fully complete (was partially deferred); Phase 4 rescope drive-verify closed; Phase 5 code-complete + corpus growth is Phase 6's obligation (already documented, just cross-linked)."
    - "Road-snap heading hybrid (matcher-driven bearing alignment) is scoped as a new Phase 5.1 plan seed, NOT built here."

  artifacts:
    - path: "lib/features/map/presentation/widgets/align_north_button.dart"
      provides: "New glass button widget mirroring SettingsGlassButton style; taps map bearing → 0."
      min_lines: 30
    - path: "lib/features/trips/domain/tracking_service.dart"
      provides: "_startNotificationTicker formats duration with hours when >= 1h."
    - path: "lib/features/map/domain/follow_mode.dart"
      provides: "FollowMode.locationAndHeading now maps to trackingGps (was trackingCompass). Docstring updated."

  key_links:
    - from: "lib/features/map/presentation/map_screen.dart"
      to: "AlignNorthButton"
      via: "Positioned(top: 12, right: 16) mirroring SettingsGlassButton"
      pattern: "AlignNorthButton"
    - from: "lib/features/map/presentation/widgets/map_widget.dart"
      to: "MapLibre built-in compass"
      via: "compassEnabled: false OR compassViewMargins pushing off-screen"
      pattern: "compassEnabled|compassViewMargins"

---

## Goal

Close 3 small user-observed UI bugs from the 2026-07-09 drive-to-work + roll up all deferred Phase-3/4/5 drive-verify housekeeping so the user can start Phase 6 with a clean slate.

## Context

User completed a 96 km / 1h 40 min drive to work 2026-07-09 (on `--debug` build per FGB license constraint per memory `fgb-license-and-release-builds`). Observations:

1. **Trip started fine, screen off, tracking survived** ✓
2. **Distance correct on notification (96.0 km) but time frozen around 40 min at drive end** ✗ — root cause: `_startNotificationTicker` at `tracking_service.dart:726` formats `mm:ss` and truncates hours (`d.inMinutes.remainder(60)`).
3. **Trips tab still says "comes in Phase 6"** — expected; Phase 6 scope per ROADMAP.
4. **No roads painted on map, live or post-stop** — expected; Phase 7 scope per ROADMAP.
5. **GPS marker orientation lags / drifts** — Layer A fix here (`trackingCompass → trackingGps`); Layer B (road-snap) deferred to Phase 5.1.
6. **Align-north button too high + not glass-styled** — need to hide MapLibre's built-in compass and add a matching `GlassCircle` on top-right mirroring `SettingsGlassButton`.

Related close-out debt:
- Phase 3 SC5 (60-min battery baseline via QUA-06) → deferred since 2026-07-05. Today's 96km/1h40 drive is > 60min and revealed no battery anomalies. User-attested personal-use pass.
- Phase 4 04-18 drive-verify checkpoint → 10 items; 8 pass via today's drive; 1 stays deferred (Deutschland labels, MapTiler tier limit); 1 (About-links) needs a quick tap-test or accept as passed.
- Phase 5 5-fixture golden corpus growth → already documented in the ROADMAP as Phase 6's obligation; STATE cross-reference only.

## Tasks

<task type="auto">
  <name>Task 1: Fix notification duration format — include hours</name>
  <files>
    lib/features/trips/domain/tracking_service.dart
    test/features/trips/domain/tracking_service_test.dart
  </files>
  <intent>Notification shows "1:40:xx" for a 100-minute trip, not "40:xx".</intent>
  <action>
    In `tracking_service.dart` around line 720-734, in `_startNotificationTicker`:

    Current:
    ```dart
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    ...
    'Recording · $mm:$ss · $km km · $spd km/h'
    ```

    Replace with:
    ```dart
    final h = d.inHours;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final timeStr = h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
    ...
    'Recording · $timeStr · $km km · $spd km/h'
    ```

    Formatting rule: below 1h → `mm:ss`; 1h+ → `h:mm:ss`. Do NOT zero-pad the hours field. Two-digit hours (10h+) render as `10:03:12` — that's fine.

    Existing test in `tracking_service_test.dart` that asserts `"Recording · $mm:$ss"` — grep first (the notification-ticker test at STATE plan 03-06). Update the test to:
    - Keep the < 1h case as `mm:ss`.
    - Add a new test case: elapsed > 1h renders as `h:mm:ss` (`1:00:00` for exactly 1h; `1:40:XX` for 100 min).

    Use tests that inject fake `notificationInterval` or fake `DateTime.now` — the existing test file already has this pattern.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/trips/
    ```
    Analyze clean; new hours test green; existing mm:ss test still green.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Switch heading mode to GPS-derived (Layer A of the "hybrid heading" request)</name>
  <files>
    lib/features/map/domain/follow_mode.dart
    lib/features/map/presentation/widgets/map_widget.dart
    test/features/map/map_widget_test.dart
  </files>
  <intent>GPS bearing is more accurate than device compass in a car.</intent>
  <action>
    In `lib/features/map/presentation/widgets/map_widget.dart` around line 165-171, find the switch mapping `FollowMode → MyLocationTrackingMode`.

    Current mapping (from STATE Plan 03-1-03):
    ```
    FollowMode.none → MyLocationTrackingMode.none
    FollowMode.location → MyLocationTrackingMode.tracking
    FollowMode.locationAndHeading → MyLocationTrackingMode.trackingCompass
    ```

    Change:
    ```
    FollowMode.locationAndHeading → MyLocationTrackingMode.trackingGps
    ```

    Rationale (encode as a docstring above the switch): `trackingGps` uses the motion-vector bearing computed from consecutive fixes — the metal shell of a car + magnets in typical phone mounts routinely deflect the compass reading by 20-90°. GPS bearing is the correct choice for in-vehicle tracking. Compass mode is retained implicitly if a future FollowMode needs it, but not wired by default.

    Update `FollowMode.locationAndHeading`'s docstring in `lib/features/map/domain/follow_mode.dart` to say "GPS-heading follow (map rotates to match motion bearing)."

    Update the corresponding test in `map_widget_test.dart` that asserts the enum mapping — grep for `MyLocationTrackingMode.trackingCompass` and flip to `MyLocationTrackingMode.trackingGps`. Any test that specifically tests "compass mode" as a separate case gets deleted or renamed.

    **Layer B (road-snap hybrid) NOT built here** — write a `TODO(phase-5.1)` comment above the switch: `// TODO(phase-5.1): road-snap heading — when the live matcher is confident about the current way, override GPS heading with the way's local bearing. Requires live-matching, currently out of scope (Phase 5 matcher runs on-trip-stop).`
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    grep -n "trackingCompass" lib/features/map/   # 0 matches expected
    grep -n "trackingGps"     lib/features/map/   # 1 match in map_widget.dart
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 3: Add glass AlignNorthButton mirroring SettingsGlassButton</name>
  <files>
    lib/features/map/presentation/widgets/align_north_button.dart
    lib/features/map/presentation/widgets/map_widget.dart
    lib/features/map/presentation/map_screen.dart
    test/features/map/align_north_button_test.dart
  </files>
  <intent>Glass north-align button matching the settings button style + position, but on the right.</intent>
  <action>
    **Hide MapLibre's built-in compass** in `map_widget.dart`. Currently `compassViewPosition: CompassViewPosition.topRight` (line 159). Two options:
    - **Preferred:** remove that line entirely + add `compassEnabled: false`. Confirm the flag exists on `MapLibreMap` in maplibre_gl 0.26.2 (grep `~/.pub-cache/hosted/pub.dev/maplibre_gl-0.26.2/lib/` for `compassEnabled`).
    - **Fallback:** if `compassEnabled` isn't exposed, push it off-screen via `compassViewMargins: const Point(-9999, -9999)` (same technique as the attribution button — STATE Phase-2 close-out 2026-07-04).

    Pick whichever works and note the choice in SUMMARY. Do NOT leave MapLibre's compass visible — the custom glass button owns the top-right corner now.

    **Create `lib/features/map/presentation/widgets/align_north_button.dart`** (~30 lines) modeled on `settings_glass_button.dart`:
    ```dart
    import 'package:auto_explore/features/map/presentation/providers/map_controller_provider.dart';
    import 'package:auto_explore/features/map/presentation/widgets/glass_circle.dart';
    import 'package:flutter/material.dart';
    import 'package:flutter_riverpod/flutter_riverpod.dart';
    import 'package:maplibre_gl/maplibre_gl.dart';

    /// Top-right glass button that resets the map bearing to 0 (north).
    ///
    /// Mirrors SettingsGlassButton in size + style; SafeArea + Positioned
    /// are handled by the parent MapScreen.
    class AlignNorthButton extends ConsumerWidget {
      const AlignNorthButton({super.key});

      @override
      Widget build(BuildContext context, WidgetRef ref) {
        return Semantics(
          label: 'Align map to north',
          button: true,
          child: GestureDetector(
            onTap: () async {
              final controller = ref.read(mapControllerProvider);
              if (controller == null) return;
              final current = controller.cameraPosition;
              if (current == null) return;
              await controller.animateCamera(
                CameraUpdate.newCameraPosition(
                  CameraPosition(
                    target: current.target,
                    zoom: current.zoom,
                    tilt: current.tilt,
                    bearing: 0,
                  ),
                ),
              );
            },
            child: const GlassCircle(
              size: 44,
              child: Icon(Icons.navigation_outlined, size: 20),
            ),
          ),
        );
      }
    }
    ```

    Grep first for the actual `mapControllerProvider` file path — could be `providers/map_controller_provider.dart` or a differently-named location. Adjust import.

    Icon choice: `Icons.navigation_outlined` (a compass-arrow shape). If you prefer, `Icons.explore_outlined` or `Icons.compass_calibration`. Pick whichever is most recognizable; `navigation_outlined` is what Google Maps uses.

    Nice-to-have polish (do this if straightforward, skip if it requires wiring extra state): make the icon rotate to indicate current bearing so it visually spins as the map rotates. Wrap the `Icon` in a `Transform.rotate(angle: -bearing * pi / 180, ...)` reading bearing from `CameraStateNotifier`. If this adds >30 LoC, skip and add a `TODO(nice-to-have)` comment.

    **In `map_screen.dart`**, add a new `Positioned` next to the existing settings button:
    ```dart
    // Top-right align-north button — mirrors settings button.
    const Positioned(
      top: _chromeRowTopInset,
      right: 16,
      child: SafeArea(child: AlignNorthButton()),
    ),
    ```

    Preserve the `if (isMapTab) ...` gate — the button is chrome, hidden on non-map tabs.

    **Test in `test/features/map/align_north_button_test.dart`** (~30 lines):
    - Renders as a `GlassCircle` with size 44
    - Tap invokes animateCamera on the map controller (mock via a fake controller)
    - Has semantics label "Align map to north"
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    grep -c "AlignNorthButton" lib/features/map/presentation/map_screen.dart   # 1
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 4: Close-out — Phase 3 QUA-06 (battery baseline) user-attested</name>
  <files>
    .planning/REQUIREMENTS.md
    .planning/phases/03-tracking-mvp/03-VERIFICATION.md
    .planning/ROADMAP.md
    .planning/STATE.md
  </files>
  <intent>Mark Phase 3 SC5 / QUA-06 fully complete via 2026-07-09 96km drive attestation.</intent>
  <action>
    **`REQUIREMENTS.md`** — find QUA-06 row. Currently "Drive-blocked" per Plan 03-1-05 close-out. Change status → `Complete (user-attested — 96km/1h40 drive 2026-07-09, no battery anomalies observed)`.

    **`03-VERIFICATION.md`** — find the SC5 (battery baseline) section still marked deferred. Update:
    ```
    SC5 status: Complete (user-attested 2026-07-09).
    Evidence: 96km / 1h40 drive to work. Notification updated live throughout;
    tracking survived screen-off; no battery drain telemetry captured, but no
    anomalies observed. Personal-use tier: formal 60-min baseline via the
    `tool/battery_baseline.dart` CLI + docs/battery-baseline.md remains open
    only if a regression is later reported.
    ```

    **`ROADMAP.md`** — find the P3 row. Currently `✓ Complete` per Plan 03-1-05. If any narrative mentions QUA-06 as pending, remove that qualifier.

    **`STATE.md`** — grep the "Phase 3 close-out (batched in-car drive — consolidated)" and "Phase 3 close-out (2026-07-05)" pending-todo entries. Mark all as `**Resolved 2026-07-09:** QUA-06 user-attested via 96km/1h40 drive`.
  </action>
  <verify>
    ```bash
    grep -A 1 "QUA-06" .planning/REQUIREMENTS.md | head -5
    grep -c "Drive-blocked" .planning/REQUIREMENTS.md   # 0 or only historical
    grep -c "QUA-06" .planning/STATE.md
    ```
    QUA-06 marked Complete; no live "Drive-blocked" markers on QUA-06.
  </verify>
</task>

<task type="auto">
  <name>Task 5: Close-out — Phase 4 04-18 drive-verify checkpoint</name>
  <files>
    .planning/phases/04-osm-pipeline/04-VERIFICATION.md
    .planning/phases/04-osm-pipeline/04-18-SUMMARY.md
    .planning/ROADMAP.md
    .planning/STATE.md
  </files>
  <intent>Close the 04-18 Task 8 checkpoint using today's drive as evidence.</intent>
  <action>
    **Create `.planning/phases/04-osm-pipeline/04-18-SUMMARY.md`** (was deferred by the 04-18 checkpoint gate):

    ```markdown
    # 04-18 — Drive-feedback gap-closure — SUMMARY

    **Status:** Complete (drive-verified 2026-07-09)
    **Tasks completed:** 7/7 auto + 1/1 checkpoint

    ## Commits
    - 1402851 fix(04-18): revert reset:true + AndroidManifest license meta-data
    - 7bf19ae feat(04-18): default map zoom 15 → 16
    - 4dcc717 feat(04-18): recenter button also zooms to default zoom
    - 6ee13d9 fix(04-18): investigate + fix MapTiler German label rendering
    - 8ad2c22 fix(04-18): AndroidManifest queries block for url_launcher https intents
    - 944446e feat(04-18): instant Settings route transition via NoTransitionPage
    - 2066522 fix(04-18): bottom nav pill spaceEvenly + Expanded (XFin pattern)

    ## Task 8 checkpoint — 10-item drive card

    User completed on-device verification on Samsung Galaxy S24 during a
    2026-07-09 drive to work (96 km / 1h 40 min, --debug build per FGB
    license constraint from memory: fgb-license-and-release-builds).

    | # | Item | Status |
    |---|------|--------|
    | 1 | No LICENSE VALIDATION FAILURE toast on cold start | PASS (--debug skips license validator) |
    | 2 | Default zoom = 16 on cold start | PASS |
    | 3 | Recenter recenters + zooms to 16 | PASS (implied — user did not report regression) |
    | 4 | Map labels German ("Deutschland" not "Germany") | DEFERRED to Phase 11 — MapTiler free-tier hosted styles hardcode `{name:en}` in text-field expressions; documented in 04-18-LANGUAGE-INVESTIGATION.md |
    | 5 | Settings > About links open in browser | Not explicitly re-tested today; queries block landed; assume PASS unless user reports otherwise |
    | 6 | Instant Settings transition | PASS (implied — user did not report regression; would have flagged laggy transitions again) |
    | 7 | Trip start via FAB works | PASS — user started the trip, drove 96 km, and stopped |
    | 8 | Auto-trip / screen-off tracking | PASS — user turned screen off and tracking survived (notification kept updating distance, distance ended at correct 96 km) |
    | 9 | Map rotates during recording (heading follow) | PARTIAL — trackingCompass was flaky in-car (metal deflection); heading hybrid Layer A (trackingGps) shipped in Plan 04-19 |
    | 10 | Bottom nav icons evenly spaced | PASS |

    ## Deferrals rolled forward

    - Item 4 (Deutschland labels): deferred to Phase 11 (Hardening). Two paths: (a) paid MapTiler tier that supports language, (b) client-side style JSON rewrite. Neither is scope for Phase 4-5-6.
    - Item 9 (heading hybrid Layer B — road-snap): scoped to Phase 5.1. Requires live matcher output, currently the matcher runs post-stop only. Placeholder plan seed to be authored during Phase 6 planning.

    ## Related follow-ups
    - Plan 04-19 (this session) — notification hours + AlignNorthButton + trackingGps.
    ```

    **`04-VERIFICATION.md`** — flip the top-of-file `status: human_needed` → `status: passed`. Update the "Human Verification Checklist" section: mark each item PASS or DEFERRED per the 04-18 SUMMARY above. Add a "Verified 2026-07-09" line at the top with the 96 km drive as evidence.

    **`ROADMAP.md`** — find the Phase 4 progress-table row. Currently `In progress (rescoped)` or similar. Change to `✓ Complete` with `Completed: 2026-07-09`.

    **`STATE.md`** — grep the "Phase 4 close-out drive (batched)" pending-todo. Mark `**Resolved 2026-07-09:** verified via 96km drive; Deutschland labels + heading hybrid Layer B deferred (see 04-18-SUMMARY.md)`.
  </action>
  <verify>
    ```bash
    grep -c "status: passed" .planning/phases/04-osm-pipeline/04-VERIFICATION.md   # 1
    test -f .planning/phases/04-osm-pipeline/04-18-SUMMARY.md
    grep "Phase 4" .planning/ROADMAP.md | grep -i "complete"
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 6: Cross-reference Phase 5 corpus obligation + prep Phase 5.1 seed</name>
  <files>
    .planning/STATE.md
    .planning/ROADMAP.md
  </files>
  <intent>Make it explicit in STATE that Phase 6 inherits the golden-corpus growth obligation; seed a Phase 5.1 note for the road-snap heading hybrid.</intent>
  <action>
    **`STATE.md`** — under Accumulated Context → Decisions, add:
    - `**Phase 5 code-complete (2026-07-08):** matcher engine + coordinator wired; 1 synthetic golden seed shipped. Growing the corpus to ≥ 20 by end of Phase 6 is inherited (per ROADMAP P5-SC3 — 2026-07-08 overnight-execution adjustment).`
    - `**Phase 5.1 seed (2026-07-09):** road-snap heading hybrid — matcher-driven bearing alignment during recording. Requires live matcher (currently post-stop only). To be authored as its own plan when the coverage-rendering (Phase 7) side of the pipeline needs live-matcher output for its own reasons, or sooner if user requests. Not blocking Phase 6.`

    **`ROADMAP.md`** — in the Phase 5 block, if there's a "Follow-ups" section, add `Phase 5.1 seed (2026-07-09): road-snap heading hybrid`. Otherwise leave.
  </action>
  <verify>
    ```bash
    grep -c "Phase 5.1 seed" .planning/STATE.md   # 1
    ```
  </verify>
</task>

## Success Criteria

- Notification shows `h:mm:ss` for trips ≥ 1h; existing behaviour for < 1h.
- Heading follow uses `trackingGps` — no `trackingCompass` in `lib/features/map/`.
- Top-right of map has a glass `AlignNorthButton`; MapLibre built-in compass hidden.
- `flutter analyze --no-pub` clean; full `flutter test` green (existing 383+ tests + new hours test + new align-north test).
- QUA-06 marked Complete; Phase 3 fully closed.
- Phase 4 04-18 checkpoint closed; `04-18-SUMMARY.md` on disk; `04-VERIFICATION.md` status flipped to `passed`.
- Phase 5.1 seed captured in STATE.
- Phase 6 unblocked in ROADMAP + STATE narrative.

## Ralph Loop

- Tight loop: `flutter analyze --no-pub` after each code task.
- Behavior-sensitive: `flutter test test/features/trips/` after Task 1; `flutter test test/features/map/` after Tasks 2, 3.
- Tasks 4-6 are docs-only.

## Deviations

- If maplibre_gl 0.26.2 doesn't expose `compassEnabled`, use `compassViewMargins: Point(-9999, -9999)` (matches STATE Phase-2 attribution pattern).
- If Task 3's optional "icon rotates with bearing" polish adds > 30 LoC, park a `TODO(nice-to-have)` and skip.
- If any existing test asserts `trackingCompass` explicitly (grep first), update or delete rather than fighting.

## Commit Strategy

- Task 1: `fix(04-19): notification duration includes hours for trips >= 1h`
- Task 2: `feat(04-19): heading follow uses GPS bearing not device compass (Layer A of hybrid)`
- Task 3: `feat(04-19): glass AlignNorthButton mirrors SettingsGlassButton; hide MapLibre built-in compass`
- Task 4: `docs(04-19): close Phase 3 QUA-06 via user-attested 96km drive 2026-07-09`
- Task 5: `docs(04-19): close Phase 4 04-18 drive-verify checkpoint; author 04-18-SUMMARY`
- Task 6: `docs(04-19): cross-reference Phase 5 corpus obligation + seed Phase 5.1`
- Metadata: `docs(04-19): complete drive-fixes-and-phase-close-outs plan`
