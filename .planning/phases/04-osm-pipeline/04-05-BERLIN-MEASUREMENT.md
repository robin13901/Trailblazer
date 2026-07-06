# Phase 4 · Plan 05 · Berlin-bbox Row-Count Measurement

**Ran:** 2026-07-06T05:48:43.487459Z
**Berlin PBF:** berlin-260705.osm.pbf
**SHA-256:** `c96a067a18ebf7ec2d5f513cf43624000ddb3860fe9928bc68d5f22e9e82f775`
**Naïve extrapolation ratio (area):** ~401 (357582 km² / 891.7 km²)
**Realistic extrapolation ratio (Kfz-way count):** ~43.6 (Germany ≈ 4000000 Kfz ways per 04-RESEARCH §7 / Berlin measured 91707)

## Berlin actuals

| Metric | Value |
|---|---|
| Kfz ways | 91707 |
| Feldweg ways | 84860 |
| Referenced nodes | 538009 |
| Admin regions (level 2) | 0 |
| Admin regions (level 4) | 2 |
| Admin regions (level 6) | 2 |
| Admin regions (level 8) | 3 |
| Admin regions (level 9) | 14 |
| Admin regions (level 10) | 97 |
| Bbox-overlap ratio (upper bound on cross-border) | 99.98 % |

## Byte-level measurements (Berlin scratch DB)

| Table / total | Bytes | MB |
|---|---:|---:|
| scratch.sqlite total | 32309248 | 30.8 |
| ways_raw (Kfz payload) | 7676300 | 7.3 |
| admin_regions_raw payload | 860697 | 0.8 |
| nodes_raw payload | 12912216 | 12.3 |

## Germany projections — SLIM model (per-table, realistic)

Slim model: measured Berlin per-Kfz-way byte cost × ~44 (realistic Germany Kfz-way count / Berlin measured), plus Germany-scale admin regions and a capped cross-border split table. This is the actionable projection.

| Strategy | Projected osm.sqlite size |
|---|---|
| denormalized-on-ways (L2..L10) + way_admin_raw for splits | 775.1 MB |
| denormalized-on-ways (L2..L8 only) + way_admin_raw for splits | 695.7 MB |
| join-table-only (no denormalization) | 1697.5 MB |

## Germany projections — NAÏVE model (area ratio ×401, pessimistic)

Naïve model: multiplies Berlin row counts by the Germany/Berlin land-area ratio (~401). Contradicts 04-RESEARCH §7 (Germany ≈ 4 M Kfz ways, not 37 M). Kept for context; do NOT use as the actionable number — Berlin urban Kfz-way density is ~9× the national average.

| Strategy | Projected osm.sqlite size |
|---|---|
| denormalized-on-ways (L2..L10) + way_admin_raw for splits | 13130.6 MB |
| denormalized-on-ways (L2..L8 only) + way_admin_raw for splits | 12401.1 MB |
| join-table-only (no denormalization) | 20061.1 MB |

## Reality check — direct scratch-DB projections

Two additional projections the user asked for during the schema-unlock consultation, as an anchor for the SC4 discussion:

| Approach | Projected Germany osm.sqlite |
|---|---|
| Naïve: scratch × 401 (Berlin area ratio) | 12356.2 MB |
| Slim: (ways_raw + admin_regions_raw) × 401 (Berlin area ratio) | 3264.8 MB |
| Slim: (ways_raw × Kfz-count-ratio) + admin | 389.1 MB |

The Kfz-count-ratio projection (~44 x, anchored on 04-RESEARCH §7's ~4 M Germany Kfz ways figure vs Berlin's measured 91 707) is the realistic one — Berlin urban Kfz density is ~9x the German average, so the area ratio overshoots by roughly the same factor.

## SC4 impact — 200 MB target vs slim projections

ROADMAP SC4 hard target: **osm.sqlite < 200 MB** for full Germany. Industry references for Germany-scale routable mapping:

| Product | Approx Germany bundle size |
|---|---|
| Osmand (full offline) | ~4 GB |
| Osmand (slim / roads-only) | ~800 MB |
| Organic Maps | ~1.5 GB |
| Here Maps offline | ~1–2 GB |
| Google Maps offline (Germany) | ~2–4 GB |

200 MB is uniquely aggressive; slim projections above should be compared against relaxed targets when nothing fits 200 MB:

| SC4 target | Which strategies fit? |
|---|---|
| 200 MB | none |
| 300 MB | none |
| 500 MB | none |

**Recommended SC4 target (based on slim projection):** **500 MB**

> Slim projection shows no strategy fits the original 200 MB target. Recommending SC4 relaxation to 500 MB — still ~63% of Osmand slim and ~33% of Organic Maps, so we remain competitively slim.

## Recommendation

04-06 SHOULD use: **denormalized-on-ways (L2..L8 only) + way_admin_raw for splits** (slim projection ≈ 695.7 MB vs SC4 target 500 MB — OVERSHOOTS; see SC4 impact section for renegotiation)

