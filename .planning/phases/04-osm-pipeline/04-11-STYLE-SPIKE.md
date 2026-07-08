# 04-11 — MapTiler Style-ID Spike

**Date:** 2026-07-08
**Account:** MapTiler Cloud free tier (dev key held out-of-band in `env/dev.json`, gitignored).
**Method:** `curl -sI "https://api.maptiler.com/maps/{styleId}/style.json?key=<KEY>"` per candidate style ID; recorded HTTP status + `Content-Type`.

## Results

All nine candidate style IDs returned HTTP 200 with `Content-Type: application/json` — none are gated behind a paid tier for the standard `style.json` endpoint on this free-tier account.

| Style ID           | HTTP Status | Content-Type       | Notes                                    |
| ------------------ | ----------- | ------------------ | ---------------------------------------- |
| `streets-v2`       | 200         | `application/json` | Google-Maps-style baseline (light).      |
| `streets-v4`       | 200         | `application/json` | Newer streets iteration.                 |
| `basic-v2`         | 200         | `application/json` | Minimal, roadmap-like.                   |
| `bright-v2`        | 200         | `application/json` | High-saturation everyday map.            |
| `dataviz`          | 200         | `application/json` | Muted grayscale; RESEARCH-recommended.   |
| `dataviz-dark`     | 200         | `application/json` | Dark counterpart to `dataviz`.           |
| `outdoor-v2`       | 200         | `application/json` | Terrain-oriented, hillshade prominent.   |
| `hybrid`           | 200         | `application/json` | Satellite + labels (heavier).            |
| `streets-v2-dark`  | 200         | `application/json` | Fallback dark pair for `streets-v2`.     |

## Chosen defaults

- **Light:** `dataviz`
- **Dark:** `dataviz-dark`

**Justification:** The RESEARCH.md tile-provider table calls out `dataviz` / `dataviz-dark` as the muted, low-saturation pair that lets the driven-road painting stand out visually (the app's core value: driven roads pop against a quiet base map). Both are on the free tier for this account, so no fallback to `streets-v2` / `streets-v2-dark` is needed. The fallback pair is retained in the `MapTilerStyle` enum (Task 2) for future flexibility and to guard against style-ID drift or gating on other accounts.

## Surprises

None. Every candidate ID from the RESEARCH shortlist resolved; no renamed IDs, no paywall gates, no `Content-Type` drift.

## Downstream contract

- Task 2's `MapTilerStyle` enum encodes the four IDs `dataviz`, `dataviz-dark`, `streets-v2`, `streets-v2-dark` verbatim.
- Task 3 wires `TileProviderConfig(lightStyle: dataviz, darkStyle: datavizDark, apiKey: kMaptilerKey)` in `main.dart`.
- Any change to these defaults requires a fresh spike against the same account — MapTiler's free-tier catalog is not guaranteed stable across accounts or over time.
