#!/usr/bin/env python3
"""Trailblazer region-data builder (Phase 10 — replaces the dead Dart pipeline).

ONE-SHOT dev-machine tool. Reads a Geofabrik `.osm.pbf` extract and emits the
TWO assets the live app consumes, keyed by the SAME OSM relation id:

  1. assets/admin/germany_admin.geojson.gz
     FeatureCollection of admin-region MultiPolygons at levels 4/6/8/9/10.
     Properties: {osm_id:int, admin_level:int, name:str, "name:de":str?}.
     Geometry: GeoJSON [lon, lat] order (what AdminRegionLookup._parseAdminBundle
     reads: p[0]=lon, p[1]=lat). INCLUDES admin_level=9 (the old bundle had none).

  2. assets/admin/region_totals.json.gz
     { "<osm_id>": <total_drivable_road_meters>, ... } — one entry per region in
     the admin bundle (key-set equality is guaranteed by construction: totals is
     seeded from the region list, so every bundled region has a totals entry and
     vice-versa).

Why this exists: the app's map (MapTiler) and matcher road data (Overpass) are
network-live since Phase 4. The old `tool/osm_pipeline/` Dart pipeline built an
8 GB osm.sqlite + tile file that NOTHING in the app uses anymore, and its
matcher-grade cross-border join (Stage D) ran ~16 h at ~60 ways/s. A totals
DENOMINATOR does not need matcher-grade fractional precision — it needs the
km of drivable road inside each region. This tool does exactly that, using
pyosmium (streaming PBF) + shapely/GEOS (fast clip) + pyproj (geodesic length),
finishing in a fraction of the time. Run once, then the whole thing can be
deleted.

Drivable = the SAME 14-tag Kfz allowlist the runtime matcher uses
(lib/features/matching/domain/way_candidate.dart `kfzHighwayClasses`). Kept in
sync by the assert in `_KFZ_HIGHWAY` below — if you change the app's set, change
this and vice-versa.

Border handling (user decision 2026-07-17: "clip ways to polygons — exact"):
each Kfz way is clipped to every admin polygon it intersects; only the portion
inside a region counts toward that region's total. A road straddling Geislitz
and its neighbour contributes exactly its metres-in-Geislitz to Geislitz.

Requirements (dev machine): python -m pip install osmium shapely pyproj

Usage:
  python tool/region_stats/build_region_data.py \
    --pbf C:/Users/.../germany-latest.osm.pbf \
    --out-admin assets/admin/germany_admin.geojson.gz \
    --out-totals assets/admin/region_totals.json.gz
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
import time
from dataclasses import dataclass, field

import osmium
import pyproj
from shapely import STRtree
from shapely import wkb as shapely_wkb
from shapely.geometry import mapping
from shapely.geometry.base import BaseGeometry
from shapely.prepared import prep

# --- Kfz allowlist — MUST match lib/features/matching/domain/way_candidate.dart
#     `kfzHighwayClasses` (14 tags). Parity is the whole point of the totals. ---
_KFZ_HIGHWAY: frozenset[str] = frozenset({
    'motorway', 'motorway_link',
    'trunk', 'trunk_link',
    'primary', 'primary_link',
    'secondary', 'secondary_link',
    'tertiary', 'tertiary_link',
    'unclassified',
    'residential',
    'living_street',
    'road',
})
assert len(_KFZ_HIGHWAY) == 14, 'Kfz allowlist must be exactly 14 tags (matcher parity)'

# Admin levels to bundle + total. L2 (country) is excluded from BOTH outputs:
# its total would be a meaningless ~645,000 km and the runtime never displays it.
_ADMIN_LEVELS: frozenset[int] = frozenset({4, 6, 8, 9, 10})

# Douglas-Peucker output simplification tolerance per level, in METERS. Only the
# emitted admin bundle is simplified; clipping uses FULL-resolution geometry.
# Mirrors the old AdminPolygonSimplifier tolerances. Tighten via --simplify-scale
# if the gzipped bundle exceeds the 15 MB budget.
_TOLERANCE_M: dict[int, float] = {4: 30.0, 6: 50.0, 8: 100.0, 9: 100.0, 10: 100.0}

_ADMIN_BUNDLE_BUDGET_BYTES = 15 * 1024 * 1024  # hard ceiling, matches old pipeline
_DEG_PER_METER = 1.0 / 111_320.0  # ~m->deg at mid-latitudes, for simplify tolerance

_geod = pyproj.Geod(ellps='WGS84')


@dataclass
class Region:
    osm_id: int
    admin_level: int
    name: str
    name_de: str | None
    geom: BaseGeometry  # full-resolution shapely (multi)polygon, [lon,lat]


@dataclass
class _AreaCollector(osmium.SimpleHandler):
    """Collects admin-boundary areas into shapely geometries."""

    regions: dict[int, Region] = field(default_factory=dict)
    _wkbfab: osmium.geom.WKBFactory = field(default_factory=osmium.geom.WKBFactory)
    seen: int = 0
    errors: int = 0

    def area(self, a: osmium.osm.Area) -> None:  # noqa: N802 (osmium API)
        tags = a.tags
        if tags.get('boundary') != 'administrative':
            return
        lvl_raw = tags.get('admin_level')
        if lvl_raw is None:
            return
        try:
            level = int(lvl_raw)
        except ValueError:
            return
        if level not in _ADMIN_LEVELS:
            return
        name = tags.get('name')
        if not name:
            return
        osm_id = a.orig_id()  # relation id for relation-built areas
        self.seen += 1
        try:
            geom = shapely_wkb.loads(self._wkbfab.create_multipolygon(a), hex=True)
        except Exception:  # noqa: BLE001 — a malformed ring shouldn't kill the run
            self.errors += 1
            return
        if geom.is_empty:
            return
        existing = self.regions.get(osm_id)
        if existing is None:
            self.regions[osm_id] = Region(osm_id, level, name, tags.get('name:de'), geom)
        else:
            # Same relation emitted twice — union the parts (rare).
            existing.geom = existing.geom.union(geom)


def _line_length_m(geom: BaseGeometry) -> float:
    """Geodesic length in meters of the line parts of an intersection result."""
    gt = geom.geom_type
    if gt == 'LineString':
        return _geod.geometry_length(geom)
    if gt in ('MultiLineString', 'GeometryCollection'):
        total = 0.0
        for g in geom.geoms:
            if g.geom_type in ('LineString', 'MultiLineString'):
                total += _geod.geometry_length(g)
        return total
    return 0.0  # points / empty -> no length


def collect_regions(pbf: str) -> dict[int, Region]:
    print(f'[1/3] Reading admin areas from {pbf} ...', flush=True)
    t0 = time.time()
    handler = _AreaCollector()
    # SimpleHandler.apply_file with locations+areas: pyosmium assembles
    # multipolygon relations into Area objects for us.
    handler.apply_file(pbf, locations=True)
    dt = time.time() - t0
    levels: dict[int, int] = {}
    for r in handler.regions.values():
        levels[r.admin_level] = levels.get(r.admin_level, 0) + 1
    print(f'      {len(handler.regions)} regions '
          f'(levels {dict(sorted(levels.items()))}), '
          f'{handler.errors} geom errors, {dt:.0f}s', flush=True)
    return handler.regions


def compute_totals(pbf: str, regions: dict[int, Region]) -> dict[int, float]:
    print('[2/3] Clipping Kfz ways to regions (exact) ...', flush=True)
    t0 = time.time()

    ordered = list(regions.values())
    geoms = [r.geom for r in ordered]
    tree = STRtree(geoms)  # GEOS-backed bbox index over ~all regions
    # Prepared geometries: build the region's edge index ONCE, then run
    # covers()/intersects() predicates cheaply per way. This is the key speedup —
    # a full line.intersection(polygon) clip is expensive and only NEEDED when a
    # way actually crosses the boundary. Most ways sit wholly inside their
    # nested regions (L4..L10), where covers() lets us add the way's full length
    # with no clip at all.
    prepared = [prep(g) for g in geoms]

    # Seed EVERY region at 0.0 so the totals key-set == the admin key-set (SC5).
    totals: dict[int, float] = {r.osm_id: 0.0 for r in ordered}

    wkbfab = osmium.geom.WKBFactory()
    kfz = 0
    clips = 0  # count of expensive boundary-crossing clips actually performed
    fp = osmium.FileProcessor(pbf).with_locations()
    for obj in fp:
        if not isinstance(obj, osmium.osm.Way):
            continue
        hw = obj.tags.get('highway')
        if hw not in _KFZ_HIGHWAY:
            continue
        kfz += 1
        try:
            line = shapely_wkb.loads(wkbfab.create_linestring(obj), hex=True)
        except Exception:  # noqa: BLE001 — skip degenerate/1-node ways
            continue
        # Full geodesic length computed ONCE; reused for every region that
        # wholly contains the way (the common case).
        full_len = _geod.geometry_length(line)
        if full_len <= 0.0:
            continue
        # Candidate regions whose bbox overlaps this way's bbox.
        for idx in tree.query(line):
            pg = prepared[idx]
            if pg.covers(line):
                # Way lies entirely inside this region → full length, no clip.
                totals[ordered[idx].osm_id] += full_len
            elif pg.intersects(line):
                # Boundary-crossing → do the (expensive) exact clip.
                clipped = line.intersection(geoms[idx])
                if not clipped.is_empty:
                    length = _line_length_m(clipped)
                    if length > 0.0:
                        totals[ordered[idx].osm_id] += length
                clips += 1
            # else: bbox overlapped but geometry doesn't touch → skip.
        if kfz % 250_000 == 0:
            dt = time.time() - t0
            rate = kfz / dt if dt else 0
            print(f'      {kfz:,} Kfz ways — {rate:,.0f}/s — {clips:,} border '
                  f'clips — {dt:.0f}s', flush=True)

    dt = time.time() - t0
    grand_km = sum(totals.values()) / 1000.0
    print(f'      {kfz:,} Kfz ways in {dt:.0f}s ({clips:,} border clips); '
          f'sum of per-region totals = {grand_km:,.0f} km '
          f'(counts border-shared roads once per region they touch)', flush=True)
    return totals


def _simplify_for_output(geom: BaseGeometry, level: int, scale: float) -> BaseGeometry:
    tol_deg = _TOLERANCE_M[level] * scale * _DEG_PER_METER
    if tol_deg <= 0:
        return geom
    simplified = geom.simplify(tol_deg, preserve_topology=True)
    return simplified if not simplified.is_empty else geom


def _to_multipolygon_coords(geom: BaseGeometry) -> list | None:
    """GeoJSON MultiPolygon coordinates ([lon,lat]) or None if not areal."""
    m = mapping(geom)
    if m['type'] == 'MultiPolygon':
        return [ [ [list(pt) for pt in ring] for ring in poly ]
                 for poly in m['coordinates'] ]
    if m['type'] == 'Polygon':
        return [ [ [list(pt) for pt in ring] for ring in m['coordinates'] ] ]
    return None


def write_admin_bundle(path: str, regions: dict[int, Region], scale: float) -> int:
    print(f'[3/3] Writing admin bundle -> {path} ...', flush=True)
    features = []
    l9 = 0
    for r in regions.values():
        coords = _to_multipolygon_coords(_simplify_for_output(r.geom, r.admin_level, scale))
        if coords is None:
            continue
        props = {'osm_id': r.osm_id, 'admin_level': r.admin_level, 'name': r.name}
        if r.name_de:
            props['name:de'] = r.name_de
        features.append({
            'type': 'Feature',
            'properties': props,
            'geometry': {'type': 'MultiPolygon', 'coordinates': coords},
        })
        if r.admin_level == 9:
            l9 += 1
    fc = {'type': 'FeatureCollection', 'features': features}
    raw = json.dumps(fc, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    gz = gzip.compress(raw, compresslevel=9)
    with open(path, 'wb') as f:
        f.write(gz)
    print(f'      {len(features)} features ({l9} at L9), '
          f'{len(gz) / 1024 / 1024:.2f} MB gzipped', flush=True)
    return len(gz)


def write_totals(path: str, totals: dict[int, float]) -> None:
    # Round to 1 decimal meter — sub-meter precision is noise for a denominator.
    out = {str(k): round(v, 1) for k, v in totals.items()}
    raw = json.dumps(out, separators=(',', ':')).encode('utf-8')
    gz = gzip.compress(raw, compresslevel=9)
    with open(path, 'wb') as f:
        f.write(gz)
    print(f'      totals -> {path} ({len(out)} regions, '
          f'{len(gz) / 1024:.0f} KB gzipped)', flush=True)


def _sanity(regions: dict[int, Region], totals: dict[int, float]) -> None:
    print('--- sanity checks ---', flush=True)
    for osm_id, label in ((62404, 'Landkreis Miltenberg (L6)'),
                          (393501, 'Kleinheubach (L8)')):
        if osm_id in totals:
            km = totals[osm_id] / 1000.0
            print(f'  {label}: osm_id={osm_id}  {km:,.1f} km', flush=True)
        else:
            print(f'  {label}: osm_id={osm_id}  ABSENT (not in bundle!)', flush=True)
    l9 = sum(1 for r in regions.values() if r.admin_level == 9)
    print(f'  L9 (Ortsteil) region count: {l9}', flush=True)
    assert set(regions.keys()) == set(totals.keys()), \
        'INVARIANT VIOLATION: admin bundle key-set != totals key-set'
    print(f'  key-set invariant OK: {len(regions)} regions == {len(totals)} totals',
          flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description='Build Trailblazer region assets from a PBF.')
    ap.add_argument('--pbf', required=True)
    ap.add_argument('--out-admin', required=True)
    ap.add_argument('--out-totals', required=True)
    ap.add_argument('--simplify-scale', type=float, default=1.0,
                    help='multiply per-level tolerances (>1 = smaller bundle)')
    args = ap.parse_args()

    t0 = time.time()
    regions = collect_regions(args.pbf)
    if not regions:
        print('ERROR: no admin regions found — wrong PBF or filter?', file=sys.stderr)
        return 1
    totals = compute_totals(args.pbf, regions)

    scale = args.simplify_scale
    size = write_admin_bundle(args.out_admin, regions, scale)
    # Auto-tighten if over the 15 MB budget (up to 3 escalating passes).
    while size > _ADMIN_BUNDLE_BUDGET_BYTES and scale < 8.0:
        scale *= 2.0
        print(f'  bundle over 15 MB budget — retrying at simplify-scale={scale} ...',
              flush=True)
        size = write_admin_bundle(args.out_admin, regions, scale)
    if size > _ADMIN_BUNDLE_BUDGET_BYTES:
        print(f'ERROR: admin bundle still {size/1024/1024:.1f} MB > 15 MB budget.',
              file=sys.stderr)
        return 1

    write_totals(args.out_totals, totals)
    _sanity(regions, totals)
    print(f'DONE in {time.time() - t0:.0f}s.', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
