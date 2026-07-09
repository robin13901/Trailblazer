---
phase: 04-osm-pipeline
plan: 19
subsystem: tracking + map + docs (drive-fix + phase close-out)
tags: [drive-fix, notification-hours, tracking-gps, align-north-button, glass-chrome, phase-close-out, phase-3, phase-4, phase-5.1-seed]

# Dependency graph
requires:
  - phase: 04-osm-pipeline
    provides: Code-complete rescope (04-11..04-17 + 04-16-1) + 04-18 drive-feedback gap-closure; 2026-07-09 96 km / 1h 40 drive to work supplied observations
  - phase: 03-tracking-mvp
    provides: TrackingService notification ticker (03-06), permission ladder (03-05); QUA-06 drive-deferred
  - phase: 05-overpass-backed-matcher
    provides: Post-stop matcher pipeline; live-matcher variant is out of scope (Phase 5.1 seed captures the road-snap Layer B)

provides:
  - Notification duration renders `h:mm:ss` for trips >= 1h; `mm:ss` below (Task 1)
  - FollowMode.locationAndHeading maps to `MyLocationTrackingMode.trackingGps` — GPS-motion bearing during recording (Task 2, Layer A of hybrid heading)
  - Glass `AlignNorthButton` at top-right of the map, mirroring `SettingsGlassButton` at top-left; MapLibre built-in compass hidden via `compassEnabled: false` (Task 3)
  - Phase 3 fully closed — QUA-06 flipped Drive-blocked → Complete via user-attested 96 km / 1h 40 drive 2026-07-09 (Task 4)
  - Phase 4 rescope drive-verified — 04-VERIFICATION.md `status: human_needed` → `status: passed`; 04-18-SUMMARY.md authored (Task 5)
  - Phase 5 corpus growth cross-linked as Phase 6's obligation; Phase 5.1 seed captured for road-snap heading hybrid Layer B (Task 6)

affects: [06-inbox-and-match-wireup, 05-1-road-snap-heading-hybrid (seed), 11-hardening (Deutschland-labels deferred)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Library-scope formatter helper for notification pill: `formatNotificationDuration(Duration)` in tracking_service.dart, exercised by 4 direct unit tests without spinning up TrackingService."
    - "In-vehicle heading follow via `MyLocationTrackingMode.trackingGps` (not `.trackingCompass`) — motion-vector bearing survives car metal + phone-mount magnets."
    - "Glass chrome button pattern replicated with `ConsumerWidget` + bearing-rotation icon: AlignNorthButton reads `cameraStateProvider.bearing`, wraps its Icon in `Transform.rotate(angle: -bearing * pi / 180)`, and animates camera bearing to 0 on tap while preserving target/zoom/tilt."
    - "MapLibre built-in top-right compass hidden via `compassEnabled: false` (exposed by maplibre_gl 0.26.2 — grep-verified in pub-cache maplibre_map.dart:22/136/492/571)."

key-files:
  created:
    - lib/features/map/presentation/widgets/align_north_button.dart
    - test/features/map/align_north_button_test.dart
    - .planning/phases/04-osm-pipeline/04-18-SUMMARY.md
  modified:
    - lib/features/trips/domain/tracking_service.dart
    - test/features/trips/domain/tracking_service_test.dart
    - lib/features/map/domain/follow_mode.dart
    - lib/features/map/presentation/widgets/map_widget.dart
    - lib/features/map/presentation/map_screen.dart
    - test/features/map/map_widget_follow_mode_test.dart
    - test/features/map/map_widget_test.dart
    - .planning/REQUIREMENTS.md
    - .planning/ROADMAP.md
    - .planning/STATE.md
    - .planning/phases/03-tracking-mvp/03-VERIFICATION.md
    - .planning/phases/04-osm-pipeline/04-VERIFICATION.md

key-decisions:
  - "Notification duration hours field is NOT zero-padded — a 10 h drive renders as `10:03:12`. Acceptable for the pill; matches most in-car nav conventions."
  - "Layer A (trackingGps) shipped here; Layer B (road-snap via live matcher) DEFERRED to Phase 5.1 seed. Requires a live-matcher variant, currently post-stop only."
  - "AlignNorthButton ships the optional 'icon rotates with bearing' polish because CameraStateNotifier already exposes bearing (STATE Plan 02-03) — no extra state wiring needed; ~10 additional LoC well under the 30-LoC skip threshold in the plan."
  - "MapLibre's `compassEnabled: false` is the cleaner path (exposed by maplibre_gl 0.26.2) — did NOT need the Point(-9999, -9999) off-screen fallback from the plan §Deviations."
  - "QUA-06 acceptance is personal-use tier: user-attested drive is authoritative; formal battery_baseline.dart CLI + artifacts kept as regression-investigation template only."
  - "Deutschland-labels DEFERRED to Phase 11 (MapTiler free-tier limitation, documented in 04-18-LANGUAGE-INVESTIGATION.md) — same trajectory as the original 04-18 Task 8 checkpoint decision."
  - "04-15 Scenarios B (offline-drain) + C (cache-hit) and 04-16 Scenarios D + E DEFERRED — not exercised on the 2026-07-09 single-corridor drive; code-complete + unit-tested; non-blocking for Phase 6."

patterns-established:
  - "Combined drive-fix + phase-close-out plan: 3 code tasks (drive fixes observed on the drive) + 3 docs tasks (P3/P4 close-outs + P5 cross-refs) landing as 6 atomic commits + 1 metadata commit. Same-day drive-observation → drive-fix → phase-close cycle when the drive doubles as verification for a previously deferred SC."
  - "Bearing-aware chrome button: `ConsumerWidget` reads `cameraStateProvider.bearing` and wraps the icon in `Transform.rotate(angle: -bearing * pi / 180)`. Works for compass icons, north-align, and any other chrome that should track true north as the map rotates."
  - "Formatter helper extracted to library-scope for unit-test isolation: `formatNotificationDuration(Duration)` sits above the class in tracking_service.dart so 4 test cases exercise it without spinning up TrackingService + FakeBackgroundGeolocationFacade + in-memory Drift."

# Metrics
duration: ~55 min
completed: 2026-07-09
---

# Phase 4 Plan 19: Drive-Fixes and Phase Close-Outs Summary

**Six commits: 3 drive-fix code tasks (notification hours, GPS heading follow, glass AlignNorthButton) + 3 docs close-out tasks (Phase 3 QUA-06 flipped Complete, Phase 4 04-18 drive-verify closed, Phase 5 corpus cross-refs + Phase 5.1 seed). 393/393 tests green; `flutter analyze --no-pub` clean. Phase 3 fully closed; Phase 4 rescope drive-verified; Phase 6 unblocked.**

## Performance

- **Duration:** ~55 min
- **Started:** 2026-07-09 (session after the 96 km / 1h 40 drive to work)
- **Completed:** 2026-07-09
- **Tasks:** 6 executed + 1 metadata commit
- **Files created:** 3 (`align_north_button.dart`, `align_north_button_test.dart`, `04-18-SUMMARY.md`)
- **Files modified:** 12 (see key-files section)

## Task Commits

Each task was committed atomically with individual file staging (no `git add -A` / `git commit -a`):

1. **Task 1: Notification duration format — include hours** — `bb16010` (fix)
   - `formatNotificationDuration(Duration)` extracted to library-scope in `tracking_service.dart`; renders `mm:ss` below 1 h and `h:mm:ss` at 1 h+. Hours field is not zero-padded (10:03:12 is fine).
   - 4 new formatter tests: < 1 h → `mm:ss`, exactly 1 h → `1:00:00`, 100-min regression case → `1:40:27`, 10 h+ → `10:03:12`.
   - Root cause of the 2026-07-09 drive observation: prior code truncated hours via `d.inMinutes.remainder(60)` → showed `40:xx` at 1h 40 min.
2. **Task 2: Heading follow uses GPS bearing (Layer A of hybrid)** — `a908bf4` (feat)
   - `FollowMode.locationAndHeading` in `map_widget.dart` now maps to `MyLocationTrackingMode.trackingGps` (was `trackingCompass`). Docstring on the enum variant + inline comment above the switch spell out the in-vehicle rationale (car metal + phone-mount magnets deflect compass 20–90°).
   - `TODO(phase-5.1)` marker parked above the switch — Layer B road-snap requires live matcher output (out of scope for Phase 5 which runs post-stop only).
   - `map_widget_follow_mode_test.dart` third assertion flipped to `trackingGps`.
3. **Task 3: Glass AlignNorthButton + hide MapLibre built-in compass** — `9dbc8dc` (feat)
   - New `lib/features/map/presentation/widgets/align_north_button.dart` — 44 dp `GlassCircle` mirroring `SettingsGlassButton` size + style. Tap reads `controller.cameraPosition` and animates bearing to 0 (fail-soft on null controller or camera position). Icon `Icons.navigation_outlined` at 20 dp counter-rotates with `CameraState.bearing` so the arrow always tracks true north (~10 LoC polish shipped because bearing was already exposed by `CameraStateNotifier`, well under the plan's 30-LoC skip threshold).
   - `map_widget.dart`: `compassEnabled: false` (exposed by maplibre_gl 0.26.2 — grep-verified in pub-cache) replaces the old `compassViewPosition: CompassViewPosition.topRight`. The Point(-9999, -9999) fallback from plan §Deviations was NOT needed.
   - `map_screen.dart`: new `Positioned(top: _chromeRowTopInset, right: 16, child: SafeArea(child: AlignNorthButton()))` next to the top-left settings button; gated by the existing `if (isMapTab) ...` chrome guard.
   - 6 new widget tests: 44 dp GlassCircle; navigation icon 20 dp; Semantics label; bearing=0 → identity rotation; bearing=90 → -pi/2 rotation; fail-soft tap when no controller wired.
   - `map_widget_test.dart`: previous `compass is enabled and positioned at topRight` test replaced with a `compassEnabled: false` assertion tied to the AlignNorthButton contract.
4. **Task 4: Close Phase 3 QUA-06 via user-attested 96 km drive** — `83e2c50` (docs)
   - REQUIREMENTS.md: QUA-06 row + traceability line + footer updated. Complete (user-attested — 96 km / 1h 40 drive 2026-07-09, no battery anomalies observed).
   - 03-VERIFICATION.md: frontmatter score 4/5 → 5/5; SC5 rewritten from DRIVE-BLOCKED to VERIFIED; requirement coverage table QUA-06 flipped; SC5 in-car checklist renamed as "template only" for future regression investigations; footer dates updated.
   - ROADMAP.md: Phase 3 completion narrative + progress-table row cite the 2026-07-09 SC5 attestation.
   - STATE.md: "Phase 3 close-out (batched in-car drive — consolidated)" pending todo marked RESOLVED 2026-07-09 with SC5 fold-in note.
5. **Task 5: Close Phase 4 04-18 drive-verify checkpoint; author 04-18-SUMMARY** — `e60cb42` (docs)
   - 04-18-SUMMARY.md authored: 7 auto-task commit list + 10-item drive card status table (7 PASS / 1 DEFERRED to Phase 11 / 1 assume-PASS-unless-reported / 1 PARTIAL rolled into 04-19) + deferrals rolled forward + Plan 04-19 cross-reference.
   - 04-VERIFICATION.md: frontmatter `status: human_needed` → `status: passed`; header + narrative updated for 2026-07-09; SC3 CODE-COMPLETE → PASS; SC5 status narrative updated; Human Verification Checklist fully rewritten with per-item PASS/DEFERRED marks + observed drive-fix cross-links to Plan 04-19.
   - ROADMAP.md: master list-item + phase-block narrative + progress-table row all flipped to Complete.
   - STATE.md: "Phase 4 close-out drive (batched — 2026-07-08)" pending todo marked RESOLVED 2026-07-09 with per-scenario disposition.
6. **Task 6: Cross-reference Phase 5 corpus obligation + seed Phase 5.1** — `e74c6e7` (docs)
   - STATE.md Decisions section gains two bullets: Phase 5 code-complete cross-reference (corpus growth is Phase 6's obligation; the 4 seed drives can now be recorded during any Phase-6 drive) + Phase 5.1 seed (2026-07-09) documenting the road-snap heading hybrid Layer B as a future plan.
   - ROADMAP.md Phase 5 block gains a "Follow-ups (post-close-out)" subsection cross-linking the same seed + inheritance.

## Deviations from Plan

- **[Rule 1 — Bug] Notification format was root cause of "time frozen" observation.** Fixed inline via the `formatNotificationDuration` helper. Not sketched in the plan as a bug per se (the plan phrased it as a feature-add), but the effect was regression-behavior on trips >= 1 h; fits Rule 1.
- **Task 3 optional polish shipped, not skipped.** The plan text said "if it adds >30 LoC, skip and add a TODO(nice-to-have) comment". Actual add was ~10 LoC because `CameraStateNotifier` already exposes `bearing` (STATE Plan 02-03). Shipped the rotating-icon polish.
- **compassEnabled: false path used, not the Point(-9999, -9999) fallback.** maplibre_gl 0.26.2 does expose `compassEnabled` on the `MapLibreMap` constructor (grep-verified in pub-cache `maplibre_map.dart:22` + `:136` + `:492` + `:571`). No fallback needed. Note plan §Deviations sketched both paths; the primary path worked.
- **`map_widget_test.dart` compass test updated as part of Task 3, not left alone.** The plan's grep tripwires implied testing the compass-hiding logic; the previous `compass is enabled and positioned at topRight` test would have failed post-Task 3. Rule 1 auto-fix: replaced with a `compassEnabled: false` assertion tied to the AlignNorthButton contract.
- **04-15 Scenarios B + C and 04-16 Scenarios D + E DEFERRED, not exercised.** The 2026-07-09 drive was a single-corridor session with signal throughout; airplane-mode + same-corridor-second-drive + admin-lookup HUD readout + Refresh-admin-regions tap were not run. These paths are code-complete + unit-tested (8 coordinator tests, 6 overpass-way-source tests, 9 lookup tests, 5 leaf-package tests, 5 widget tests). Marked DEFERRED (non-blocking for Phase 6) in the checklist.

## Grep tripwires (all green)

- `trackingCompass` in `lib/features/map/` → 0 hits (Task 2 done cleanly).
- `trackingGps` in `lib/features/map/` → 4 hits (docstring + comment + switch case + widget-comment).
- `AlignNorthButton` in `lib/features/map/presentation/map_screen.dart` → 1 hit (Task 3 wired).
- `Drive-blocked` for QUA-06 in `.planning/REQUIREMENTS.md` → 0 live hits (Task 4 done).
- `status: passed` in `.planning/phases/04-osm-pipeline/04-VERIFICATION.md` → 1 hit (Task 5 done).
- `Phase 5.1 seed` in `.planning/STATE.md` → 1 hit; same in `.planning/ROADMAP.md` → 1 hit (Task 6 done).
- `git status --porcelain` post-completion → only `.idea/` (out-of-scope IDE metadata).

## Test + Analyze status

- `flutter analyze --no-pub` → No issues found.
- `flutter test` → 393/393 tests green. Delta from pre-04-19 baseline (383): +4 formatter tests (Task 1) + 6 align-north widget tests (Task 3) = +10 tests. (Actual is +10; the 393 total confirms.)

## Downstream impact

- **Phase 6 UNBLOCKED.** All Phase 4 close-outs done; the drive-verify checkpoint at 04-18 Task 8 is closed. Phase 6 (Inbox + Match Wire-Up) can be planned as soon as this plan lands.
- **Phase 3 fully closed.** SC5 (QUA-06 60-min battery baseline) verified via user-attested drive; all TRK-01..TRK-11 + QUA-06 rows Complete in REQUIREMENTS.md.
- **Phase 5.1 seed captured.** Road-snap heading hybrid (matcher-driven bearing alignment during recording) is queued for authoring when Phase 7 needs the live-matcher variant, or sooner on user request.
- **Phase 6 inherits corpus growth to ≥ 20 fixtures.** The 4 real-drive fixtures that were previously batched separately can now be recorded during any Phase-6 drive — no separate follow-up needed.
- **Deutschland labels stay DEFERRED to Phase 11.** MapTiler free-tier limitation; two paths (paid tier / client-side style JSON rewrite) documented in 04-18-LANGUAGE-INVESTIGATION.md.
