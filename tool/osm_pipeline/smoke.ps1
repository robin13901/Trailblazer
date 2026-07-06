#!/usr/bin/env pwsh
# Trailblazer OSM Pipeline -- Berlin bbox smoke test (Windows).
#
# Downloads Berlin PBF from Geofabrik (~60 MB) if absent, runs the pipeline
# with a Berlin bbox, and asserts the two output artifacts exist and are
# non-empty. Requires WSL2 tippecanoe -- see tippecanoe/README.md.
#
# Targets (04-RESEARCH sec.11 ceilings -- soft, WARN not FAIL):
#   wall-clock < 60 s
#   osm.sqlite < 20 MB
#   germany-base.pmtiles < 15 MB
#
# Usage from repo root:
#   pwsh tool\osm_pipeline\smoke.ps1

$ErrorActionPreference = "Stop"

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$outDir       = Join-Path $repoRoot "tool\osm_pipeline\out"
$pbfPath      = Join-Path $outDir "berlin-latest.osm.pbf"
$geofabrikUrl = "https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf"

# Berlin bbox: (minLng, minLat, maxLng, maxLat)
$bbox = "13.0,52.3,13.8,52.7"

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (-not (Test-Path $pbfPath)) {
    Write-Host "-> Downloading Berlin PBF from Geofabrik..."
    # Invoke-WebRequest is faster with the default progress bar suppressed on
    # large downloads (PowerShell known-issue: progress rendering ~10x slower).
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $geofabrikUrl -OutFile $pbfPath
    } finally {
        $ProgressPreference = $prevProgress
    }
} else {
    Write-Host "-> Using cached Berlin PBF at $pbfPath"
}

$pbfMB = [math]::Round((Get-Item $pbfPath).Length / 1MB, 1)
Write-Host "-> Berlin PBF size: $pbfMB MB"

# Preflight: tippecanoe reachable via WSL2.
# NOTE: tippecanoe --version prints its banner to STDERR. PowerShell's 2>&1
# wraps native-command stderr into ErrorRecord objects, which Out-String
# renders with error decoration ("wsl.exe : ..." + call-site info) even when
# ErrorActionPreference is Continue. Route through cmd /c so the redirection
# happens at the OS level and PowerShell only sees plain strings.
Write-Host "-> Preflight: wsl.exe -- tippecanoe --version"
$tippVer = (cmd /c "wsl.exe -- tippecanoe --version 2>&1").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tippVer)) {
    Write-Error ("tippecanoe not available under WSL (exit=$LASTEXITCODE). " +
        "See tool/osm_pipeline/tippecanoe/README.md.`nOutput: $tippVer")
    exit 1
}
Write-Host "   $tippVer"

Write-Host "-> Running pipeline..."
$start = Get-Date

# Run from inside the sub-package. `dart run tool/osm_pipeline` from repo root
# does not work: the root pubspec's drift_dev ^2.34 pins sqlite3 ^3.0.0 while
# tool/osm_pipeline pins sqlite3 ^2.4.0, so pub resolution fails at the root.
# The sub-package has its own pubspec.lock; running there is the supported path.
$pkgDir = Join-Path $repoRoot "tool\osm_pipeline"
Push-Location $pkgDir
try {
    & dart run bin/osm_pipeline.dart --pbf="$pbfPath" --bbox=$bbox --out-dir="$outDir"
    if ($LASTEXITCODE -ne 0) {
        throw "Pipeline exited with code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)

Write-Host ""
Write-Host "-> Verifying artifacts..."
$osmSqlite = Join-Path $outDir "osm.sqlite"
$pmtiles   = Join-Path $outDir "germany-base.pmtiles"

if (-not (Test-Path $osmSqlite)) { Write-Error "FAIL: $osmSqlite missing"; exit 1 }
if (-not (Test-Path $pmtiles))   { Write-Error "FAIL: $pmtiles missing";   exit 1 }

$osmMB = [math]::Round((Get-Item $osmSqlite).Length / 1MB, 1)
$pmtMB = [math]::Round((Get-Item $pmtiles).Length / 1MB, 1)

Write-Host "  osm.sqlite:           $osmMB MB"
Write-Host "  germany-base.pmtiles: $pmtMB MB"
Write-Host ""
Write-Host "-> Wall-clock: $elapsed s (target < 60 s per 04-RESEARCH sec.11)"

# Soft targets -- warn, don't fail. 04-RESEARCH sec.11 ceilings for Berlin:
# osm.sqlite < 20 MB, pmtiles < 15 MB.
if ($osmMB -gt 20) { Write-Warning "osm.sqlite > 20 MB (Berlin ceiling per 04-RESEARCH sec.11)" }
if ($pmtMB -gt 15) { Write-Warning "germany-base.pmtiles > 15 MB (Berlin ceiling per 04-RESEARCH sec.11)" }
if ($elapsed -gt 60) { Write-Warning "wall-clock > 60 s (soft target per 04-RESEARCH sec.11 -- first run may be slower)" }

Write-Host ""
Write-Host "SMOKE PASS."
