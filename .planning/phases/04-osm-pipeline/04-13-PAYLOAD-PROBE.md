# 04-13 Payload Probe — Overpass response sizing for realistic single-trip bboxes

**Date:** 2026-07-08
**Probe by:** Plan 04-13 Task 3
**Purpose:** Empirically measure Overpass response size + Dart parse time for the worst realistic single-trip bbox, to decide whether Wave 3's tile-splitting logic is MANDATORY for v1 or a nice-to-have.

## Summary

| Metric | Value |
| ---- | ---- |
| Bbox actually probed | Nuremberg 100×100 km slice — `49.00,10.50,49.90,11.60` |
| Uncompressed JSON size | 309,082,583 B = **294.76 MiB** |
| Gzipped size | 47,421,181 B = **45.22 MiB** |
| Way elements in response (raw, pre-filter) | 422,318 |
| Kfz-allowlist ways after parser filter | 107,879 |
| Dart read (file I/O) | 901 ms |
| Dart parse (`OverpassResponseParser.parseWays`) | 3,696 ms |
| **Verdict** | **MANDATORY tile-splitting** for v1 |

## Bbox selection (three attempts)

The plan called for the widest realistic single-trip bbox — Berlin→Munich padded to `47.90, 11.30, 52.80, 13.70` (~550 km × 200 km). Overpass rejected this at the server side; two smaller alternatives were tried before landing on a 100×100 km slice that returned successfully.

### Attempt 1 — Full Berlin→Munich (`47.90, 11.30, 52.80, 13.70`, ~550 km × 200 km)

```bash
curl -X POST 'https://overpass-api.de/api/interpreter' \
     --data-urlencode 'data=[out:json][timeout:300]; way[highway](47.90,11.30,52.80,13.70); out geom qt;' \
     -H 'User-Agent: Trailblazer/0.1'
```

**Result:** HTTP 504 in 8.57 s with error body:

```
Error: runtime error: open64: 0 Success /osm3s_osm_base
Dispatcher_Client::request_read_and_idx::timeout.
The server is probably too busy to handle your request.
```

Public Overpass instance rejected the query — the bbox exceeds what the shared free-tier server will process even at `[timeout:300]`. Confirms the plan's expectation that the widest single-trip queries are not viable against `overpass-api.de` without splitting.

### Attempt 2 — A9 corridor slice (`48.30, 11.20, 50.80, 12.10`, ~280 km × 60 km)

Same query shape, narrower bbox. **Result:** HTTP 504 in 9.16 s, same "server too busy" error. Even a 280 km × 60 km stripe overwhelms the shared instance for the full Kfz+Feldweg query.

### Attempt 3 — Nuremberg 100×100 km (`49.00, 10.50, 49.90, 11.60`)

Third attempt with a square-ish 100×100 km bbox around Nuremberg (chosen because it spans mixed urban/rural/autobahn/rail terrain with the A6/A9/A73 intersecting — representative of a "single realistic trip"):

```bash
curl -X POST 'https://overpass-api.de/api/interpreter' \
     --data-urlencode 'data=[out:json][timeout:180]; way[highway](49.00,10.50,49.90,11.60); out geom qt;' \
     -H 'User-Agent: Trailblazer/0.1' \
     -o probe_nuremberg_100km.json
```

**Result:** HTTP 200 in **67.37 s**, 309,082,583 bytes (294.76 MiB) uncompressed.

### Sanity slice — motorway-only A9 corridor (`48.30, 11.20, 50.80, 12.10`)

Ran a `way[highway=motorway]` variant of Attempt 2's bbox to sanity-check that the 504 was volume-driven and not a bbox-shape problem. **Result:** HTTP 200 in 6.40 s, 3,003,348 bytes, 3,240 motorway ways. Confirms the shared Overpass instance can handle the same bbox when filtered to a small set — the failure of Attempt 2 was purely payload-size.

## Dart parse measurement

Measured against the 294.76 MiB Nuremberg payload via `flutter test` with a throwaway probe test (`test/features/matching/_probe_parse_test.dart`, deleted after this doc was written) invoking `OverpassResponseParser.parseWays`:

```
=== PROBE ===
Size: 309082583 bytes (294.76 MiB)
Read: 901 ms
Parse: 3696 ms
Kfz-allowlist ways: 107879
=== END PROBE ===
```

- **Read (file I/O):** 901 ms — dwarfed by parse; over the network the equivalent HTTP body-download would be strongly link-limited (see "network transfer time" below).
- **Parse:** 3,696 ms — `jsonDecode` + `parseWays` on a Windows dev box (SSD, recent-gen Ryzen). On a mid-tier mobile device this will be 3-6× slower — call it 12-25 s worst case.
- **Result count:** 107,879 Kfz ways from 422,318 raw way elements — the parser dropped **~74% of the response** to the Feldweg / footway / path / cycleway / service / track categories. This is a huge amount of wasted bandwidth per real trip.

## Threshold check (from plan §Task 3 acceptance)

The plan's threshold: **"if response > 5 MB uncompressed OR parse > 3 s, tile-splitting is mandatory."**

| Threshold | Measured | Verdict |
| ---- | ---- | ---- |
| Response size ≤ 5 MB uncompressed | 294.76 MiB | **FAIL** (by ~60×) |
| Parse time ≤ 3 s | 3.7 s (dev box); est. 12-25 s (mobile) | **FAIL** |

**Both thresholds fail by wide margins.** Tile-splitting is mandatory-for-v1.

## Network transfer time (informational)

Response gzipped: 45.22 MiB.

At representative mobile bandwidths:

| Link | Time to download 45 MiB |
| ---- | ---- |
| 4G LTE (10 Mbit/s realistic) | ~36 s |
| 5G (100 Mbit/s realistic) | ~4 s |
| Fixed cellular / dev-machine wifi | 1-2 s |
| Overpass server compute time | 67 s (measured) |

So on 4G, a naive "one query per trip" flow would leave the user waiting ~100 s just for the tile fetch before the matcher can start. This is user-hostile independent of parse time.

## Downstream implications for 04-14

**MANDATORY tile-splitting for v1.**

04-14 (Drift migration v3 + DAOs) must ship with the assumption that Wave 3 will build:

1. Slippy-tile bbox math (z12 as the plan's baseline) — split any incoming trip bbox into a set of z12 tiles.
2. A fetch coordinator that issues one Overpass query per tile.
3. Persistent cache: fetched tiles are stored in the `way_candidates` / `overpass_tile_cache` schema so re-driving the same road doesn't re-hit Overpass.
4. Concurrency + rate-limit awareness — the coordinator must serialize (or cap parallelism) against the shared free-tier throttle.

At z12, one tile is roughly 9.8 km × 6.5 km at latitude ~49° — so a 100 km × 100 km bbox produces ~156 tiles, and a full Berlin→Munich autobahn corridor ~250-300 tiles. The unit-scale response size is therefore ~2-3 MiB per tile (extrapolating from the measured density), which lands inside the plan's 5 MB threshold.

## Sample-body characteristics

From the successful Nuremberg 100 km probe (`elements[0]`):

```json
{
  "version": 0.6,
  "generator": "Overpass API 0.7.62.11 87bfad18",
  "osm3s": {
    "timestamp_osm_base": "2026-07-08T11:34:30Z",
    "copyright": "The data included in this document is from www.openstreetmap.org. The data is made available under ODbL."
  },
  "elements": [
    {
      "type": "way",
      "id": 4525864,
      "bounds": { "minlat": ..., "minlon": ..., "maxlat": ..., "maxlon": ... },
      "nodes": [27786102, 281511092, ...],
      "geometry": [
        { "lat": ..., "lon": ... },
        ...
      ],
      "tags": { "highway": "residential", "name": "...", "maxspeed": "30", ... }
    },
    ...
  ]
}
```

Response shape matches the plan's expectation (§Task 1 action). `bounds` + `nodes` are extra data our parser doesn't use — the payload is roughly 30-40% larger than strictly necessary because Overpass emits both `nodes` (node ID array) and `geometry` (lat/lon inlined) when `out geom` is requested. A future optimization (out of 04-13 scope) could switch to `out ids qt;` + a separate `node(w);out geom qt;` pair to skip the redundant `nodes` array, saving bandwidth.

## Deleted artifacts

Per plan §Task 3 action, these were deleted after measurement:

- `C:/tmp/probe_berlin_munich.json` (695 B, 504 error body)
- `C:/tmp/probe_a9_slice.json` (695 B, 504 error body)
- `C:/tmp/probe_a9_motorway.json` (~3 MB, informational)
- `C:/tmp/probe_nuremberg_100km.json` (~295 MB — successful sample)
- `test/features/matching/_probe_parse_test.dart` (throwaway parse-timing test)
- `tool/probe_parse.dart` (throwaway CLI — failed to compile against Flutter deps; replaced by the `flutter test` variant above)

None of these should appear in `git status` — verified before the Task 3 commit.

## Verdict (recorded for 04-14 SUMMARY consumption)

**Tile-splitting: MANDATORY for v1.** 04-14 must plumb the tile-cache schema; 04-15's `WayCandidateSource` must partition every request by z12 tile before hitting `OverpassClient.fetchWaysInBbox`. Single-query-per-trip is not viable — both the shared Overpass instance and the mobile client parse budget rule it out.
