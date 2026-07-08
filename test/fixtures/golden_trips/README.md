# Golden Trip Corpus (Phase 5 MMT-09)

Each subdirectory here is one recorded trip with a known-correct way-ID
sequence. The `golden_corpus_test.dart` runner iterates over every
subdirectory and asserts `HmmMatcher.match()` produces the expected
sequence.

## Layout

    {NNN}_{scenario_slug}/
      gps_trace.json       -- input GPS trace, plain JSON array
      ways.json.gz         -- gzipped Overpass response JSON
      expected_ways.json   -- expected interval way-ID sequence
      metadata.json        -- scenario, notes, recorded_at

## Field specifications

### gps_trace.json

Plain JSON array of fix objects:

```json
[
  {
    "lat": 49.7,
    "lon": 9.0,
    "accuracy": 5.0,
    "speedKmh": 60.0,
    "ts": "2026-07-08T10:00:00.000Z"
  }
]
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `lat` | number | yes | WGS84 latitude |
| `lon` | number | yes | WGS84 longitude |
| `accuracy` | number | no | Horizontal accuracy in metres; omit or null = NaN |
| `speedKmh` | number | no | Speed in km/h; defaults to 0.0 |
| `ts` | string | yes | ISO-8601 timestamp (UTC Z suffix) |

### ways.json.gz

Gzipped Overpass JSON response (same format as `out geom;` endpoint).
Produced by `tool/osm_pipeline/bin/save_trip_fixture.dart` for real drives
or hand-authored for synthetic fixtures.

### expected_ways.json

```json
[
  {"wayId": 123456, "direction": "forward"},
  {"wayId": 789012, "direction": "forward"}
]
```

`direction` is `"forward"` (along stored node order) or `"backward"`.
Each entry corresponds to one `DrivenWayIntervalDraft` output from
`HmmMatcher.match()`. The test asserts that the produced `result.intervals`
wayId sequence matches this list exactly.

### metadata.json

```json
{
  "scenario": "synthetic_straight_east",
  "notes": "Human-readable description of the scenario.",
  "recorded_at": "2026-07-08"
}
```

## Adding a new fixture

1. Drive the scenario, recording via the app.
2. Export the trip's `trip_points` as `gps_trace.json` (via debug HUD or
   Drift dump).
3. Run `dart run osm_pipeline:save_trip_fixture --trace path/to/gps_trace.json`
   (requires internet — hits Overpass). Writes `ways.json.gz`.
4. Run the matcher manually against the fixture, inspect the intervals,
   write `expected_ways.json` after visual verification.
5. Commit all four files.

## Required scenarios (MMT-09 — ≥ 20 total)

| # | Slug template | Scenario |
|---|---------------|----------|
| 1–3 | `NNN_autobahn_*` | Autobahn forward |
| 4–5 | `NNN_bundesstrasse_*` | Bundesstraße mixed class |
| 6–7 | `NNN_kreisel_*_entry` | Kreisverkehr entry/exit |
| 8–9 | `NNN_kreisel_*_loop` | Full-loop roundabout |
| 10–11 | `NNN_tunnel_*` | Tunnel GPS blackout |
| 12–13 | `NNN_parking_*` | Parking lot approach |
| 14–15 | `NNN_uturn_*` | U-turn on narrow street |
| 16–17 | `NNN_citygrid_*` | Dense city grid |
| 18–19 | `NNN_roundabout_*` | Roundabout with straight exit |
| 20 | `NNN_einbahn_*` | One-way pair |
