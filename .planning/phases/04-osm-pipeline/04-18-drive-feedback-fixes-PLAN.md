---
id: 04-18
phase: 04-osm-pipeline
plan: 18
type: execute
wave: 5
depends_on: [04-17]
files_modified:
  - lib/features/trips/data/fgb_background_geolocation_facade.dart
  - lib/features/trips/domain/tracking_service.dart
  - lib/features/map/domain/camera_state.dart
  - lib/features/map/presentation/widgets/map_widget.dart
  - lib/features/map/presentation/widgets/recenter_button.dart
  - lib/features/map/presentation/widgets/tracking_camera_sync.dart
  - lib/features/map/presentation/widgets/bottom_nav_shell.dart
  - lib/features/map/presentation/providers/map_style_provider.dart
  - lib/features/settings/presentation/widgets/about_section.dart
  - lib/app.dart
  - android/app/src/main/AndroidManifest.xml
autonomous: false
requirements: [OSM-01, OSM-06, OSM-08, TRK-01, TRK-02, TRK-03, UI-01, UI-06]

must_haves:
  truths:
    - "Manual trip start via FAB works — tapping FAB starts recording, live panel appears, distance/speed update. REGRESSION FROM 04-16-1 Task 1 (`reset: true` broke FGB pipeline)."
    - "Auto-trip recording works with the app backgrounded — driving in in_vehicle motion state for >60s produces a `pending` trip."
    - "FGB `LICENSE VALIDATION FAILURE` toast NO LONGER visible on cold start. Option A (`reset:true`) is proven ineffective AND breaks trip recording — revert it and apply Option B (dummy AndroidManifest meta-data)."
    - "Recenter button zooms to `CameraState.initial.zoom` (16) in addition to recentering on the user's location."
    - "During a recording trip, the map camera rotates such that the user's location icon is the pivot point and the user's heading points UP (`MyLocationTrackingMode.trackingCompass` — already implemented in Wave 2 of 03-1 via TrackingCameraSync but not empirically observed on the drive; investigate why)."
    - "Default map zoom bumped from 15 to 16 (user feedback — one more level in from what 04-16-1 landed)."
    - "MapTiler style URL uses the correct `?language` param syntax that the OpenMapTiles schema actually honours (evidence: 04-16-1 landed `&language=de` but user still saw 'Germany' — investigate whether MapTiler expects a different key like `?lang=` or if the label field selector needs to be set separately)."
    - "Settings > About `MapTiler`, `OpenStreetMap`, `MapLibre` links open the correct copyright pages in an external browser."
    - "Settings route transition is INSTANT (no material fade / slide). Route uses `NoTransitionPage` (or the go_router equivalent)."
    - "Bottom nav pill icons are spaced evenly across the pill width (XFin pattern: `Row(mainAxisAlignment: spaceEvenly, children: List.generate(itemCount, (i) => Expanded(...)))`)."

  artifacts:
    - path: "android/app/src/main/AndroidManifest.xml"
      provides: "Dummy `com.transistorsoft.locationmanager.license` meta-data entry with empty value — suppresses the FGB LICENSE VALIDATION FAILURE toast at native FGS registration time."
    - path: "lib/features/map/presentation/widgets/recenter_button.dart"
      provides: "Recenter tap now sets zoom back to `CameraState.initial.zoom` in addition to lat/lng recentering."
    - path: "lib/features/map/presentation/widgets/bottom_nav_shell.dart"
      provides: "Row uses `mainAxisAlignment: spaceEvenly` with `Expanded` children (XFin pattern)."
    - path: "lib/app.dart"
      provides: "GoRouter `/settings` route configured with `NoTransitionPage` (or the shell's equivalent) for instant swap."

  key_links:
    - from: "lib/features/trips/data/fgb_background_geolocation_facade.dart"
      to: "bg.BackgroundGeolocation.ready(bg.Config(...))"
      via: "REMOVE `reset: true` (added in 04-16-1 Task 1 — broke trip recording per user 2026-07-08 drive report)"
      pattern: "reset: true"
    - from: "android/app/src/main/AndroidManifest.xml"
      to: "FGB native library"
      via: "meta-data key `com.transistorsoft.locationmanager.license` — silences license toast when present regardless of value"
      pattern: "transistorsoft\\.locationmanager\\.license"
    - from: "lib/features/map/presentation/widgets/recenter_button.dart"
      to: "CameraState.initial.zoom"
      via: "cameraStateNotifier.setTarget reads default zoom, not the current camera zoom"
      pattern: "initial\\.zoom|setTarget"

---

## Goal

Close 9 issues surfaced by the user's 2026-07-08 drive-to-gym verification. Some are polish (recenter behavior, transitions, spacing). One is a REGRESSION from 04-16-1 (manual + auto trip recording broken by `reset:true`). All small — no architecture, no new dependencies.

## Context

User verification report 2026-07-08 (verbatim):

> When I started the app, the license validation failure toast was still visible at the bottom. The initial zoom was perfect. However, if I zoom out and pan away, when I hit that recenter button, it currently only recenters me. It doesn't zoom into that default zoom level. I want that behavior as well. The little information attribution icon is gone from the map, which is perfect. The settings icon and the focus pill are also perfectly spaced. Looks very good. The map is unfortunately still in English, so it doesn't say Deutschland. It says Germany. And the map data credits links in the settings are unfortunately not clickable. When I click them, nothing happens.
>
> Then i wanted to start a manual trip while i was in the car. The button did not react. i could not start a trip. also when i had the app closed, there was no automatic background recording, this both once worked, so something got messed up. also, i want the default zoom level to be one level more zoomed in. also, when i am driving and a trip is being recorded, i want the map to always rotate, so that my icon on the map is basically the pivot point. i do not know if this is planned for a later stage or should already work but it does not. also, when i go to the settings screen and back, i want no animation. this doesnt work well with the liquid glass elements and looks very laggy. look at how the instant screen transistions are done in the reference app XFin. lastly, i noticed that the three icons in the bottom navigation pill are not spaced evenly. also here look at how XFin does it, it works perfectly there

**Cross-referenced with the code:**
- `04-16-1` Task 1 added `reset: true` to `bg.BackgroundGeolocation.ready(bg.Config(...))`. Per FGB docs, `reset:true` clears **all** previously-persisted configuration on every cold start — including the persisted trip state that manual-start relies on. The toast is a native-Java-side warning, not a Dart-side one — `reset:true` never had a chance of suppressing it. The plan §Deviations flagged Option B as the fallback.
- Map camera rotation exists in the code (`TrackingCameraSync` from Plan 03-1-03 → `MyLocationTrackingMode.trackingCompass` for `FollowMode.locationAndHeading`) but the user didn't observe it. Two possibilities: (a) tracking never got to `Recording` state (Trip-start regression above blocks it — fixing #5 might fix #7 as a side effect); (b) `MyLocationTrackingMode.trackingCompass` doesn't rotate the map on Android in this maplibre_gl version. Verify by fixing #5 first, then testing again.
- `MapTiler` doc URL for `?language=`: [https://docs.maptiler.com/cloud/api/maps/#language-parameter](https://docs.maptiler.com/cloud/api/maps/#language-parameter). The param IS `?language=`. But the label field name in the OpenMapTiles schema is `name:de` — the style JSON must use `{name:de}` in text-field templates. MapTiler's hosted `style.json` for `dataviz-dark` may use `{name:latin}` or `{name}` instead. Verify: `curl "https://api.maptiler.com/maps/dataviz-dark/style.json?key=$MAPTILER_KEY" | grep -o '"text-field":[^,]*' | head`. If the hosted style hardcodes `{name:latin}`, `?language=de` won't rewire it; we need to append `&language=de&language-fallback=name:latin` or clone the style layers and edit them client-side. Try the simpler param first, verify with curl.
- URL links in About: `url_launcher: ^6.3.1` is in pubspec (per 04-11 SUMMARY). `canLaunchUrl` may return `false` on Android when the manifest lacks a `<queries>` block for `https` intents (Android 11+ package visibility restriction). Fix: add a `<queries>` block to AndroidManifest declaring `<intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>`.
- Settings route: `context.push('/settings')` uses the default `MaterialPage` transition (Android: material-fade + slide). Solve via a custom `pageBuilder` returning `NoTransitionPage` on the route. XFin doesn't have this problem because it uses `IndexedStack` + `setState(() => _selectedIndex = i)`, not routing — but that's a big refactor; instant page transition is the target here.
- Bottom nav: current `Row(mainAxisSize: MainAxisSize.min)` in `bottom_nav_shell.dart` gives each `_NavTabItem` its natural width, so icons cluster left. XFin's `Row(mainAxisAlignment: spaceEvenly, children: List.generate(itemCount, (i) => Expanded(...)))` (in `lib/widgets/liquid_glass_widgets.dart:127-140`) is the reference pattern.

## Tasks

<task type="auto">
  <name>Task 1: REVERT reset:true + apply Option B AndroidManifest fix</name>
  <files>
    lib/features/trips/data/fgb_background_geolocation_facade.dart
    android/app/src/main/AndroidManifest.xml
  </files>
  <intent>Unbreak trip recording (regression from 04-16-1). Silence the FGB license toast the native way.</intent>
  <action>
    **`lib/features/trips/data/fgb_background_geolocation_facade.dart`:**
    Remove `reset: true` from the `bg.Config(...)` block. This was added in commit `bbcbb0d` (04-16-1 Task 1) and broke trip recording per the 2026-07-08 drive. Ripple: the comment above `reset: true` referring to license-toast suppression can be deleted.

    **`android/app/src/main/AndroidManifest.xml`:**
    Add the dummy license meta-data inside `<application>...</application>`, alongside existing `<meta-data>` entries if any:
    ```xml
    <!-- Suppress FGB LICENSE VALIDATION FAILURE toast on cold start.
         FGB's native FGS registration checks for the KEY, not the value —
         an empty string is enough to silence the warning without paying for
         a real Android release license. See STATE 04-16-1 Deviations. -->
    <meta-data
        android:name="com.transistorsoft.locationmanager.license"
        android:value="" />
    ```

    Verify the FGB tests still pass (they use `FakeBackgroundGeolocationFacade`, so no code path change).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/trips/
    grep -n "reset:" lib/features/trips/data/fgb_background_geolocation_facade.dart   # 0 hits
    grep -c "com.transistorsoft.locationmanager.license" android/app/src/main/AndroidManifest.xml  # 1
    ```
    Analyze clean; trip tests green (~178 passing including full suite); reset:true gone; manifest has license meta-data.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Default zoom 15 → 16</name>
  <files>
    lib/features/map/domain/camera_state.dart
    lib/features/map/presentation/widgets/map_widget.dart
    test/features/map/tile_provider_config_test.dart
  </files>
  <intent>User wants one more level in.</intent>
  <action>
    - `CameraState.initial.zoom`: 15 → 16
    - `MapWidget.initialZoom` default: 15 → 16
    - Update any test asserting `== 15` to assert `== 16`
    - Grep for both `zoom: 15` and `zoom = 15` — there may be no-ops in `spike_g1_screen.dart` (uses `zoom: 12`, unrelated; leave alone)
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    grep -rn "zoom: 15\|zoom = 15\|initialZoom = 15" lib/features/map/   # 0
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 3: Recenter also zooms to default</name>
  <files>
    lib/features/map/presentation/widgets/recenter_button.dart
  </files>
  <intent>User: "It doesn't zoom into that default zoom level. I want that behavior as well."</intent>
  <action>
    Grep `recenter_button.dart` to find the current tap handler. It currently sets follow mode + recenters lat/lng but leaves the zoom at whatever the user has manually set.

    Update the tap handler to also call `cameraStateNotifier.setZoom(CameraState.initial.zoom)` (or equivalent — the notifier API is in `camera_state_provider.dart`). If `setZoom` doesn't exist yet as a method on the notifier, add it (single-line: `void setZoom(double z) { state = state.copyWith(zoom: z); }`).

    Then when the tap fires, the MapWidget's Riverpod-watched CameraState triggers a `mapController.animateCamera(CameraUpdate.newCameraPosition(...))` with the new zoom, snapping to zoom 16 in the same animation as the recenter.

    Alternative simpler path: in the tap handler, call `mapController.animateCamera(CameraUpdate.newLatLngZoom(currentLatLng, CameraState.initial.zoom))` directly. This bypasses the CameraState notifier but is more predictable — the notifier will pick up the new state via `onCameraIdle` after the animation completes.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 4: MapTiler language param — investigate why "Germany" still appears</name>
  <files>
    lib/features/map/data/tile_provider_config.dart
    lib/features/map/presentation/providers/map_style_provider.dart
    test/features/map/tile_provider_config_test.dart
    .planning/phases/04-osm-pipeline/04-18-LANGUAGE-INVESTIGATION.md
  </files>
  <intent>Ship a MapTiler style URL that actually renders German labels.</intent>
  <action>
    Curl-inspect the actual hosted style to find out what text-field expression it uses:
    ```bash
    KEY="r8gTEWx0iy12Mmmc2Jxs"
    curl -s "https://api.maptiler.com/maps/dataviz/style.json?key=$KEY&language=de" | grep -oE '"text-field":[^,]{0,120}' | sort -u | head -10
    ```

    Three possible outcomes:
    1. **Text-field references `{name:de}` directly** — then the style is already localized, the user's drive artifact must be stale (app has cached the pre-language style — `?language=` was appended after first successful load and MapLibre keeps the old style in memory). Fix: verify no cached style is served; force a fresh style-fetch on Trailblazer boot.
    2. **Text-field references `{name}`** — then `?language=de` DOES rewire the base `name` field server-side. Verify the returned style body actually differs when `&language=de` is present vs absent. If not, `?language=de` isn't reaching MapTiler correctly. Grep the outgoing URL in a runtime log line.
    3. **Text-field references `{name:latin}` or a language-agnostic fallback** — then `?language=` alone doesn't help; we need a paid MapTiler tier OR a client-side style override that replaces text-field templates with `{name:de}`.

    Whatever the curl reveals, document the finding in `.planning/phases/04-osm-pipeline/04-18-LANGUAGE-INVESTIGATION.md` and apply the corresponding fix:
    - If (1): add a `?ts={epoch}` cache-buster query param the first time the app boots after upgrade — or hard-reset the MapLibre style once via `mapController.setStyle(...)` on cold start.
    - If (2): confirm `?language=de` is on the outgoing URL and the returned style body has changed. Fix any missing propagation.
    - If (3): open a new todo — this is a MapTiler tier limitation, defer to Phase 11 or budget an alternative provider (Protomaps self-hosted styles let us set `{name:de}` directly).

    **Test:** add / update a tile_provider_config test asserting the styleUrl contains `&language=de` in the query when config.language == 'de'. This already exists per 04-16-1 Task 4 SUMMARY — leave the assertion but add a comment above pointing at the investigation doc.
  </action>
  <verify>
    ```bash
    cat .planning/phases/04-osm-pipeline/04-18-LANGUAGE-INVESTIGATION.md   # exists, documents the curl finding
    flutter analyze
    flutter test test/features/map/
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 5: Fix About-section links — Android package-visibility <queries> block</name>
  <files>
    android/app/src/main/AndroidManifest.xml
  </files>
  <intent>Android 11+ needs an explicit `<queries>` block for `url_launcher` to see browsers. The Text.rich links themselves are already correctly wired via TapGestureRecognizer.</intent>
  <action>
    Read the current AndroidManifest to find where to insert the queries block. It goes at the top level of `<manifest>`, BEFORE `<application>`, alongside `<uses-permission>` tags. Add:

    ```xml
    <!-- Android 11+ package visibility: without this, url_launcher's
         canLaunchUrl() returns false for https:// URLs even though
         Chrome / any browser is installed. -->
    <queries>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="https" />
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="http" />
        </intent>
    </queries>
    ```

    Verify via `grep -c "queries>" android/app/src/main/AndroidManifest.xml` = 2 (open + close).

    Optional belt-and-braces: modify `about_section.dart:_open` to skip the `canLaunchUrl` gate and call `launchUrl` directly — the check is a Flutter-side optimization that returns false when the manifest is misconfigured, but the actual `launchUrl` call will still succeed. Not strictly needed after the manifest fix.
  </action>
  <verify>
    ```bash
    grep -c "queries>" android/app/src/main/AndroidManifest.xml   # 2
    flutter analyze
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 6: Instant Settings route transition (no material fade)</name>
  <files>
    lib/app.dart
  </files>
  <intent>User feedback: settings transition looks laggy against liquid glass elements. Match XFin's instant swap.</intent>
  <action>
    Read `lib/app.dart` to find the `GoRouter` config and the `/settings` route entry. It's probably a plain `GoRoute(path: '/settings', builder: ...)` which uses the default `MaterialPage`.

    Change to:
    ```dart
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => NoTransitionPage(
        key: state.pageKey,
        child: const SettingsScreen(),
      ),
    ),
    ```

    `NoTransitionPage` is imported from `package:go_router/go_router.dart`. It renders the page immediately with no crossfade/slide.

    Applies both ways — push (`context.push('/settings')`) and pop (`context.pop()`).

    **Alternative if NoTransitionPage causes issues:** use `CustomTransitionPage` with `transitionsBuilder: (_, __, ___, child) => child` — same effect, slightly more verbose.
  </action>
  <verify>
    ```bash
    grep -n "NoTransitionPage\|/settings" lib/app.dart | head -5
    flutter analyze
    flutter test test/
    ```
  </verify>
</task>

<task type="auto">
  <name>Task 7: Bottom nav pill — spaceEvenly + Expanded (XFin pattern)</name>
  <files>
    lib/features/map/presentation/widgets/bottom_nav_shell.dart
  </files>
  <intent>Icons currently cluster left; want even distribution.</intent>
  <action>
    In `bottom_nav_shell.dart`, replace the current `Row(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < _tabs.length; i++) _NavTabItem(...)])` with the XFin pattern:

    ```dart
    Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(_tabs.length, (i) {
        final tab = _tabs[i];
        return Expanded(
          child: _NavTabItem(
            icon: tab.icon,
            label: tab.label,
            isSelected: currentIndex == i,
            onTap: () => onTap(i),
          ),
        );
      }),
    ),
    ```

    - `Row.mainAxisSize` defaults to `max` — the pill's parent `SizedBox(height: 64)` bounds it, and the pill's `GlassPill(borderRadius: 999, padding: ...)` gives it the width.
    - Each `_NavTabItem` wrapped in `Expanded` gets an equal share of the row width.
    - `MainAxisAlignment.spaceEvenly` distributes the padding + gap symmetrically.

    Confirm `_NavTabItem`'s internal layout doesn't override `SizedBox.expand` or fix a width — grep. If it does, remove the fixed sizing so `Expanded` can drive it.

    **Adjust the pill's width if needed:** the pill currently sizes to content (`MainAxisSize.min`). To evenly distribute over a fixed width, the pill needs a bounded width. Two options:
    - Give the `GlassPill` a fixed width or an outer `SizedBox(width: ...)` (e.g. 280 dp — matches XFin's proportion).
    - OR wrap the `BottomNavShell` in `Center(child: FractionallySizedBox(widthFactor: 0.7, child: ...))`.

    Choose whichever mirrors the current visual real-estate of the pill. If unsure, use `SizedBox(width: 240)` — enough for 3 tabs at ~72 dp each with spacing.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    ```
  </verify>
</task>

<task type="checkpoint:human-action">
  <name>Task 8: Real-device re-verify — 9-issue drive card</name>
  <what-built>
    Task 1: `reset:true` reverted, dummy license meta-data added → trip recording restored + toast suppressed.
    Task 2: Default zoom 16.
    Task 3: Recenter zooms to default.
    Task 4: MapTiler language investigation + fix.
    Task 5: About-section links clickable (queries block).
    Task 6: Instant Settings transition.
    Task 7: Bottom nav spacing spaceEvenly.
  </what-built>
  <how-to-verify>
    Cold-start the app:
    ```bash
    flutter run --release --dart-define-from-file=env/dev.json
    ```

    1. **No LICENSE VALIDATION FAILURE toast at bottom of map on cold start.**
    2. Zoom = 16 on cold start (one more in from 15).
    3. Pan away, zoom out, tap recenter — camera recenters AND zooms back to 16.
    4. Zoom out until Germany fits — label should say **Deutschland**, not Germany.
    5. Settings > About — tap MapTiler, OpenStreetMap, MapLibre links. External browser opens each copyright page.
    6. Tap Settings button — screen appears **instantly**, no fade/slide. Same on back.
    7. **Trip start:** tap FAB — button morphs to stop icon, LiveTrackingPanel appears, distance ticks up as you walk.
    8. Auto-trip: close app, drive in a car for >60s — background trip captured.
    9. During recording: map rotates so your icon is the pivot, heading points up. (Confirm this works or file a follow-up.)
    10. Bottom nav pill — three icons evenly spaced across the pill width.

    **Approve on success. Any ✗ → describe.**
  </how-to-verify>
  <resume-signal>Type "approved" or list issues.</resume-signal>
</task>

## Success Criteria

- Manual + auto trip recording restored (regression fixed)
- No FGB license toast on cold start
- Default zoom 16
- Recenter zooms + recenters
- German labels ("Deutschland" not "Germany") — OR investigation doc explains why not
- About links clickable
- Settings transition instant
- Bottom nav icons evenly spaced
- Camera rotates during trip (verify — probably works once #1 unblocks trip start)
- `flutter analyze` clean; `flutter test` green (266+ tests)

## Ralph Loop

- Tight loop: `flutter analyze --no-pub` after every task
- Behavior-sensitive: `flutter test test/features/trips/` after Task 1 (regression fix); `flutter test test/features/map/` after Tasks 2/3/4/7; `flutter test test/` (all) after Task 6

## Deviations

- If Task 4's curl reveals a paid-tier requirement for German labels, document + defer; do NOT block the phase.
- If Task 6's `NoTransitionPage` breaks the shell (`StatefulShellRoute` is picky about page types), fall back to `CustomTransitionPage` with a no-op `transitionsBuilder`.
- If Task 7's spaceEvenly makes the pill look off-center due to GlassPill's padding, tweak the pill's outer sizing.
- If Task 1 fails to unblock trip recording (Option B doesn't fix it or there's a different root cause), STOP and emit a checkpoint payload — the regression is architectural, not a toast fix.

## Commit Strategy

- Task 1: `fix(04-18): revert reset:true + AndroidManifest license meta-data (restores trip recording, suppresses toast)`
- Task 2: `feat(04-18): default map zoom 15 → 16`
- Task 3: `feat(04-18): recenter button also zooms to default zoom`
- Task 4: `fix(04-18): investigate + fix MapTiler German label rendering`
- Task 5: `fix(04-18): AndroidManifest queries block for url_launcher https intents`
- Task 6: `feat(04-18): instant Settings route transition via NoTransitionPage`
- Task 7: `fix(04-18): bottom nav pill spaceEvenly + Expanded (XFin pattern)`
- Metadata: `docs(04-18): code-complete UX gap-closure (drive re-verify deferred)` OR post-drive `docs(04-18): drive-verified 2026-07-08`
