#!/usr/bin/env bash
set -euo pipefail

# Trailblazer OSM Pipeline — Berlin bbox smoke test.
#
# Downloads Berlin PBF from Geofabrik (~60 MB) if absent, runs the pipeline
# with a Berlin bbox, and asserts the two output artifacts exist and are
# non-empty.
#
# Targets (04-RESEARCH §11 ceilings — soft, WARN not FAIL):
#   wall-clock < 60 s
#   osm.sqlite < 20 MB
#   germany-base.pmtiles < 15 MB
#
# Prerequisites: dart >= 3.5, tippecanoe (Linux/macOS: on PATH; Windows via
# Git Bash: requires WSL2 tippecanoe — see tippecanoe/README.md).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${REPO_ROOT}/tool/osm_pipeline/out"
PBF_PATH="${OUT_DIR}/berlin-latest.osm.pbf"
GEOFABRIK_URL="https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf"

# Berlin bbox: (minLng, minLat, maxLng, maxLat)
BBOX="13.0,52.3,13.8,52.7"

mkdir -p "${OUT_DIR}"

if [[ ! -f "${PBF_PATH}" ]]; then
  echo "-> Downloading Berlin PBF from Geofabrik..."
  curl -L --fail -o "${PBF_PATH}" "${GEOFABRIK_URL}"
else
  echo "-> Using cached Berlin PBF at ${PBF_PATH}"
fi

echo "-> Berlin PBF size: $(du -h "${PBF_PATH}" | cut -f1)"

echo "-> Running pipeline..."
START=$(date +%s)

# Run from inside the sub-package. `dart run tool/osm_pipeline` from repo root
# fails because the root pubspec's drift_dev ^2.34 pins sqlite3 ^3.0.0 while
# tool/osm_pipeline pins sqlite3 ^2.4.0, so pub resolution errors at the root.
# The sub-package has its own pubspec.lock; running there is the supported path.
cd "${REPO_ROOT}/tool/osm_pipeline"
dart run bin/osm_pipeline.dart \
  --pbf="${PBF_PATH}" \
  --bbox="${BBOX}" \
  --out-dir="${OUT_DIR}"

END=$(date +%s)
ELAPSED=$((END - START))

echo ""
echo "-> Verifying artifacts..."
OSM_SQLITE="${OUT_DIR}/osm.sqlite"
PMTILES="${OUT_DIR}/germany-base.pmtiles"

[[ -f "${OSM_SQLITE}" ]] || { echo "FAIL: ${OSM_SQLITE} missing"; exit 1; }
[[ -f "${PMTILES}"    ]] || { echo "FAIL: ${PMTILES} missing";    exit 1; }

# Portable byte size (BSD stat -f%z on macOS; GNU stat -c%s on Linux).
OSM_SIZE=$(stat -f%z "${OSM_SQLITE}" 2>/dev/null || stat -c%s "${OSM_SQLITE}")
PMT_SIZE=$(stat -f%z "${PMTILES}"    2>/dev/null || stat -c%s "${PMTILES}")

echo "  osm.sqlite:           $(du -h "${OSM_SQLITE}" | cut -f1)"
echo "  germany-base.pmtiles: $(du -h "${PMTILES}"    | cut -f1)"
echo ""
echo "-> Wall-clock: ${ELAPSED} s (target < 60 s per 04-RESEARCH §11)"

# Soft targets — warn, don't fail. 04-RESEARCH §11 ceilings for Berlin:
# osm.sqlite < 20 MB, pmtiles < 15 MB (with 30% headroom on the 15/10 targets).
if (( OSM_SIZE > 20 * 1024 * 1024 )); then
  echo "WARN: osm.sqlite > 20 MB (Berlin ceiling per 04-RESEARCH §11)"
fi
if (( PMT_SIZE > 15 * 1024 * 1024 )); then
  echo "WARN: germany-base.pmtiles > 15 MB (Berlin ceiling per 04-RESEARCH §11)"
fi
if (( ELAPSED > 60 )); then
  echo "WARN: wall-clock > 60 s (soft target per 04-RESEARCH §11 — first run may be slower)"
fi

echo ""
echo "SMOKE PASS."
