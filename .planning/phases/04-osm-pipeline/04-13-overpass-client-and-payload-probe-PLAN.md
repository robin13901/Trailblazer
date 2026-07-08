---
id: 04-13
phase: 04-osm-pipeline
plan: 13
type: execute
wave: 2
wave_ordering: serial-within-wave
wave_serial_order: 1  # runs first in Wave 2
depends_on: [04-12]
files_modified:
  - pubspec.yaml
  - lib/features/matching/data/overpass_client.dart
  - lib/features/matching/data/overpass_query_builder.dart
  - lib/features/matching/data/overpass_response_parser.dart
  - lib/features/matching/domain/way_candidate.dart
  - lib/features/matching/data/matching_providers.dart
  - test/features/matching/overpass_client_test.dart
  - test/features/matching/overpass_query_builder_test.dart
  - test/features/matching/overpass_response_parser_test.dart
  - test/fixtures/overpass/urban_kreuzberg_5x5km.json.gz
  - test/fixtures/overpass/rural_grebenhain_5x5km.json.gz
  - test/fixtures/overpass/overload_429.txt
  - test/fixtures/overpass/timeout_504.txt
  - .planning/phases/04-osm-pipeline/04-13-PAYLOAD-PROBE.md
autonomous: true
requirements: [OSM-02, OSM-05]

must_haves:
  truths:
    - "`OverpassClient` fetches `way[highway]` results within a bbox and returns parsed `WayCandidate` objects."
    - "Two endpoints are configured: primary `https://overpass-api.de/api/interpreter`, fallback URL determined at build time by a live probe (Kumi if reachable, else `overpass.private.coffee`)."
    - "`User-Agent: Trailblazer/0.1` header is set on every request (Overpass usage policy requirement)."
    - "The client is fully testable via `http.Client` injection (`MockClient` in tests)."
    - "Retry + exponential backoff on 429/503/504/timeout; second failure switches to fallback endpoint; third failure surfaces DomainError."
    - "The `WayCandidate` model + `OnewayDirection` enum are on disk with fields matching the existing `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart` ways-row shape."
    - "The cross-country payload probe (~30 min inside this plan) is documented in the plan's SUMMARY with the observed JSON size + parse time for a realistic Berlin→Munich autobahn trip bbox."
  artifacts:
    - path: "lib/features/matching/data/overpass_client.dart"
      provides: "HTTP client with endpoint fallback, retry+backoff, injectable http.Client."
      min_lines: 120
    - path: "lib/features/matching/data/overpass_query_builder.dart"
      provides: "Pure-function query builder for `[out:json][timeout:25]; way[highway]({bbox}); out geom qt;`."
      min_lines: 30
    - path: "lib/features/matching/data/overpass_response_parser.dart"
      provides: "GeoJSON-adjacent-shape parser: `{lat, lon}` → LatLng; oneway normalization; maxspeed parsing."
      min_lines: 80
    - path: "lib/features/matching/domain/way_candidate.dart"
      provides: "Immutable WayCandidate model + OnewayDirection enum; matches osm_sqlite_writer's ways row shape."
      min_lines: 60
    - path: "lib/features/matching/data/matching_providers.dart"
      provides: "Riverpod providers: overpassEndpointProvider, overpassFallbackEndpointProvider, httpClientProvider, overpassClientProvider."
      min_lines: 40
    - path: "test/fixtures/overpass/urban_kreuzberg_5x5km.json.gz"
      provides: "Real Overpass response, gzipped."
    - path: "test/fixtures/overpass/rural_grebenhain_5x5km.json.gz"
      provides: "Real Overpass response, gzipped."
  key_links:
    - from: "lib/features/matching/data/overpass_client.dart"
      to: "lib/features/matching/data/overpass_response_parser.dart"
      via: "client hands raw JSON to parser; parser returns List<WayCandidate>"
      pattern: "OverpassResponseParser|parseWays"
    - from: "lib/features/matching/data/overpass_client.dart"
      to: "DomainError.wrap"
      via: "non-DomainError throwables are wrapped at the client boundary per project rule"
      pattern: "DomainError\\.wrap"
---

## Goal

Build a testable Overpass HTTP client that fetches `highway=*` ways within a bbox and returns parsed `WayCandidate` objects. Establish the mockable seam Wave 5's matcher will consume. Fold in a ~30-min payload probe against a real Berlin→Munich autobahn bbox to determine whether Wave 3's tile-splitting logic is mandatory-for-v1 or a nice-to-have.

## Context

- **Wave-2 serial ordering:** 04-13 → 04-14 → 04-15 are all `wave: 2` but MUST run serially in plan-number order. 04-14 consumes the `WayCandidate` model + `OverpassClient` created here; 04-15 consumes both. Not a parallel-wave. The `wave_ordering: serial-within-wave` frontmatter annotation makes this explicit for the orchestrator.

- Research: `.planning/phases/04-osm-pipeline/04-RESEARCH.md` §2 (Overpass endpoints, query format, response shape, rate limits, backoff strategy) and §6 (WayCandidate model shape).
- Endpoint fallback: primary = `overpass-api.de`; fallback = live-probed at planning time. Kumi (`overpass.kumi.systems`) is community-cited but unconfirmed; `overpass.private.coffee` is docs-verified. Both URLs go into the plan; the live probe decides which is default fallback.
- User-Agent header MANDATORY per Overpass usage policy.
- Rate-limit behavior: HTTP 429 / 5xx / timeout → retry with backoff, then fallback endpoint on second failure.
- Existing ways schema for reference: `tool/osm_pipeline/lib/output/osm_sqlite_writer.dart:488-505` — WayCandidate fields (wayId, geometry, highwayClass, name, ref, oneway, maxspeedKmh) mirror that shape so the fixture-PBF source in 04-15 can produce identical data.
- Project rules: package imports; `DomainError.wrap()` non-DomainError throwables at boundaries; new deps alphabetized.

## Tasks

<task type="auto">
  <name>Task 1: Add http dep + define WayCandidate + OnewayDirection + query builder + parser</name>
  <files>
    pubspec.yaml
    lib/features/matching/domain/way_candidate.dart
    lib/features/matching/data/overpass_query_builder.dart
    lib/features/matching/data/overpass_response_parser.dart
    test/features/matching/overpass_query_builder_test.dart
    test/features/matching/overpass_response_parser_test.dart
    test/fixtures/overpass/urban_kreuzberg_5x5km.json.gz
    test/fixtures/overpass/rural_grebenhain_5x5km.json.gz
  </files>
  <intent>Pure data-layer scaffolding: the model, the query builder, the parser, and the fixture files. No network yet.</intent>
  <action>
    **`pubspec.yaml`:** add `http: ^1.2.0` (alphabetized). Run `flutter pub get`.

    **`lib/features/matching/domain/way_candidate.dart`:**
    ```dart
    import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

    enum OnewayDirection { no, forward, backward }

    /// Kfz highway classes (14 tags — from Phase 4 CONTEXT / Kfz allowlist).
    const kfzHighwayClasses = <String>{
      'motorway', 'motorway_link',
      'trunk', 'trunk_link',
      'primary', 'primary_link',
      'secondary', 'secondary_link',
      'tertiary', 'tertiary_link',
      'unclassified', 'residential', 'living_street', 'road',
    };

    class WayCandidate {
      const WayCandidate({
        required this.wayId,
        required this.geometry,
        required this.highwayClass,
        this.name,
        this.ref,
        this.oneway = OnewayDirection.no,
        this.maxspeedKmh,
      });

      final int wayId;
      final List<LatLng> geometry;
      final String highwayClass;
      final String? name;
      final String? ref;
      final OnewayDirection oneway;
      final int? maxspeedKmh;

      @override
      bool operator ==(Object other) => other is WayCandidate
          && other.wayId == wayId; // wayId is stable across sources
      @override
      int get hashCode => wayId.hashCode;
    }
    ```

    **`lib/features/matching/data/overpass_query_builder.dart`:**
    ```dart
    class OverpassQueryBuilder {
      const OverpassQueryBuilder();

      /// Builds the QL body for a bbox highway fetch.
      /// Kfz-vs-Feldweg filtering is applied client-side after parse.
      String buildBboxHighwayQuery({
        required double minLat,
        required double minLon,
        required double maxLat,
        required double maxLon,
        int timeoutSeconds = 25,
      }) {
        // Overpass expects (south, west, north, east)
        return '[out:json][timeout:$timeoutSeconds];\n'
               'way[highway]($minLat,$minLon,$maxLat,$maxLon);\n'
               'out geom qt;';
      }
    }
    ```

    **`lib/features/matching/data/overpass_response_parser.dart`:**
    - Function `parseWays(String rawJson) → List<WayCandidate>`.
    - Handles:
      - `elements` array iteration; skips non-way elements.
      - `geometry: [{lat, lon}, ...]` → `List<LatLng>` (note: JSON is lat/lon, LatLng is lat/lng).
      - `tags` extraction: highway (required), name?, ref?, oneway (normalize: "yes"→forward, "-1"→backward, "no"|absent→no), maxspeed (parse; strip "mph"/"kmh"/"signals"/"walk" → null on failure).
      - Filter to Kfz allowlist via `kfzHighwayClasses.contains(highwayClass)`; drop others (Feldweg/Fußweg/service/etc.) at the parser boundary.
      - Non-numeric wayId → skip row (defensive).

    **Fixtures (`test/fixtures/overpass/`):**
    - Generate `urban_kreuzberg_5x5km.json` by running the real Overpass query against a Berlin Kreuzberg bbox (e.g. `52.4900,13.3700,52.5100,13.4100`). Save output. Gzip: `gzip -9 urban_kreuzberg_5x5km.json`.
    - Generate `rural_grebenhain_5x5km.json` similarly for a Grebenhain bbox (e.g. `50.4700,9.3300,50.5000,9.3700`). Gzip.
    - Both files must be committed (they're small; ~<300 KB each gzipped).
    - Add `overload_429.txt` and `timeout_504.txt` as verbatim Overpass error bodies (get real ones by hammering the endpoint until it 429s, OR fake plausible content — a real Overpass 429 body is usually plaintext with "Too Many Requests" + a hint about slot availability).

    **Tests:**
    - `overpass_query_builder_test.dart`: 3 tests — bbox interpolation order (S,W,N,E), timeout override, single-line vs multi-line format.
    - `overpass_response_parser_test.dart`: parse both fixtures; assert ~>500 ways in Kreuzberg, ~>50 ways in Grebenhain; assert Kfz filter drops known non-Kfz classes (path, cycleway, footway) — spot-check by seeding a synthetic JSON with a `footway` element and asserting it doesn't appear.

    Package imports only.
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/
    ls test/fixtures/overpass/
    ```
    Analyze clean; parser + query builder tests green; two gzipped fixtures + two error-body fixtures on disk.
  </verify>
</task>

<task type="auto">
  <name>Task 2: OverpassClient with endpoint fallback + retry + Riverpod providers</name>
  <files>
    lib/features/matching/data/overpass_client.dart
    lib/features/matching/data/matching_providers.dart
    test/features/matching/overpass_client_test.dart
  </files>
  <intent>Networked, mockable, resilient client.</intent>
  <action>
    **Live-probe fallback endpoint** (do this once at Task-start, then hard-code in the plan):
    ```bash
    curl -sI --max-time 5 https://overpass.kumi.systems/api/status
    curl -sI --max-time 5 https://overpass.private.coffee/api/status
    ```
    If Kumi returns 200/301/302 → use as fallback. Else use private.coffee. Document which is chosen in the plan SUMMARY.

    **`lib/features/matching/data/overpass_client.dart`:**
    ```dart
    class OverpassClient {
      OverpassClient({
        http.Client? client,
        Uri? primaryEndpoint,
        Uri? fallbackEndpoint,
        String userAgent = 'Trailblazer/0.1 (github.com/…)',
        Duration Function(int)? backoffBuilder,
        Duration requestTimeout = const Duration(seconds: 30),
      }) : _client = client ?? http.Client(),
           _primary = primaryEndpoint ?? Uri.parse('https://overpass-api.de/api/interpreter'),
           _fallback = fallbackEndpoint ?? Uri.parse('<from live probe>'),
           _userAgent = userAgent,
           _backoff = backoffBuilder ?? _defaultBackoff,
           _timeout = requestTimeout;

      final http.Client _client;
      final Uri _primary;
      final Uri _fallback;
      final String _userAgent;
      final Duration Function(int) _backoff;
      final Duration _timeout;

      Future<List<WayCandidate>> fetchWaysInBbox({
        required double minLat, required double minLon,
        required double maxLat, required double maxLon,
      }) async {
        final query = const OverpassQueryBuilder().buildBboxHighwayQuery(
          minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
        );

        for (var attempt = 0; attempt < 3; attempt++) {
          final endpoint = attempt < 2 ? _primary : _fallback;
          try {
            final response = await _client.post(
              endpoint,
              headers: {
                'User-Agent': _userAgent,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: 'data=${Uri.encodeQueryComponent(query)}',
            ).timeout(_timeout);

            if (response.statusCode == 200) {
              return const OverpassResponseParser().parseWays(response.body);
            }
            if (response.statusCode == 429 || (response.statusCode >= 500 && response.statusCode < 600)) {
              await Future.delayed(_backoff(attempt));
              continue;
            }
            throw DomainError.network('overpass returned ${response.statusCode}');
          } on TimeoutException catch (e, st) {
            await Future.delayed(_backoff(attempt));
            if (attempt == 2) throw DomainError.wrap(e, st);
          } on Object catch (e, st) {
            if (e is DomainError) rethrow;
            if (attempt == 2) throw DomainError.wrap(e, st);
            await Future.delayed(_backoff(attempt));
          }
        }
        throw DomainError.network('overpass exhausted all attempts');
      }

      static Duration _defaultBackoff(int attempt) =>
          Duration(seconds: [2, 5, 10][attempt]);
    }
    ```
    Adjust `DomainError.network` API to match the actual sealed constructors in `lib/core/errors/`. If the exact factory is different, grep first.

    **`lib/features/matching/data/matching_providers.dart`:**
    ```dart
    final overpassEndpointProvider = Provider<Uri>((_) =>
        Uri.parse('https://overpass-api.de/api/interpreter'));

    final overpassFallbackEndpointProvider = Provider<Uri>((_) =>
        Uri.parse('<from live probe — hard-code the winning URL>'));

    final httpClientProvider = Provider<http.Client>((ref) {
      final client = http.Client();
      ref.onDispose(client.close);
      return client;
    });

    final overpassClientProvider = Provider<OverpassClient>((ref) {
      return OverpassClient(
        client: ref.watch(httpClientProvider),
        primaryEndpoint: ref.watch(overpassEndpointProvider),
        fallbackEndpoint: ref.watch(overpassFallbackEndpointProvider),
      );
    });
    ```
    Plain `Provider<T>` — no codegen (project rule).

    **Tests (`overpass_client_test.dart`) using `package:http/testing.dart` `MockClient`:**
    1. `200 response returns parsed ways` — mock returns Kreuzberg fixture; assert count > 500.
    2. `429 retries with backoff then succeeds` — first call returns 429, second returns 200; use a fast test-backoff via `backoffBuilder: (_) => Duration.zero`.
    3. `5xx on primary + primary retry + fallback succeeds` — three-attempt path; last attempt hits fallback URL; assert `req.url.host` on the third call matches the fallback host.
    4. `all three fail → DomainError thrown` — three 500s; expect `DomainError`.
    5. `timeout retries then throws on third` — three synthetic timeouts.
    6. `User-Agent header always set` — spy on request headers.

    Use `flutter test` (not `dart test` — this is app code).
  </action>
  <verify>
    ```bash
    flutter analyze
    flutter test test/features/matching/overpass_client_test.dart
    ```
    Analyze clean; all 6 client tests green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: Cross-country payload probe — Berlin→Munich autobahn bbox</name>
  <files>
    .planning/phases/04-osm-pipeline/04-13-PAYLOAD-PROBE.md
  </files>
  <intent>Empirically measure Overpass response size + parse time for the worst realistic single-trip bbox to decide whether Wave 3 needs tile-splitting logic.</intent>
  <action>
    **~30 min probe. Fold into this plan (not deferred).**

    1. Compute a realistic Berlin→Munich bbox padded slightly:
       - Berlin: ~52.52°N, 13.40°E
       - Munich: ~48.14°N, 11.58°E
       - Padded bbox: `47.90, 11.30, 52.80, 13.70` (roughly 550 km × 200 km — the widest realistic single trip).

    2. Run the query against the primary endpoint from the shell (safer than from Dart until the client is battle-tested):
       ```bash
       curl -X POST 'https://overpass-api.de/api/interpreter' \
            --data-urlencode 'data=[out:json][timeout:180]; way[highway](47.90,11.30,52.80,13.70); out geom qt;' \
            -H 'User-Agent: Trailblazer/0.1' \
            -o probe_berlin_munich.json
       ls -lh probe_berlin_munich.json
       gzip -c probe_berlin_munich.json | wc -c
       ```
    3. Measure parse time in Dart with a tiny throwaway script:
       ```bash
       flutter test test/features/matching/overpass_response_parser_test.dart \
                    --name="probe parse time" # add a temp test that reads probe_berlin_munich.json + Stopwatch
       ```

    4. Record findings in `.planning/phases/04-osm-pipeline/04-13-PAYLOAD-PROBE.md`:
       - Uncompressed JSON size
       - Gzipped JSON size
       - Way count in response
       - Dart parse time (Stopwatch.elapsedMilliseconds)
       - Peak memory during parse (Dart VM `--observe` or just note "parse fits in a modest heap")
       - **Verdict:** is Wave 3's tile-splitting logic (per RESEARCH §2 slippy z12 tile split) MANDATORY for v1, or can we ship single-query-per-trip? Threshold: if response > 5 MB uncompressed OR parse > 3 s, tile-splitting is mandatory.

    5. Delete the throwaway probe file and any temp test after documenting. Do NOT commit `probe_berlin_munich.json`.

    **Consequence for 04-14:** if the probe says "mandatory tile split", 04-14 must build the slippy-tile bbox math AND the fetch coordinator. If "optional", 04-14 can ship a simpler single-query flow with a `TODO(tile-split)` marker for later. Update 04-14's plan (after this task lands) to reflect the actual decision.
  </action>
  <verify>
    ```bash
    cat .planning/phases/04-osm-pipeline/04-13-PAYLOAD-PROBE.md | head -50
    ```
    Doc exists; contains sizes, parse time, and a MANDATORY/OPTIONAL verdict for tile-splitting.
  </verify>
</task>

## Success Criteria

- `flutter analyze` clean; `flutter test` green.
- `WayCandidate` + `OverpassClient` + `OverpassQueryBuilder` + `OverpassResponseParser` on disk with matching tests.
- Endpoint fallback live-probed; winning URL hard-coded in `matching_providers.dart`.
- User-Agent header set on all requests.
- Retry + backoff verified in tests.
- Payload probe results on disk; tile-splitting decision documented for 04-14.

## Ralph Loop

- Tight loop: `flutter analyze`
- Behavior-sensitive: `flutter test` after every task (Wave 2 is all behavior).
- Pre-push hook covers the rest.

## Deviations

- If Kumi + private.coffee are BOTH down at probe time, use `https://maps.mail.ru/osm/tools/overpass/api/interpreter` (VK Maps mirror, documented). If all three are down, ship with only the primary and add a `TODO(fallback)` — better to ship a single-endpoint client than to delay the phase.
- If the payload probe reveals a response > 100 MB, treat it as a discovery event and stop; escalate to the user for design input before proceeding to 04-14.
- If `DomainError`'s API doesn't have a `.network(msg)` factory, use the closest existing sealed variant (grep `lib/core/errors/` first).

## Commit Strategy

- Task 1 commit: `feat(04-13): WayCandidate model + query builder + response parser + fixtures`
- Task 2 commit: `feat(04-13): OverpassClient with endpoint fallback + retry`
- Task 3 commit: `docs(04-13): Berlin→Munich payload probe results + tile-split decision`
