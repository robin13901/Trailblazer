---
id: 04-11
phase: 04-osm-pipeline
plan: 11
type: execute
wave: 1
wave_ordering: serial-within-wave
wave_serial_order: 1  # runs before 04-12
depends_on: []
files_modified:
  - lib/main.dart
  - lib/features/map/data/tile_provider_config.dart
  - lib/features/map/presentation/providers/map_style_provider.dart
  - lib/features/settings/presentation/widgets/about_section.dart
  - env/dev.json.example
  - .gitignore
  - README.md
  - .github/workflows/ci.yml
  - test/features/map/tile_provider_config_test.dart
  - .planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md
autonomous: true
requirements: [OSM-01, OSM-08]

must_haves:
  truths:
    - "MapTiler API key is delivered via --dart-define=MAPTILER_KEY (or --dart-define-from-file=env/dev.json) and never appears in source, git history, or logs."
    - "Empty-key case surfaces a diagnostic banner or logged warning; the app does not silently render a blank map."
    - "The style-ID spike is documented in the plan's SUMMARY with the exact style IDs confirmed against a real free-tier account."
    - "Settings > About screen shows a clickable attribution line: `© MapTiler © OpenStreetMap contributors` with links to https://www.maptiler.com/copyright/ and https://www.openstreetmap.org/copyright."
    - "A pure-Dart `TileProviderConfig` model exists that resolves MapTiler style URLs from a style-ID enum + the injected key."
  artifacts:
    - path: "lib/features/map/data/tile_provider_config.dart"
      provides: "TileProviderConfig immutable model + MapTilerStyle enum + styleUrl() resolver; empty-key guard."
      min_lines: 60
    - path: "test/features/map/tile_provider_config_test.dart"
      provides: "Unit tests: URL formatting, empty-key sentinel, enum → ID mapping."
      min_lines: 40
    - path: "env/dev.json.example"
      provides: "Documented example of the --dart-define-from-file JSON shape; gitignored real version documented in README."
    - path: "lib/features/settings/presentation/widgets/about_section.dart"
      provides: "Attribution line + clickable links (MapTiler + OSM)."
    - path: ".planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md"
      provides: "Style-ID spike results — table of tested IDs, chosen light/dark defaults, curl-verified HTTP statuses."
      min_lines: 20
  key_links:
    - from: "lib/main.dart"
      to: "lib/features/map/data/tile_provider_config.dart"
      via: "reads `String.fromEnvironment('MAPTILER_KEY')` at startup and hands to TileProviderConfig"
      pattern: "String\\.fromEnvironment\\('MAPTILER_KEY'\\)"
    - from: "lib/features/map/presentation/providers/map_style_provider.dart"
      to: "lib/features/map/data/tile_provider_config.dart"
      via: "provider reads the current TileProviderConfig and returns the MapTiler style URL (not the bundled asset path)"
      pattern: "styleUrl\\("
    - from: ".github/workflows/ci.yml"
      to: "secrets.MAPTILER_KEY"
      via: "injected at build time via --dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }}"
      pattern: "MAPTILER_KEY"
---

## Goal

Replace the loopback PMTiles tile server with MapTiler Cloud as the vector-tile provider. Wire the API key end-to-end (dev + CI), model the tile provider config in pure Dart, and land the free-tier attribution in Settings > About. This plan does NOT rewrite `assets/map_style_*.json` and does NOT delete the old TileServer — 04-12 does that once the wiring works.

## Context

- Research: `.planning/phases/04-osm-pipeline/04-RESEARCH.md` §1 (MapTiler URLs, attribution, key delivery, style catalog).
- Locked decisions from planning_context: `--dart-define=MAPTILER_KEY`; MapTiler + OSM attribution required by free tier; free-tier logo required on-map (implementation deferred to 04-12).
- Existing code: `lib/features/map/data/tile_server.dart` (loopback shim), `lib/features/map/presentation/providers/map_style_provider.dart` (current style-asset provider). Both stay untouched in this plan.
- Project rule: package imports only (`package:auto_explore/…`); no `withOpacity`; alphabetized `pubspec.yaml` deps.
- **Wave-1 serial ordering:** 04-11 and 04-12 are BOTH `wave: 1` but MUST run serially (04-12 consumes `mapStyleUrlProvider` created here). Execute in plan-number order: 04-11 first, then 04-12. This is not a parallel-wave; the `wave_ordering: serial-within-wave` frontmatter annotation makes this explicit for the orchestrator.

## Tasks

<task type="auto">
  <name>Task 1: MapTiler style-ID spike + document confirmed IDs</name>
  <files>
    .planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md
  </files>
  <intent>Empirically confirm which MapTiler style IDs work on a fresh free-tier account before committing to a value in TileProviderConfig.</intent>
  <action>
    **~15 min spike. Do NOT hard-code a style ID until this step completes.**

    1. Open (or ask the user to open) the MapTiler dashboard at https://cloud.maptiler.com/maps/ with a real free-tier account.
    2. From the dashboard, list which of the following style IDs are actually loadable on the free tier: `streets-v2`, `streets-v4`, `basic-v2`, `bright-v2`, `dataviz`, `dataviz-dark`, `outdoor-v2`, `hybrid`.
    3. For each candidate light + dark pair, curl-verify:
       ```bash
       curl -sI "https://api.maptiler.com/maps/{styleId}/style.json?key=${MAPTILER_KEY}" | head -5
       ```
       Confirm HTTP 200 + `content-type: application/json`.
    4. Recommend a default light + dark pair. RESEARCH prefers `dataviz` / `dataviz-dark` for the muted look. Fall back to `streets-v2` / `streets-v2-dark` if `dataviz` is not on the free tier.
    5. Record findings in `.planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md`:
       - Table of style IDs tested + HTTP status per ID
       - Chosen light + dark IDs with 1-line justification
       - Any surprises (renamed IDs, gated-behind-paywall, etc.)

    **This document is the source of truth for the enum values in Task 2.** Do not proceed to Task 2 without it on disk.
  </action>
  <verify>
    ```bash
    cat .planning/phases/04-osm-pipeline/04-11-STYLE-SPIKE.md | head -40
    ```
    File exists, contains style-ID table, chosen defaults, and curl-verified status codes.
  </verify>
</task>

<task type="auto">
  <name>Task 2: TileProviderConfig model + MapTilerStyle enum + unit tests</name>
  <files>
    lib/features/map/data/tile_provider_config.dart
    test/features/map/tile_provider_config_test.dart
  </files>
  <intent>Pure-Dart immutable config that resolves style URLs from the enum + injected key.</intent>
  <action>
    Create `lib/features/map/data/tile_provider_config.dart`:

    ```dart
    /// Enum values populated from 04-11-STYLE-SPIKE.md. Do NOT change without a
    /// fresh spike — free-tier catalog is not stable across accounts.
    enum MapTilerStyle {
      dataviz,       // light default — TBD confirm from spike
      datavizDark,   // dark default
      streetsV2,     // fallback if dataviz is gated
      streetsV2Dark,
    }

    extension MapTilerStyleId on MapTilerStyle {
      String get id {
        switch (this) {
          case MapTilerStyle.dataviz: return 'dataviz';
          case MapTilerStyle.datavizDark: return 'dataviz-dark';
          case MapTilerStyle.streetsV2: return 'streets-v2';
          case MapTilerStyle.streetsV2Dark: return 'streets-v2-dark';
        }
      }
    }

    /// Immutable tile-provider configuration. Owns the (styleId, key) tuple and
    /// resolves style URLs. Empty key => hasKey=false; callers must diagnose.
    class TileProviderConfig {
      const TileProviderConfig({
        required this.lightStyle,
        required this.darkStyle,
        required this.apiKey,
      });

      final MapTilerStyle lightStyle;
      final MapTilerStyle darkStyle;
      final String apiKey;

      bool get hasKey => apiKey.isNotEmpty;

      /// Resolves the style URL for [style]. Callers must check [hasKey] first.
      Uri styleUrl(MapTilerStyle style) {
        assert(hasKey, 'apiKey is empty — check --dart-define=MAPTILER_KEY');
        return Uri.parse(
          'https://api.maptiler.com/maps/${style.id}/style.json?key=$apiKey',
        );
      }
    }
    ```

    Tests in `test/features/map/tile_provider_config_test.dart`:
    1. `styleUrl formats correctly for dataviz` — assert full URL matches expected.
    2. `styleUrl formats correctly for streetsV2Dark` — assert `streets-v2-dark` in path.
    3. `hasKey false on empty apiKey` — construct with `apiKey: ''`, assert `hasKey == false`.
    4. `styleUrl asserts on empty apiKey in debug` — expect assertion error in debug builds only (use `expect(() => …, throwsAssertionError)` guarded by `assert(true)`-detected debug mode).

    Package imports only. No new pubspec deps.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/map/tile_provider_config_test.dart
    ```
    Analyze clean; all 4 tests green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Wire MAPTILER_KEY through main.dart + provider + Settings > About + CI</name>
  <files>
    lib/main.dart
    lib/features/map/presentation/providers/map_style_provider.dart
    lib/features/settings/presentation/widgets/about_section.dart
    env/dev.json.example
    .gitignore
    README.md
    .github/workflows/ci.yml
  </files>
  <intent>End-to-end key delivery + attribution.</intent>
  <action>
    **`lib/main.dart`:**
    - Add near the top of `main()`:
      ```dart
      const kMaptilerKey = String.fromEnvironment('MAPTILER_KEY');
      ```
    - Construct a `TileProviderConfig` from `kMaptilerKey` with the light/dark defaults from Task 1.
    - Inject via `ProviderScope(overrides: [tileProviderConfigProvider.overrideWithValue(config)], child: …)`.
    - If `kMaptilerKey.isEmpty`, call `AppLogger.warn('MAPTILER_KEY not set — map will show blank tiles')` (does not throw; the app still boots).

    **`lib/features/map/presentation/providers/map_style_provider.dart`:**
    - Add a new provider `tileProviderConfigProvider` (plain `Provider<TileProviderConfig>` — no codegen).
    - Refactor the existing `mapStyleAssetProvider` (or equivalent — grep first) into `mapStyleUrlProvider` that returns a `String` (the MapTiler URL). Read the current theme brightness from the existing brightness provider; return `config.styleUrl(config.lightStyle).toString()` or dark counterpart.
    - Leave the old asset-path provider in place for one commit — 04-12 deletes it. This keeps the map screen bootable if the swap has a hiccup.

    **`lib/features/settings/presentation/widgets/about_section.dart`:**
    - Locate the existing About section (grep for `About` in `lib/features/settings/`).
    - Add an "Attribution" subsection with two clickable rows:
      ```
      © MapTiler       (opens https://www.maptiler.com/copyright/)
      © OpenStreetMap contributors  (opens https://www.openstreetmap.org/copyright)
      ```
    - Use `url_launcher` if already in pubspec; if not, use `flutter/services.dart` `launchUrl` via the existing helper. Do NOT add a new pubspec dep for this alone — check first.
    - Ensure both links are keyboard/screen-reader focusable (Semantics widget).

    **`env/dev.json.example`:**
    ```json
    {
      "MAPTILER_KEY": "your-personal-free-tier-key-here",
      "_comment": "Copy to env/dev.json (gitignored). Get key from https://cloud.maptiler.com/account/keys/"
    }
    ```

    **`.gitignore`:** verify `env/dev.json` is ignored. If not covered by an existing pattern, append `env/dev.json` (do not touch other entries).

    **`README.md`:** verify a "MapTiler key setup" section exists. If missing, add one documenting `env/dev.json.example` → `env/dev.json` and how to run:
    ```bash
    flutter run --dart-define-from-file=env/dev.json
    ```
    If the section already exists (README may already document env setup), leave it alone.

    **`.github/workflows/ci.yml`:**
    - Find every `flutter build` / `flutter test` invocation.
    - Add `--dart-define=MAPTILER_KEY=${{ secrets.MAPTILER_KEY }}` to each build/test step.
    - For CI without the secret (fork PRs, local `act` runs), the empty-key path is tolerated — tests must not assume a real key. Add a comment noting this.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test
    grep -r "String.fromEnvironment('MAPTILER_KEY')" lib/
    grep -R "MAPTILER_KEY" .github/workflows/
    grep -F "env/dev.json" .gitignore
    cat env/dev.json.example
    ```
    Analyze clean; tests green; key sourced only via `--dart-define`; CI workflows reference `secrets.MAPTILER_KEY`; `env/dev.json` gitignored; example file exists.
  </verify>
</task>

## Success Criteria

- `flutter analyze` clean; all tests green.
- Style-spike doc on disk with confirmed style IDs.
- `TileProviderConfig` model + tests exist.
- `MAPTILER_KEY` flows through `main.dart` → provider → map style URL (though the map still uses old assets until 04-12).
- Settings > About shows the attribution text with clickable links.
- CI workflows inject the key at build time.
- `env/dev.json.example` documents the dev workflow; real `env/dev.json` is gitignored.

## Ralph Loop

- Tight loop: `flutter analyze`
- Behavior-sensitive: `flutter test` after Task 2 (unit tests) and Task 3 (URL provider refactor could break existing widget tests).
- Pre-push hook covers the full test suite.

## Deviations

- If `dataviz`/`dataviz-dark` are NOT on the free tier (spike reveals paywall), fall back to `streets-v2`/`streets-v2-dark`. Document in `04-11-STYLE-SPIKE.md`.
- If the existing About screen doesn't exist yet (grep returns nothing), create a minimal `AboutSection` widget consumed by `SettingsScreen`. Do not build a whole new Settings feature — one section is enough.
- If `url_launcher` is not in pubspec and the About screen has no clickable-link precedent, add `url_launcher` (alphabetically-sorted per project rule).

## Commit Strategy

- Task 1 commit: `docs(04-11): document MapTiler style-ID spike results`
- Task 2 commit: `feat(04-11): add TileProviderConfig + MapTilerStyle enum + tests`
- Task 3 commit: `feat(04-11): wire MAPTILER_KEY through main + provider + CI + attribution`
