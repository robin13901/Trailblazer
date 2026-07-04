#!/usr/bin/env bash
# Fetch the dev PMTiles asset used for offline map rendering in Phase 2.
# This asset is gitignored — every fresh clone must run this once.
# Replaced in Phase 4 by a custom-built germany-base.pmtiles from the
# OSM pipeline.
#
# Usage:
#   bash tool/fetch_pmtiles.sh
#
# Requirements:
#   pmtiles CLI — https://github.com/protomaps/go-pmtiles/releases/latest
#   Network access (uses HTTP range requests against Protomaps demo bucket)

set -euo pipefail

TILE_FILE="assets/tiles/dev_germany.pmtiles"
SOURCE_URL="https://demo-bucket.protomaps.com/v4.pmtiles"
BBOX="5.866,47.270,15.042,55.058"  # Germany (Konstanz to Sylt, Aachen to Goerlitz)
MAXZOOM=14

if [ -f "$TILE_FILE" ]; then
  echo "Tile file already exists: $TILE_FILE ($(du -h "$TILE_FILE" | cut -f1))"
  echo "Delete it first to regenerate."
  exit 0
fi

if ! command -v pmtiles &>/dev/null; then
  echo "ERROR: pmtiles CLI not found."
  echo "Install from: https://github.com/protomaps/go-pmtiles/releases/latest"
  exit 1
fi

mkdir -p assets/tiles
echo "Extracting Germany (bbox=$BBOX maxzoom=$MAXZOOM) from Protomaps demo bucket..."
echo "This may take 2-5 minutes depending on network."
pmtiles extract "$SOURCE_URL" "$TILE_FILE" --bbox="$BBOX" --maxzoom="$MAXZOOM"

echo "Done. Size: $(du -h "$TILE_FILE" | cut -f1)"
echo "Verify magic bytes:"
head -c 7 "$TILE_FILE" | od -c | head -1
