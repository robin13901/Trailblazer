---
id: 04-16
phase: 04-osm-pipeline
plan: 16
type: execute
wave: 3
depends_on: [04-15]
files_modified:
  - lib/core/admin_geometry/admin_polygon_downloader.dart
  - lib/core/admin_geometry/admin_polygon_simplifier.dart
  - tool/osm_pipeline/bin/fetch_admin_polygons.dart
  - tool/osm_pipeline/pubspec.yaml
  - assets/admin/germany_admin.geojson.gz
  - pubspec.yaml
  - lib/features/admin/data/admin_region.dart
  - lib/features/admin/data/admin_region_lookup.dart
  - lib/features/admin/data/admin_region_providers.dart
  - lib/features/admin/data/admin_bundle_refresher.dart
  - lib/features/settings/presentation/widgets/data_management_section.dart
  - lib/core/prefs/app_prefs.dart
  - test/features/admin/admin_region_lookup_test.dart
  - test/core/admin_geometry/admin_polygon_simplifier_test.dart
autonomous: false
requirements: [OSM-04]

must_haves:
  truths:
    - "`tool/osm_pipeline/bin/fetch_admin_polygons.dart` is a one-shot dev-machine CLI that fetches DE admin_level=2/4/6/8/9/10 relations via Overpass, assembles multipolygons, simplifies (Douglas-Peucker), and writes `assets/admin/germany_admin.geojson.gz` under 15 MB."
    - "`assets/admin/germany_admin.geojson.gz` is committed to the repo and referenced from `pubspec.yaml`'s `assets:` section."
    - "Runtime `AdminRegionLookup` loads the bundled GeoJSON at first-use, builds an in-memory spatial index (hash grid at 0.01° cells recommended), and `regionAt(lat, lng, level) → AdminRegion?` returns the correct region+name in <5 ms."
    - "Settings > Data > `Refresh admin regions` button triggers `AdminBundleRefresher` which re-runs the Overpass fetch at runtime, replaces the app-documents-dir copy, updates `AppPrefs.adminBundleVersion`."
    - "The refresh path is the ONLY runtime user-facing OSM operation in Phase 4 besides trip-time Overpass fetches; it's user-triggered, not automatic."
    - "5 known Kleinheubach + Berlin coordinates round-trip through `regionAt` and return the expected Gemeinde / Landkreis / Bundesland names (test fixtures documented)."
    - "The polygon downloader + simplifier code lives in `lib/core/admin_geometry/` (main-package pure Dart) and is imported by BOTH the runtime `AdminBundleRefresher` AND the dev CLI `tool/osm_pipeline/bin/fetch_admin_polygons.dart` (via `package:auto_explore/core/admin_geometry/...`). Single source of truth — no duplication."
  artifacts:
    - path: "lib/core/admin_geometry/admin_polygon_downloader.dart"
      provides: "Shared Overpass fetch: query construction, User-Agent, retry+backoff. Consumed by both dev CLI and runtime refresher."
      min_lines: 60
    - path: "lib/core/admin_geometry/admin_polygon_simplifier.dart"
      provides: "Shared multipolygon assembly + Douglas-Peucker simplification + GeoJSON FeatureCollection emitter. Consumed by both dev CLI and runtime refresher."
      min_lines: 50
    - path: "tool/osm_pipeline/bin/fetch_admin_polygons.dart"
      provides: "One-shot dev CLI: imports from `package:auto_explore/core/admin_geometry/…`; fetches → simplifies → writes assets/admin/germany_admin.geojson.gz."
      min_lines: 40
    - path: "assets/admin/germany_admin.geojson.gz"
      provides: "Committed bundled asset; <15 MB gzipped."
    - path: "lib/features/admin/data/admin_region.dart"
      provides: "Immutable AdminRegion model (osmId, adminLevel, name, nameDe?, bbox, polygon)."
      min_lines: 40
    - path: "lib/features/admin/data/admin_region_lookup.dart"
      provides: "Lazy loader + hash-grid spatial index + regionAt(lat, lng, level)."
      min_lines: 100
    - path: "lib/features/admin/data/admin_bundle_refresher.dart"
      provides: "Runtime Overpass fetch → replace app-docs bundle → bump AppPrefs version."
      min_lines: 60
  key_links:
    - from: "lib/features/admin/data/admin_region_lookup.dart"
      to: "assets/admin/germany_admin.geojson.gz"
      via: "rootBundle.load('assets/admin/germany_admin.geojson.gz') → gunzip → parse GeoJSON FeatureCollection"
      pattern: "rootBundle\\.load|germany_admin\\.geojson"
    - from: "lib/features/settings/presentation/widgets/data_management_section.dart"
      to: "lib/features/admin/data/admin_bundle_refresher.dart"
      via: "'Refresh admin regions' button invokes refresher.refreshFromOverpass()"
      pattern: "AdminBundleRefresher|refreshFromOverpass"
    - from: "tool/osm_pipeline/bin/fetch_admin_polygons.dart"
      to: "lib/core/admin_geometry/"
      via: "dev CLI imports shared downloader + simplifier from `package:auto_explore/core/admin_geometry/…` (single source of truth)"
      pattern: "package:auto_explore/core/admin_geometry"
---

## Goal

Ship the bundled Germany admin-polygon asset + runtime lookup service. The dev-side generator lives in `tool/osm_pipeline/bin/fetch_admin_polygons.dart` (new, one-shot). The runtime side lazily loads the bundle at first-use, indexes via hash grid, and answers `regionAt(lat, lng, level)` in <5 ms. Settings > Data has a manual refresh button.

## Context

- Research: `.planning/phases/04-osm-pipeline/04-RESEARCH.md` §3 (Overpass one-shot download, split-per-level vs single-file, DP simplification tolerances, size budget) and §4 (why Nominatim is not needed — bundled polygons carry OSM `name` tags natively).
- Locked decision: single-file `germany_admin.geojson.gz` (not split per level) to keep loader simple. If size projections balloon, we can split later.
- Overpass query template (from RESEARCH §3):
  ```
  [out:json][timeout:600];
  area["ISO3166-1"="DE"][admin_level=2]->.de;
  (relation["boundary"="administrative"]["admin_level"~"^(2|4|6|8|9|10)$"](area.de););
  out geom;
  ```
- Douglas-Peucker tolerance table: L2 <10 m, L4 <30 m, L6 <50 m, L8 <100 m, L9/L10 <100 m (RESEARCH §3 targets <15 MB gzipped).
- Runtime spatial index: hash grid at 0.01° cells built lazily on first `regionAt` call (RESEARCH §3 recommends over R-Tree for simplicity).
- Existing `AppPrefs` (from Phase 1): plain string-keyed prefs; add `admin_bundle_version` key.
- **Shared runtime + dev-CLI code lives in `lib/core/admin_geometry/`.** Both `AdminBundleRefresher` (runtime) and `tool/osm_pipeline/bin/fetch_admin_polygons.dart` (dev CLI) import from `package:auto_explore/core/admin_geometry/…`. Single source of truth. `tool/osm_pipeline/pubspec.yaml` must declare a path-dep on the main package (grep first — it likely already does).
- `tool/osm_pipeline/` sub-package: adds only the new `bin/fetch_admin_polygons.dart`. Existing files are UNTOUCHED. No new files under `tool/osm_pipeline/lib/admin/`.

## Tasks

<task type="auto">
  <name>Task 1: Shared admin_geometry package + dev CLI + committed bundled asset</name>
  <files>
    lib/core/admin_geometry/admin_polygon_downloader.dart
    lib/core/admin_geometry/admin_polygon_simplifier.dart
    tool/osm_pipeline/bin/fetch_admin_polygons.dart
    tool/osm_pipeline/pubspec.yaml
    pubspec.yaml
    assets/admin/germany_admin.geojson.gz
    test/core/admin_geometry/admin_polygon_simplifier_test.dart
  </files>
  <intent>One-time dev-machine run produces the committed bundled asset. Shared code so 04-16 Task 3's runtime refresher can reuse it.</intent>
  <action>
    **`tool/osm_pipeline/pubspec.yaml`:** verify it declares a path-dep on the main package:
    ```yaml
    dependencies:
      auto_explore:
        path: ../..
      http: ^1.2.0    # if not already
    ```
    Grep first — path-dep may already be there. Also add `http` if not present (alphabetized).

    **`lib/core/admin_geometry/admin_polygon_downloader.dart`:** (shared code)
    - `class AdminPolygonDownloader` with `Future<String> fetchDeAdminRelations({http.Client? client, Uri? endpoint})`.
    - Uses the Overpass query template above (server-side timeout=600s).
    - Sends User-Agent header `Trailblazer-AdminPolyFetch/0.1`.
    - Endpoint default: `https://overpass-api.de/api/interpreter`. Fallback: same live-probed URL as 04-13's client.
    - Retries 3x on 429/5xx with 30s / 60s / 120s backoff (heavy query; server may be slow).
    - Returns raw JSON body.
    - Package imports only. Depends on `http`, not on any Flutter-specific package (so `dart run` from the dev CLI works without a Flutter runtime).

    **`lib/core/admin_geometry/admin_polygon_simplifier.dart`:** (shared code)
    - `class AdminPolygonSimplifier` with `Map<String, dynamic> assembleAndSimplify(String rawJson)`.
    - Assemble Overpass relations → multipolygons (nontrivial for concave/donut regions):
      1. Group `way` members by relation.
      2. Chain ways head-to-tail to form closed rings.
      3. Outer role rings → outer polygons; inner role → holes.
    - Alternative: use existing `tool/osm_pipeline/lib/admin/` PBF-based code as reference (grep first — 04-04 did admin extraction). If the shape is very different, write fresh — do not force-fit.
    - Douglas-Peucker simplification per polygon; tolerance from a level-lookup:
      ```dart
      const _toleranceMeters = {2: 10.0, 4: 30.0, 6: 50.0, 8: 100.0, 9: 100.0, 10: 100.0};
      ```
      Convert meters → degrees using local latitude (roughly `1° lat ≈ 111 km`).
    - Emit a single `FeatureCollection` GeoJSON:
      ```json
      {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "properties": {
              "osm_id": 51477,
              "admin_level": 2,
              "name": "Deutschland",
              "name:de": "Deutschland"
            },
            "geometry": { "type": "MultiPolygon", "coordinates": [...] }
          }
        ]
      }
      ```
    - Preserve `name` and `name:de` tags. Drop all other tags.
    - Pure Dart; no Flutter imports.

    **`tool/osm_pipeline/bin/fetch_admin_polygons.dart`:**
    ```dart
    import 'dart:convert';
    import 'dart:io';
    import 'package:auto_explore/core/admin_geometry/admin_polygon_downloader.dart';
    import 'package:auto_explore/core/admin_geometry/admin_polygon_simplifier.dart';

    Future<void> main(List<String> args) async {
      final outputPath = args.isNotEmpty ? args[0] : 'assets/admin/germany_admin.geojson.gz';
      stderr.writeln('Fetching Germany admin relations from Overpass…');
      final raw = await AdminPolygonDownloader().fetchDeAdminRelations();
      stderr.writeln('Received ${raw.length ~/ 1024} KB. Assembling multipolygons…');
      final featureCollection = AdminPolygonSimplifier().assembleAndSimplify(raw);
      stderr.writeln('Writing gzipped GeoJSON to $outputPath…');
      final bytes = utf8.encode(jsonEncode(featureCollection));
      final gzipped = GZipCodec().encode(bytes);
      await File(outputPath).parent.create(recursive: true);
      await File(outputPath).writeAsBytes(gzipped);
      stderr.writeln('Done. Size: ${gzipped.length ~/ 1024} KB gzipped.');
      if (gzipped.length > 15 * 1024 * 1024) {
        stderr.writeln('WARNING: size exceeds 15 MB budget. Consider stricter DP tolerances.');
      }
    }
    ```

    **Run the CLI ONCE from the dev machine to produce the committed asset** (this call can take up to 10 minutes — Overpass server-side timeout is 600s):
    ```bash
    cd tool/osm_pipeline
    dart run bin/fetch_admin_polygons.dart ../../assets/admin/germany_admin.geojson.gz
    ls -lh ../../assets/admin/germany_admin.geojson.gz    # should be <15 MB
    ```
    Commit the resulting `assets/admin/germany_admin.geojson.gz`.

    **`pubspec.yaml` (app root):** add `assets/admin/germany_admin.geojson.gz` to the `assets:` section. Ensure alphabetical order among asset entries.

    **Tests (`test/core/admin_geometry/admin_polygon_simplifier_test.dart`):**
    1. `simplify preserves closed rings` — feed a rectangular polygon, assert output is still closed.
    2. `simplify preserves multipolygon structure with holes` — synthetic donut polygon → assert outer + inner survive.
    3. `simplify with tighter tolerance keeps more points` — same input at 5m tolerance vs 100m tolerance.
    4. `name and name:de tags are preserved on features`.

    Do NOT unit-test the network downloader here (network flakiness). One integration test is fine but optional.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/core/admin_geometry/admin_polygon_simplifier_test.dart
    ls -lh assets/admin/germany_admin.geojson.gz
    # Manually verify: unzip inspection
    gunzip -c assets/admin/germany_admin.geojson.gz | head -c 500
    ```
    Analyzer clean; simplifier tests green; bundled asset exists and is <15 MB.
  </verify>
</task>

<task type="checkpoint:human-verify">
  <name>Task 1b: Verify bundled asset sanity before commit</name>
  <what-built>
    Task 1 produced `assets/admin/germany_admin.geojson.gz` via a ~10-minute Overpass fetch. Before committing, a human should sanity-check size + feature-count distribution.
  </what-built>
  <how-to-verify>
    Run:
    ```bash
    ls -lh assets/admin/germany_admin.geojson.gz
    # Should show a file 8-15 MB
    gunzip -c assets/admin/germany_admin.geojson.gz | jq '.features | length'
    # Should show several thousand features (rough: 1 L2 + ~16 L4 + ~40 L6 + ~11000 L8 + Ns for L9/L10)
    gunzip -c assets/admin/germany_admin.geojson.gz | jq '[.features[].properties.admin_level] | group_by(.) | map({level: .[0], count: length})'
    # Should show non-zero counts for levels 2, 4, 6, 8, and typically 9 + 10
    ```

    Sign-off criteria:
    - File size: 8-15 MB gzipped.
    - L2 count: 1 (Germany).
    - L4 count: ~16 (Bundesländer).
    - L6 count: ~40 (Regierungsbezirke; NOT every state uses L6 — 20-50 range is fine).
    - L8 count: several thousand (Gemeinden).
    - No level entirely missing.

    If any check fails (e.g. file is 40 MB, or L8 count is 5) — DO NOT commit. Adjust DP tolerances in `admin_polygon_simplifier.dart`, re-run Task 1's CLI, re-verify. Escalate to user if tolerances at their stricter limit still blow budget.
  </how-to-verify>
  <resume-signal>Type "approved" once the checks pass and the asset is committed, or describe issues.</resume-signal>
</task>

<task type="auto">
  <name>Task 2: Runtime AdminRegion model + AdminRegionLookup with hash-grid index + tests</name>
  <files>
    lib/features/admin/data/admin_region.dart
    lib/features/admin/data/admin_region_lookup.dart
    lib/features/admin/data/admin_region_providers.dart
    test/features/admin/admin_region_lookup_test.dart
  </files>
  <intent>Lazy-loaded in-memory spatial index for `regionAt(lat, lng, level)`.</intent>
  <action>
    **`lib/features/admin/data/admin_region.dart`:**
    ```dart
    class AdminRegion {
      const AdminRegion({
        required this.osmId,
        required this.adminLevel,
        required this.name,
        this.nameDe,
        required this.bboxMinLat, required this.bboxMinLon,
        required this.bboxMaxLat, required this.bboxMaxLon,
        required this.polygon, // list of rings; ring 0 = outer, rest = holes
      });

      final int osmId;
      final int adminLevel;
      final String name;
      final String? nameDe;
      final double bboxMinLat, bboxMinLon, bboxMaxLat, bboxMaxLon;
      final List<List<LatLng>> polygon;

      bool containsPoint(double lat, double lon) {
        if (lat < bboxMinLat || lat > bboxMaxLat) return false;
        if (lon < bboxMinLon || lon > bboxMaxLon) return false;
        // Ray-cast on outer ring, subtract holes.
        // Standard even-odd rule; ignore rings.length == 0 edge case (defensive).
        // ...
      }
    }
    ```

    **`lib/features/admin/data/admin_region_lookup.dart`:**
    - Constructor: `AdminRegionLookup({AssetBundle? bundle, String assetPath = 'assets/admin/germany_admin.geojson.gz'})`.
    - `Future<void> ensureLoaded()` — idempotent; loads once. Reads bundle → gunzip → parse GeoJSON → build `List<AdminRegion>` (typically ~11k regions). Build hash-grid index at 0.01° cells: `Map<int, List<int>> _gridToRegionIdx` where the int key is packed `(latCell << 16) | lonCell`.
    - `AdminRegion? regionAt(double lat, double lon, int adminLevel)`:
      1. `await ensureLoaded()`.
      2. Compute the 0.01° cell key.
      3. Look up candidate region indices from `_gridToRegionIdx[key]`.
      4. Filter to `adminLevel == adminLevel`.
      5. For each candidate, call `region.containsPoint(lat, lon)`.
      6. Return first match (regions at the same level don't overlap).
      7. Return null if no match.
    - `void invalidate()` — clears in-memory cache; next `regionAt` reloads. Used by refresher (Task 3).
    - **Runtime file precedence:** if `getApplicationDocumentsDirectory()/admin/germany_admin.geojson.gz` exists AND its `admin_bundle_version` (via AppPrefs) is newer than the shipped bundle's version, load THAT instead of the assets/-bundled copy.

    **`lib/features/admin/data/admin_region_providers.dart`:**
    ```dart
    final adminRegionLookupProvider = Provider<AdminRegionLookup>((ref) {
      final lookup = AdminRegionLookup();
      ref.onDispose(() {
        // no explicit dispose needed
      });
      return lookup;
    });
    ```
    Plain `Provider<T>` — no codegen.

    **Tests (`test/features/admin/admin_region_lookup_test.dart`):**

    Fixture: build a small in-memory fixture (or use a subset of the real bundle) with 5 known regions:
    - Berlin (Bundesland, admin_level=4, name="Berlin")
    - Berlin-Kreuzberg (Ortsteil, admin_level=10, name="Kreuzberg")
    - Landkreis Miltenberg (Landkreis, admin_level=6, name="Miltenberg")
    - Kleinheubach (Gemeinde, admin_level=8, name="Kleinheubach")
    - Bayern (Bundesland, admin_level=4, name="Bayern")

    Tests:
    1. `regionAt(52.52, 13.405, 4) === "Berlin"`.
    2. `regionAt(52.4993, 13.4025, 10) === "Kreuzberg"`.
    3. `regionAt(49.796, 9.185, 8) === "Kleinheubach"`.
    4. `regionAt(49.796, 9.185, 6) === "Miltenberg"`.
    5. `regionAt(49.796, 9.185, 4) === "Bayern"`.
    6. `regionAt over ocean returns null`.
    7. `regionAt latency: 1000 calls average < 5 ms per call` (Stopwatch test, avg not p99).
    8. `ensureLoaded is idempotent` — call twice, assert bundle parsed only once (assert an internal counter or measure via a spy on the asset bundle).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/admin/admin_region_lookup_test.dart
    ```
    Analyze clean; all 8 tests green; latency test passes.
  </verify>
</task>

<task type="auto">
  <name>Task 3: AdminBundleRefresher + Settings > Data > "Refresh admin regions" button</name>
  <files>
    lib/features/admin/data/admin_bundle_refresher.dart
    lib/features/admin/data/admin_region_providers.dart
    lib/features/settings/presentation/widgets/data_management_section.dart
    lib/core/prefs/app_prefs.dart
  </files>
  <intent>Runtime user-triggered refresh of the admin bundle from Overpass.</intent>
  <action>
    **`lib/core/prefs/app_prefs.dart`:** add getter/setter for `adminBundleVersion` (string; format `YYYYMMDDHHMM` or a Unix timestamp). Grep existing prefs pattern and follow it.

    **`lib/features/admin/data/admin_bundle_refresher.dart`:**
    ```dart
    import 'package:auto_explore/core/admin_geometry/admin_polygon_downloader.dart';
    import 'package:auto_explore/core/admin_geometry/admin_polygon_simplifier.dart';

    class AdminBundleRefresher {
      AdminBundleRefresher({
        required this.downloader,
        required this.simplifier,
        required this.appPrefs,
        required this.lookup,
        Directory Function()? docsDir,
      });

      final AdminPolygonDownloader downloader; // from lib/core/admin_geometry/ (SHARED with dev CLI)
      final AdminPolygonSimplifier simplifier; // from lib/core/admin_geometry/ (SHARED with dev CLI)
      final AppPrefs appPrefs;
      final AdminRegionLookup lookup;

      /// Full runtime refresh: fetches from Overpass, replaces the docs-dir copy,
      /// bumps AppPrefs version, invalidates the lookup cache so next regionAt
      /// call reloads.
      Future<void> refreshFromOverpass({Duration timeout = const Duration(minutes: 5)}) async {
        final raw = await downloader.fetchDeAdminRelations();
        final fc = simplifier.assembleAndSimplify(raw);
        final bytes = utf8.encode(jsonEncode(fc));
        final gzipped = GZipCodec().encode(bytes);
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/admin/germany_admin.geojson.gz');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(gzipped);
        await appPrefs.setAdminBundleVersion(DateTime.now().toIso8601String());
        lookup.invalidate(); // clears in-memory cache; next regionAt reloads
      }
    }
    ```

    **Shared runtime + dev-CLI code:** both `AdminBundleRefresher` (this file) and `tool/osm_pipeline/bin/fetch_admin_polygons.dart` (from Task 1) import from `package:auto_explore/core/admin_geometry/…`. Single source of truth — no duplication.

    **`lib/features/admin/data/admin_region_providers.dart`:** add `adminBundleRefresherProvider`.

    **`lib/features/settings/presentation/widgets/data_management_section.dart`:**
    - Add a "Data" section to Settings (grep existing settings structure).
    - Add a ListTile "Refresh admin regions" with subtitle showing `AppPrefs.adminBundleVersion` (or "bundled version" if unset).
    - On tap: show a confirmation dialog ("This will download ~10 MB of data and may take 1-2 minutes"), then call `refresher.refreshFromOverpass()` in a loading state.
    - On success: SnackBar "Admin regions updated".
    - On error: SnackBar with DomainError.userMessage.

    Do NOT block the UI thread — run in a `compute()`-friendly manner or accept a brief spinner (a 1-minute Overpass call happens on the isolate that owns `http.Client`, so it's async but not off-isolate).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/admin/ test/features/settings/
    ```
    Analyze clean; existing tests unbroken; new Settings widget builds without errors.
  </verify>
</task>

## Success Criteria

- Shared code lives in `lib/core/admin_geometry/`; both dev CLI and runtime refresher import from there.
- `tool/osm_pipeline/bin/fetch_admin_polygons.dart` runs, produces `<15 MB` gzipped bundle.
- Bundle committed at `assets/admin/germany_admin.geojson.gz` and declared in `pubspec.yaml`.
- Runtime `regionAt(lat, lng, level)` returns correct names for the 5 fixture coordinates.
- Latency <5 ms per query.
- Settings > Data > "Refresh admin regions" invokes runtime refresh; version updates in AppPrefs.
- `flutter analyze` clean.
- `tool/osm_pipeline/` outside of the new `bin/fetch_admin_polygons.dart` is UNTOUCHED (grep-verify).

## Ralph Loop

- Tight loop: `flutter analyze` (main package) + `dart analyze` (tool/osm_pipeline sub-package).
- Behavior-sensitive (all three tasks): `flutter test` after each.
- Pre-push hook covers full suite.

## Deviations

- If the ~11k L8 polygons blow the 15 MB budget after DP simplification, tighten L8 tolerance to 150 m or 200 m. Visual acceptability at phone-screen size is fine at 200 m per RESEARCH §3.
- If Douglas-Peucker implementation is nontrivial to hand-roll, use the `package:turf` port if available in pub, OR the `package:geobase` simplifier. Alphabetize and pin.
- If the Overpass query for full-Germany admin relations exceeds server limits at Task 1 execution time (unlikely — RESEARCH says 30-90s), split into per-admin-level queries and merge client-side. Update the CLI accordingly.
- If `regionAt` <5 ms fails on target device (e.g. hash grid too sparse), add a secondary bbox-prefilter step before ray-cast. Do not switch to R-Tree unless truly needed.
- If Task 1's simplifier assembly is too hard to derive from existing `04-04-admin-boundary-extraction-PLAN.md`'s PBF-based code (different input shape: Overpass JSON vs PBF), write a fresh Overpass-JSON-aware assembler — do not force-fit the PBF code path.
- If `tool/osm_pipeline/pubspec.yaml` doesn't already declare a path-dep on the main package, add it. If circular-dep concerns arise, the shared code can move to a leaf `packages/admin_geometry/` — but only if truly needed.

## Commit Strategy

- Task 1 commit: `feat(04-16): shared admin_geometry package + dev CLI to fetch + simplify polygons`
- Task 1 asset commit (after Task 1b checkpoint approval): `chore(04-16): commit bundled germany_admin.geojson.gz (X MB gzipped)`
- Task 2 commit: `feat(04-16): AdminRegionLookup with hash-grid spatial index`
- Task 3 commit: `feat(04-16): runtime admin-bundle refresher + Settings > Data button`
