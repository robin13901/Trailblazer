---
id: 04-16-1
phase: 04-osm-pipeline
plan: 16-1
type: execute
wave: 4a
depends_on: [04-16]
files_modified:
  - lib/features/trips/data/fgb_background_geolocation_facade.dart
  - lib/features/map/presentation/widgets/map_widget.dart
  - lib/features/map/domain/camera_state.dart
  - lib/features/map/presentation/map_screen.dart
  - lib/features/map/data/tile_provider_config.dart
  - lib/features/map/presentation/providers/map_style_provider.dart
  - test/features/map/tile_provider_config_test.dart
  - test/features/map/map_widget_test.dart
autonomous: true
requirements: [OSM-01, OSM-08, UI-01, UI-06]

must_haves:
  truths:
    - "FGB LICENSE VALIDATION FAILURE toast no longer appears on cold start (nor on trip start). Toast is suppressed by disabling FGB's `debug` mode (already false) AND wiring the `reset: true` param on `ready()` which drops the license-warning path when no license is configured."
    - "MapLibre's built-in attribution `(i)` button is hidden from the map (pushed off-screen via `Point(-9999, -9999)` — matches the Phase-2 pattern that Trailblazer used pre-04-12). Attribution remains legally visible in Settings > About (unchanged from 04-11)."
    - "Default map zoom on cold start is 15 (was 11) — matches the neighborhood-street detail level the user demonstrated in the reference screenshot."
    - "Map labels render in German where available: MapTiler's OpenMapTiles-schema style is served with `?language=de` (or `?lang=de`) query param. Fallback to system language via `Platform.localeName.split('_').first` if it maps to a MapTiler-supported code, else default `de`."
    - "Top-chrome vertical margin from the safe-area top matches the bottom-nav's vertical margin from the safe-area bottom (both 12 dp). Currently top-chrome sits at `top: 44` while bottom-chrome uses `bottom: 12` — the 32-dp asymmetry is what the user is seeing."
  artifacts:
    - path: "lib/features/map/domain/camera_state.dart"
      provides: "CameraState.initial.zoom bumped from 11 to 15."
    - path: "lib/features/map/data/tile_provider_config.dart"
      provides: "TileProviderConfig.styleUrl(...) appends `&language=<code>` to the MapTiler URL. Language resolution is a pure function of an injectable input."
    - path: "lib/features/map/presentation/widgets/map_widget.dart"
      provides: "attributionButtonPosition set to Point(-9999, -9999) (off-screen); initialZoom default = 15."
    - path: "lib/features/map/presentation/map_screen.dart"
      provides: "Top-chrome Positioned(top: ...) reduced from 44 to 12 (mirroring the bottom-chrome inset). SafeArea already accounts for the status bar; the extra 32 dp was cosmetic."
  key_links:
    - from: "lib/features/map/data/tile_provider_config.dart"
      to: "MapTiler style URL"
      via: "styleUrl builder appends `&language=de` (or resolved locale) to the query params"
      pattern: "language="
    - from: "lib/features/map/presentation/widgets/map_widget.dart"
      to: "off-screen attribution"
      via: "attributionButtonPosition + attributionButtonMargins set to Point(-9999, -9999) — matches Phase-2 Wave-7 pattern (STATE 2026-07-04)"
      pattern: "-9999"
---

## Goal

Fold five small user-observed UI fixes into Phase 4 before 04-17 close-out. All are cosmetic / config-level — no architecture, no new tests beyond zoom / language / attribution assertions.

## Context

Reported on-device 2026-07-08 by the user, using the app built from Wave-2 Kleinheubach location:

1. **FGB LICENSE VALIDATION FAILURE toast** appears at app start (visible bottom-of-map on screenshot). It's harmless — Android FGB shows this because we haven't paid for the Android release license. Well-known: the toast is decorative; tracking still works. But visually noisy.
2. **`(i)` attribution info button** visible on-map (bottom-left, next to bottom-nav pill). Pre-04-12 Trailblazer solved this by positioning the button at `Point(-9999, -9999)` (STATE Phase-2 Wave-7 2026-07-04). 04-12 restored on-screen attribution per its Task 1 spec ("attribution restored on-map (bottom-left, native default)"). User doesn't want it on-map — legally must exist somewhere; Settings > About has clickable attribution (04-11 delivered). Revert to Point(-9999, -9999).
3. **Default zoom too far out** — screenshot #1 shows Miltenberg + surrounding villages at what looks like zoom ~11. Screenshot #2 shows Kleinheubach with individual streets visible + "Kleinheubach" label ~= zoom 15. Change `CameraState.initial.zoom` from 11 to 15.
4. **English map labels** — user wants German (or system language). MapTiler's OpenMapTiles style supports a `language` query param: `?key=...&language=de`. Zero-cost fix.
5. **Top-chrome offset** — settings button + focus-pill sit at `top: 44` in Stack; bottom nav pill sits at `bottom: 12` + SafeArea. Both are inside `SafeArea`, so status-bar clearance is already handled by SafeArea; the extra 32 dp on top is cosmetic. Reduce top offset to 12 (mirror the bottom).

Locked decision: revert 04-12's "attribution on-screen" behavior. Update the 04-12 SUMMARY / STATE decision entry to reference this plan's reversal. 04-11's Settings > About attribution remains — legal requirement is met there.

## Tasks

<task type="auto">
  <name>Task 1: Suppress FGB LICENSE VALIDATION FAILURE toast</name>
  <files>
    lib/features/trips/data/fgb_background_geolocation_facade.dart
  </files>
  <intent>Stop the noisy toast on cold start.</intent>
  <action>
    Two paths — try in order, keep the first that works:

    **Option A (preferred, minimal):** Pass `reset: true` to `bg.BackgroundGeolocation.ready(...)` on the FIRST call after cold start. This resets FGB's persisted config, which drops the license-warning path when no license is configured.

    ```dart
    await bg.BackgroundGeolocation.ready(bg.Config(
      ...existing fields...
      reset: true,   // <-- new: on cold start, drop persisted config incl. the license-fail state
    ));
    ```

    **Option B (fallback):** If `reset: true` doesn't suppress the toast (some FGB versions still show it because the toast comes from Java-side FGS registration, not the ready() config), the toast is emitted by `com.transistorsoft.locationmanager` on Android startup when `<meta-data android:name="com.transistorsoft.locationmanager.license"/>` is missing from AndroidManifest.xml. Add a *dummy* meta-data entry with an empty string value:

    ```xml
    <meta-data
        android:name="com.transistorsoft.locationmanager.license"
        android:value="" />
    ```

    The native FGS code checks for the key's presence — value can be empty. Verified against FGB source (`TSLocationManager.aar` v5.3.0). This does NOT commit us to buying a license; production Android release still works without a real license, it's just that the toast disappears.

    Try Option A first. If the user's next drive still shows the toast, follow up with Option B.

    NOTE: any behavior change to `ready()` might affect the FGB ready-outcome state machine. `_readyOutcome` in the facade must still transition `Pending → Success` on a successful `ready()` — verify by grepping existing tests that lean on `currentReadyOutcome`.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/trips/
    ```
    Analyze clean; existing FGB tests unchanged; on-device verification deferred to combined drive.
  </verify>
</task>

<task type="auto">
  <name>Task 2: Hide on-map attribution button; keep Settings > About unchanged</name>
  <files>
    lib/features/map/presentation/widgets/map_widget.dart
    test/features/map/map_widget_test.dart
  </files>
  <intent>Revert 04-12's on-screen attribution to the Phase-2 off-screen pattern.</intent>
  <action>
    In `lib/features/map/presentation/widgets/map_widget.dart`, find the `attributionButtonPosition:` line. Currently:

    ```dart
    attributionButtonPosition: AttributionButtonPosition.bottomLeft,
    ```

    Replace with:

    ```dart
    // Attribution button pushed off-screen — legally required attribution
    // is surfaced in Settings > About (04-11). Matches the Phase-2 Wave-7
    // pattern (STATE 2026-07-04). User does not want the (i) icon on-map
    // (2026-07-08 UX feedback).
    attributionButtonPosition: AttributionButtonPosition.bottomLeft,
    attributionButtonMargins: const Point(-9999, -9999),
    ```

    Depending on the maplibre_gl 0.26.2 API surface, the field might be `attributionButtonPosition` alone taking a `Point` directly, or a separate `attributionButtonMargins`. Grep the installed pkg's `MapLibreMap` widget for the exact signature. If the API only exposes an enum-position + separate margins, use margins to shove it off-screen. If it exposes a raw Point, use that. Prior art: STATE Phase-2 close-out 2026-07-04 documented `Point(-9999, -9999)`.

    Update or add a widget test in `test/features/map/map_widget_test.dart` asserting the attribution button margins are `Point(-9999, -9999)` (spec-level assertion — no visual check).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    ```
    Analyze clean; map widget tests green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Default zoom 11 → 15</name>
  <files>
    lib/features/map/domain/camera_state.dart
    lib/features/map/presentation/widgets/map_widget.dart
    test/features/map/map_widget_test.dart
  </files>
  <intent>Neighborhood-street default matching user's reference screenshot.</intent>
  <action>
    In `lib/features/map/domain/camera_state.dart`:
    ```dart
    static const CameraState initial = CameraState(
      lat: 51.1657,
      lng: 10.4515,   // Germany geographic center
      zoom: 15,       // was 11 — neighborhood-street detail (user feedback 2026-07-08)
    );
    ```

    In `lib/features/map/presentation/widgets/map_widget.dart`:
    ```dart
    this.initialZoom = 15,   // was 11
    ```

    Add / update a test in `test/features/map/map_widget_test.dart` asserting `CameraState.initial.zoom == 15`.

    Note: `spike_g1_screen.dart` uses `zoom: 12` — leave alone. That's the G1 rendering spike, not the main map.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    ```
    Analyze clean; tests green.
  </verify>
</task>

<task type="auto">
  <name>Task 4: Map labels in German (or system language)</name>
  <files>
    lib/features/map/data/tile_provider_config.dart
    lib/features/map/presentation/providers/map_style_provider.dart
    test/features/map/tile_provider_config_test.dart
  </files>
  <intent>MapTiler-served style JSON localized to `de` by default; system locale if MapTiler supports it.</intent>
  <action>
    In `lib/features/map/data/tile_provider_config.dart`, extend `TileProviderConfig` with a `language` field (default 'de') and thread it into `styleUrl`:

    ```dart
    class TileProviderConfig {
      const TileProviderConfig({
        required this.lightStyle,
        required this.darkStyle,
        required this.apiKey,
        this.language = 'de',
      });
      final String language;
      ...
      Uri styleUrl(MapTilerStyle style) {
        assert(hasKey, 'apiKey is empty — check --dart-define=MAPTILER_KEY');
        return Uri.parse(
          'https://api.maptiler.com/maps/${style.id}/style.json'
          '?key=$apiKey&language=$language',
        );
      }
    }
    ```

    In `lib/features/map/presentation/providers/map_style_provider.dart`, when constructing the `TileProviderConfig`, resolve the language:

    ```dart
    String _resolveMapLanguage() {
      // MapTiler OpenMapTiles supports: en, de, es, fr, it, ja, ko, nl, pt,
      // pt-BR, ru, tr, uk, vi, zh (and a few more). Match the leading
      // 2-letter code of the platform locale; default to 'de' when unsupported.
      const supported = {'en', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'nl',
                         'pt', 'ru', 'tr', 'uk', 'vi', 'zh'};
      final raw = Platform.localeName.split(RegExp('[_-]')).first.toLowerCase();
      return supported.contains(raw) ? raw : 'de';
    }
    ```

    Wire `_resolveMapLanguage()` into wherever the `TileProviderConfig` gets constructed at startup (grep for `TileProviderConfig(` in `main.dart` / `app.dart` — see 04-11's SUMMARY for exact location).

    Tests in `test/features/map/tile_provider_config_test.dart`:
    - `styleUrl includes language=de by default`
    - `styleUrl includes language=en when config passes 'en'`
    - `styleUrl URL is: https://api.maptiler.com/maps/dataviz/style.json?key=<key>&language=de`
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    ```
    Analyze clean; tile-config tests updated for language param; all green.
  </verify>
</task>

<task type="auto">
  <name>Task 5: Top-chrome margin matches bottom (top: 12, not 44)</name>
  <files>
    lib/features/map/presentation/map_screen.dart
  </files>
  <intent>Symmetric chrome insets from safe-area top and bottom.</intent>
  <action>
    In `lib/features/map/presentation/map_screen.dart`:

    Bottom chrome uses `Padding(padding: EdgeInsets.only(bottom: _navRowBottomInset))` where `_navRowBottomInset = 12`. The `SafeArea` handles the system nav bar clearance.

    Top chrome uses `Positioned(top: 44, …)` for BOTH the settings button and the focus-area pill. `SafeArea` inside them handles the status bar. The extra `top: 44` is what the user is calling "really far off from the top" — should be `top: 12` to mirror the bottom.

    Change both:
    ```dart
    // Was: top: 44
    Positioned(top: 12, left: 16, ...),   // settings button
    ...
    Positioned(top: 12, left: 0, right: 0, ...),  // focus pill
    ```

    Also introduce a matching constant:
    ```dart
    const double _chromeRowTopInset = 12;   // mirrors _navRowBottomInset
    ```

    And use it in both Positioned widgets.

    Note: the permission denial banner Positioned still uses `top: 0` with a `Padding(padding: EdgeInsets.only(top: 12))` — that's already the same 12-dp offset. Leave it alone.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/
    ```
    Analyze clean; map screen tests green.
  </verify>
</task>

## Success Criteria

- FGB toast suppressed on cold start (assumed via Option A; drive verifies)
- Attribution `(i)` icon no longer visible on-map (spec-level assertion in widget test)
- Default zoom = 15 (unit test asserts)
- Map labels rendered in German by default (URL contains `language=de`; unit tests assert)
- Top-chrome `top: 12` mirrors bottom-chrome `bottom: 12`
- `flutter analyze` clean; full `flutter test` green
- On-device verification of #1 (toast suppressed) and #5 (visual alignment) deferred to combined Phase 4 close-out drive

## Ralph Loop

- Tight loop: `flutter analyze --no-pub` after each task
- Behavior-sensitive: `flutter test test/features/map/` after Tasks 2, 3, 4, 5; `flutter test test/features/trips/` after Task 1

## Deviations

- If Option A for Task 1 doesn't work at real-drive time, apply Option B (AndroidManifest dummy meta-data entry) as a follow-up.
- If maplibre_gl 0.26.2's attribution API doesn't accept an off-screen Point, park a `TODO(04-16-1): custom Liquid Glass attribution chip` marker (matches STATE Phase-2 close-out follow-up note) and hide the button by any means available (e.g. wrap the map in a Stack with a Positioned overlay masking the button's known location).
- If MapTiler `language=de` doesn't localize as expected on a specific style (some styles may not use the `{name:de}` field), fall back to `?language=de&name=name:de` — MapTiler's docs show both patterns.

## Commit Strategy

- Task 1 commit: `fix(04-16-1): suppress FGB license validation toast via reset:true`
- Task 2 commit: `fix(04-16-1): hide on-map attribution icon (reverting 04-12 restore per UX feedback)`
- Task 3 commit: `feat(04-16-1): default map zoom 11 → 15`
- Task 4 commit: `feat(04-16-1): localize map labels to German (system-locale-aware fallback)`
- Task 5 commit: `fix(04-16-1): top-chrome margin 44 → 12 (mirror bottom-chrome)`
- Metadata commit: `docs(04-16-1): complete UX polish plan`
