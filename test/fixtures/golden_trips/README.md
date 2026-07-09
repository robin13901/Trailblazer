# Golden Trip Corpus

Regression fixtures for the HMM matcher. Each subdirectory is one recorded
drive with a known-correct way-ID sequence. `golden_corpus_test.dart`
(`test/features/matching/`) iterates every subdirectory and asserts
`HmmMatcher.match()` reproduces `expected_ways.json` exactly.

## Fixture layout

Each `NNN_<region>_<scenario>/` contains:

    gps_trace.json       -- array of {lat, lon, accuracy, speedKmh, ts}
    ways.json.gz         -- gzipped Overpass response for the trip's bbox
    expected_ways.json   -- array of {wayId, direction} the matcher must produce
    metadata.json        -- optional human notes (scenario, notes, recorded_at)

`metadata.json` is NOT consumed by `golden_corpus_test.dart` — it's for triage.

## Field specifications

### gps_trace.json

Plain JSON array of fix objects:

```json
[
  {"lat": 49.7, "lon": 9.0, "accuracy": 5.0, "speedKmh": 60.0, "ts": "2026-07-08T10:00:00.000Z"}
]
```

| Field      | Type   | Required | Notes                                        |
| ---------- | ------ | -------- | -------------------------------------------- |
| `lat`      | number | yes      | WGS84 latitude                               |
| `lon`      | number | yes      | WGS84 longitude                              |
| `accuracy` | number | no       | Horizontal accuracy in metres; null = NaN    |
| `speedKmh` | number | no       | Speed in km/h; defaults to 0.0               |
| `ts`       | string | yes      | ISO-8601 timestamp (UTC `Z` suffix)          |

### ways.json.gz

Gzipped Overpass `out geom;`-shaped JSON envelope
(`{"version":0.6,"elements":[{"type":"way","id":..,"geometry":[..],"tags":{..}}]}`).

`GoldenFixtureExporter` writes the RAW ways for the trip's **bbox** — obtained
via `WayCandidateSource.fetchWaysInBbox` — NOT the corridor-filtered subset the
`TripMatchCoordinator` feeds the matcher. Capturing the full bbox input is what
makes the fixture a faithful regression: `golden_corpus_test.dart` re-derives
the corridor filter itself. The exporter re-emits the envelope from parsed
`WayCandidate`s (the per-tile cache bytes can't be concatenated into one valid
envelope), and its round-trip unit test proves the re-emitted shape parses
cleanly through `FixtureWayCandidateSource.fromGzippedOverpassJson`.

### expected_ways.json

```json
[
  {"wayId": 123456, "direction": "forward"},
  {"wayId": 789012, "direction": "forward"}
]
```

`direction` is `"forward"` (along stored node order) or `"backward"`. Each
entry corresponds to one interval output from `HmmMatcher.match()`; the test
asserts the produced `result.intervals` wayId sequence equals this list.

### metadata.json

```json
{"scenario": "kleinheubach_roundabout", "notes": "...", "recorded_at": "2026-07-09"}
```

## Recording a new fixture (workflow)

1. Run the app in `--debug` or `--profile` (see
   `.claude/memory/fgb-license-and-release-builds.md` — release builds have
   degraded tracking and the export FAB is tree-shaken out).
2. Drive the scenario.
3. Open the Trips tab → History → tap the trip → **TripDetailScreen**.
4. Tap the **Export fixture** FAB (visible only in `kDebugMode`).
5. Enter a slug of the form `NNN_<region>_<scenario>` — e.g.
   `002_kleinheubach_roundabout`, `003_gymtrip_a3_northbound`. The exporter
   rejects anything that doesn't match `^\d{3}_[a-z0-9_]+$`.
6. Files land at `<AppDocs>/golden_export/<slug>/` on the device. The SnackBar
   shows the absolute path.
7. Pull the directory to `test/fixtures/golden_trips/` on your dev machine:
   - **Android:** `adb pull /data/data/de.autoexplore.auto_explore/app_flutter/golden_export/`
     (or `/data/user/0/…` — same path). Use `adb exec-out run-as` for a
     non-rooted device if the direct pull is denied.
   - **iOS Simulator:** `~/Library/Developer/CoreSimulator/Devices/<id>/data/Containers/Data/Application/<id>/Documents/golden_export/`
8. Verify: `flutter test test/features/matching/golden_corpus_test.dart` — the
   new fixture must pass WITHOUT matcher changes. If it fails, either the
   matcher regressed OR the recorded intervals are bogus — inspect before
   committing (the fixture is the oracle; don't hand-edit `expected_ways.json`
   to make a red test green).
9. Commit the four files under `test/fixtures/golden_trips/NNN_<slug>/`.

## Slug conventions

- Zero-padded 3-digit index (`001`, `002`, …).
- Region: `kleinheubach`, `miltenberg`, `gymtrip`, `aschaffenburg`, …
- Scenario: `roundabout`, `straight`, `intersection`, `bridge`, `tunnel`,
  `motorway`, `field_road`, `citygrid`, `uturn`, …

## Coverage goal (Phase 6)

Target **≥ 20 fixtures** by phase close-out (inherited from Phase 5 MMT-09).
Minimum acceptable at the first drive batch: **3–5 seed fixtures** across
distinct road types (motorway, town roundabout, rural cross-junction).

Fixture accumulation is a **best-effort dogfooding goal** requiring real
drives — the export *tooling* is the hard deliverable of Plan 06-06; the
fixtures themselves land organically during the Phase 6 close-out drive batch
(see `.planning/phases/06-inbox-match-wire-up/06-06-SUMMARY.md`).

### Suggested seed scenarios

| # | Slug template          | Scenario                         |
|---|------------------------|----------------------------------|
| 1–3 | `NNN_autobahn_*`     | Autobahn forward                 |
| 4–5 | `NNN_bundesstrasse_*`| Bundesstraße mixed class         |
| 6–7 | `NNN_kreisel_*`      | Kreisverkehr entry/exit + loop   |
| 8–9 | `NNN_tunnel_*`       | Tunnel GPS blackout              |
| 10+ | `NNN_citygrid_*`     | Dense city grid, U-turns, one-way|

## Known limitations

- Fixtures embed the Overpass extract snapshot at record time. If OSM data
  changes upstream, `expected_ways` may drift; refresh the fixture (delete +
  re-record) rather than editing it by hand.
- `ways.json.gz` is stored gzipped — hex-diffing before commit is unhelpful.
- The synthetic seed `001_synthetic_straight_east/` was hand-authored (not
  exported from a drive); it verifies the harness works with a trivial trace.
