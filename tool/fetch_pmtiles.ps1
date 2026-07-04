# Fetch the dev PMTiles asset used for offline map rendering in Phase 2.
# This asset is gitignored -- every fresh clone must run this once.
# Replaced in Phase 4 by a custom-built germany-base.pmtiles from the
# OSM pipeline.
#
# Usage:
#   pwsh tool/fetch_pmtiles.ps1
#   (or: powershell -File tool/fetch_pmtiles.ps1)
#
# Requirements:
#   pmtiles CLI -- https://github.com/protomaps/go-pmtiles/releases/latest
#   Network access (uses HTTP range requests against Protomaps demo bucket)

$ErrorActionPreference = "Stop"

$TileFile  = "assets/tiles/dev_germany.pmtiles"
$SourceUrl = "https://demo-bucket.protomaps.com/v4.pmtiles"
$Bbox      = "5.866,47.270,15.042,55.058"   # Germany
$MaxZoom   = 14

if (Test-Path $TileFile) {
    $size = (Get-Item $TileFile).Length / 1MB
    Write-Host ("Tile file already exists: {0} ({1:N0} MB)" -f $TileFile, $size)
    Write-Host "Delete it first to regenerate."
    exit 0
}

$pmtiles = Get-Command pmtiles -ErrorAction SilentlyContinue
if (-not $pmtiles) {
    Write-Error @"
ERROR: pmtiles CLI not found in PATH.
Install from: https://github.com/protomaps/go-pmtiles/releases/latest
Download the Windows binary (go-pmtiles_<version>_Windows_x86_64.zip),
extract pmtiles.exe, and place it somewhere on your PATH (e.g. C:\tools\).
"@
    exit 1
}

New-Item -ItemType Directory -Force -Path "assets/tiles" | Out-Null

Write-Host "Extracting Germany (bbox=$Bbox maxzoom=$MaxZoom) from Protomaps demo bucket..."
Write-Host "This may take 2-5 minutes depending on network."

& pmtiles extract $SourceUrl $TileFile "--bbox=$Bbox" "--maxzoom=$MaxZoom"

$finalSize = (Get-Item $TileFile).Length / 1MB
Write-Host ("Done. Size: {0:N0} MB" -f $finalSize)
Write-Host "Verify magic bytes (first 7 bytes should be 'PMTiles'):"
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $TileFile))[0..6]
Write-Host ([System.Text.Encoding]::ASCII.GetString($bytes))
