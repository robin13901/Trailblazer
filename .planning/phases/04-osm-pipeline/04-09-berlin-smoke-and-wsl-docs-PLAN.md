---
id: 04-09
phase: 04-osm-pipeline
plan: 09
type: execute
wave: 7
depends_on: [04-06, 04-08]
files_modified:
  - tool/osm_pipeline/smoke.sh
  - tool/osm_pipeline/smoke.ps1
  - tool/osm_pipeline/tippecanoe/README.md
  - tool/osm_pipeline/README.md
  - tool/osm_pipeline/test/smoke/berlin_smoke_manual.md
autonomous: false
requirements: [OSM-08]

must_haves:
  truths:
    - "tool/osm_pipeline/smoke.sh (bash) downloads berlin-latest.osm.pbf from Geofabrik if absent, runs the pipeline with --bbox=13.0,52.3,13.8,52.7, and asserts osm.sqlite + germany-base.pmtiles exist under out/"
    - "tool/osm_pipeline/smoke.ps1 (PowerShell twin) does the same on Windows dev boxes — Invoke-WebRequest for the download, dart run for the CLI, Test-Path for the assertion"
    - "tool/osm_pipeline/tippecanoe/README.md documents the WSL2 install path in step-by-step form (enable WSL, install Ubuntu, apt install tippecanoe or build from source), verifies via `wsl.exe -- tippecanoe --version`"
    - "SC1 (Berlin-bbox produces both artifacts) and SC5 (arbitrary --bbox works) are both PASS on the developer's dev box after this plan executes and the manual checkpoint completes"
    - "Wall-clock timing on the Berlin smoke is recorded in the plan's SUMMARY: target < 60 s per 04-RESEARCH §11"
    - "osm.sqlite output for Berlin is < 20 MB; germany-base.pmtiles output for Berlin is < 15 MB (04-RESEARCH §11 targets: 15 MB and 10 MB respectively — treat as ceilings with 30% headroom)"
  artifacts:
    - path: "tool/osm_pipeline/smoke.sh"
      provides: "One-command Berlin smoke on macOS/Linux"
    - path: "tool/osm_pipeline/smoke.ps1"
      provides: "One-command Berlin smoke on Windows (via WSL2 tippecanoe subprocess)"
    - path: "tool/osm_pipeline/tippecanoe/README.md"
      provides: "Windows-specific WSL2 install guide"
  key_links:
    - from: "tool/osm_pipeline/smoke.sh"
      to: "tool/osm_pipeline/bin/osm_pipeline.dart"
      via: "invokes with --pbf and --bbox flags"
      pattern: "dart run"
    - from: "tool/osm_pipeline/README.md"
      to: "tool/osm_pipeline/tippecanoe/README.md"
      via: "links from the Prerequisites section to the WSL2 detailed guide"
      pattern: "tippecanoe/README.md"
---

## Goal

Ship a one-command Berlin-bbox smoke test for both platforms + a definitive WSL2/tippecanoe install guide for the Windows dev box. Closes SC1 + SC5 on the developer's machine.

## Context

- 04-RESEARCH §11: "Add a `tool/osm_pipeline/smoke.sh` (bash + PowerShell twin) that downloads Berlin PBF from Geofabrik if missing and runs the pipeline. One-command reproducibility for a new developer." Explicitly not a CI job in v1 (Berlin PBF is external, > 60 MB).
- Expected Berlin wall-clock: 30–60 s end-to-end. Expected sizes: osm.sqlite ~15 MB, pmtiles ~10 MB (04-RESEARCH §11).
- Windows dev box lacks a native tippecanoe. 04-01 introduced the WSL2 mention in the top-level README. This plan owns the DETAILED install guide at `tool/osm_pipeline/tippecanoe/README.md`.
- SC1 (running `dart run tool/osm_pipeline` against a Berlin-bbox PBF produces both artifacts) is closed HERE, not in 04-06/07, because it requires a real Berlin PBF and real tippecanoe execution.
- SC5 (arbitrary `--bbox` works) is closed HERE via the same smoke — the bbox is Berlin's, proving the flag works.
- 04-CONTEXT locks a monolithic CLI with only `--pbf` and `--bbox` flags — the smoke script doesn't need any extra flags on the CLI itself.
- **This plan is `autonomous: false`** — it has a `checkpoint:human-verify` for the Berlin smoke run. Automation cannot download the PBF, run tippecanoe, AND validate output sizes without human involvement (the user's laptop has the tippecanoe/WSL2 setup, not the CI). See Task 4.

## Tasks

<task type="auto">
  <name>Task 1: WSL2 + tippecanoe install guide for Windows</name>
  <files>
    tool/osm_pipeline/tippecanoe/README.md
    tool/osm_pipeline/README.md
  </files>
  <intent>Definitive step-by-step install guide for the Windows dev box.</intent>
  <action>
    Create `tool/osm_pipeline/tippecanoe/README.md`:

    ```markdown
    # tippecanoe on Windows via WSL2

    The Trailblazer OSM pipeline shells out to `tippecanoe` for PMTiles authoring
    (see `../README.md` §Pipeline shape). tippecanoe has no first-party Windows
    binary; install it under WSL2 and the pipeline invokes it via `wsl.exe -- tippecanoe ...`.

    ## Prerequisites

    - Windows 10 build 19041+ or Windows 11
    - Admin rights (to enable WSL feature)
    - ~5 GB free disk for WSL Ubuntu

    ## Step 1: Enable WSL2

    Open PowerShell as Administrator:

    ```powershell
    wsl --install
    ```

    This installs the WSL feature and Ubuntu (default distro). Reboot when prompted.

    Verify:
    ```powershell
    wsl --status
    wsl --list --verbose
    ```
    Expect `Default Version: 2` and one distro (Ubuntu) with `VERSION 2`.

    ## Step 2: Install tippecanoe under WSL

    Open the Ubuntu shell (`wsl` in PowerShell, or open "Ubuntu" from Start).

    **Preferred (Ubuntu 22.04+):**
    ```bash
    sudo apt update
    sudo apt install -y build-essential libsqlite3-dev zlib1g-dev git
    git clone https://github.com/felt/tippecanoe.git
    cd tippecanoe
    make -j$(nproc)
    sudo make install
    ```
    *(Ubuntu's `apt install tippecanoe` package exists but tends to be several
    versions behind. Building from source is ~2 minutes and gives us
    tippecanoe ≥ 2.30 which we need for pmtiles output.)*

    **Verify:**
    ```bash
    tippecanoe --version
    ```
    Expect `tippecanoe v2.30.0` or higher.

    ## Step 3: Verify from Windows PowerShell

    ```powershell
    wsl.exe -- tippecanoe --version
    ```
    Same version string should appear. This is exactly the invocation the
    pipeline uses.

    ## Step 4: Run the Berlin smoke

    From the repo root in PowerShell:
    ```powershell
    tool\osm_pipeline\smoke.ps1
    ```

    Or bash (if you use Git Bash / WSL as your shell):
    ```bash
    ./tool/osm_pipeline/smoke.sh
    ```

    ## Troubleshooting

    | Symptom | Fix |
    |---------|-----|
    | `wsl.exe -- tippecanoe: command not found` | Repeat Step 2 inside `wsl.exe`. The `--` is required — it separates wsl flags from the command to run. |
    | `Permission denied` on `/mnt/c/...` files | tippecanoe running in WSL sees Windows drives at `/mnt/c/`. The pipeline auto-translates paths (see `tippecanoe_runner.dart::_wslifyPath`). If custom paths break, ensure they're absolute. |
    | Slow file I/O | Run the pipeline against files in the WSL filesystem (`~/`) rather than `/mnt/c/`. Windows/WSL cross-filesystem I/O is ~10× slower. |
    | tippecanoe OOMs on full Germany | Add `--maximum-tile-bytes=500000 --drop-densest-as-needed` — the pipeline already sets `--drop-densest-as-needed`; tighten `--maximum-tile-bytes` if needed. |

    ## Alternative: felt/tippecanoe Docker image

    If WSL2 is unavailable (older Windows, corporate lockdown), use:
    ```powershell
    docker pull felt/tippecanoe:latest
    ```
    Then swap `TippecanoeRunner._resolveExecutable()` to shell out via
    `docker run --rm -v ${outDir}:/data felt/tippecanoe:latest tippecanoe ...`.
    Not the default path — deferred to a follow-up if WSL2 proves problematic.
    ```

    Update `tool/osm_pipeline/README.md` — replace the placeholder "See `tippecanoe/README.md` (created by plan 04-09)" from 04-01 with a real link.

    Cross-check: verify `wsl.exe -- tippecanoe --version` works on the current dev box. If NOT, this is a checkpoint blocker for Task 4 — surface to user.
  </action>
  <verify>
    `tool/osm_pipeline/tippecanoe/README.md` exists.
    `tool/osm_pipeline/README.md` no longer references "created by plan 04-09".
    Manual: run `wsl.exe -- tippecanoe --version` in a PowerShell prompt; verify success. If it fails, the executor SHOULD stop and ask the user to complete the tippecanoe install before proceeding.
  </verify>
</task>

<task type="auto">
  <name>Task 2: smoke.sh (bash) for macOS/Linux + Git Bash</name>
  <files>
    tool/osm_pipeline/smoke.sh
  </files>
  <intent>One-command Berlin smoke on bash-capable environments.</intent>
  <action>
    Create `tool/osm_pipeline/smoke.sh`:

    ```bash
    #!/usr/bin/env bash
    set -euo pipefail

    # Trailblazer OSM Pipeline — Berlin bbox smoke test.
    #
    # Downloads Berlin PBF from Geofabrik (~60 MB) if absent, runs the pipeline
    # with a Berlin bbox, and asserts the two output artifacts exist and are
    # non-empty.

    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    OUT_DIR="${REPO_ROOT}/tool/osm_pipeline/out"
    PBF_PATH="${OUT_DIR}/berlin-latest.osm.pbf"
    GEOFABRIK_URL="https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf"

    # Berlin bbox: (minLng, minLat, maxLng, maxLat)
    BBOX="13.0,52.3,13.8,52.7"

    mkdir -p "${OUT_DIR}"

    if [[ ! -f "${PBF_PATH}" ]]; then
      echo "→ Downloading Berlin PBF from Geofabrik..."
      curl -L --fail -o "${PBF_PATH}" "${GEOFABRIK_URL}"
    else
      echo "→ Using cached Berlin PBF at ${PBF_PATH}"
    fi

    echo "→ Berlin PBF size: $(du -h "${PBF_PATH}" | cut -f1)"

    echo "→ Running pipeline..."
    START=$(date +%s)

    cd "${REPO_ROOT}"
    dart run tool/osm_pipeline \
      --pbf="${PBF_PATH}" \
      --bbox="${BBOX}"

    END=$(date +%s)
    ELAPSED=$((END - START))

    echo ""
    echo "→ Verifying artifacts..."
    OSM_SQLITE="${OUT_DIR}/osm.sqlite"
    PMTILES="${OUT_DIR}/germany-base.pmtiles"

    [[ -f "${OSM_SQLITE}" ]]  || { echo "FAIL: ${OSM_SQLITE} missing"; exit 1; }
    [[ -f "${PMTILES}" ]]     || { echo "FAIL: ${PMTILES} missing"; exit 1; }

    OSM_SIZE=$(stat -f%z "${OSM_SQLITE}" 2>/dev/null || stat -c%s "${OSM_SQLITE}")
    PMT_SIZE=$(stat -f%z "${PMTILES}"    2>/dev/null || stat -c%s "${PMTILES}")

    echo "  osm.sqlite:         $(du -h "${OSM_SQLITE}" | cut -f1)"
    echo "  germany-base.pmtiles: $(du -h "${PMTILES}" | cut -f1)"
    echo ""
    echo "→ Wall-clock: ${ELAPSED} s (target < 60 s per 04-RESEARCH §11)"

    # Soft targets — warn, don't fail. Ceilings for Berlin per 04-RESEARCH §11:
    # osm.sqlite < 20 MB, pmtiles < 15 MB.
    if (( OSM_SIZE > 20 * 1024 * 1024 )); then
      echo "WARN: osm.sqlite > 20 MB (expected < 20 MB for Berlin)"
    fi
    if (( PMT_SIZE > 15 * 1024 * 1024 )); then
      echo "WARN: germany-base.pmtiles > 15 MB (expected < 15 MB for Berlin)"
    fi

    echo ""
    echo "SMOKE PASS."
    ```

    `chmod +x tool/osm_pipeline/smoke.sh` after creation.
  </action>
  <verify>
    `tool/osm_pipeline/smoke.sh` exists and is executable.
    On a machine with Berlin PBF + tippecanoe available, `./tool/osm_pipeline/smoke.sh` runs green.
  </verify>
</task>

<task type="auto">
  <name>Task 3: smoke.ps1 (PowerShell) for Windows</name>
  <files>
    tool/osm_pipeline/smoke.ps1
  </files>
  <intent>PowerShell twin for the Windows dev box.</intent>
  <action>
    Create `tool/osm_pipeline/smoke.ps1`:

    ```powershell
    #!/usr/bin/env pwsh
    # Trailblazer OSM Pipeline — Berlin bbox smoke test (Windows).
    #
    # Downloads Berlin PBF from Geofabrik (~60 MB) if absent, runs the pipeline
    # with a Berlin bbox, and asserts the two output artifacts exist and are
    # non-empty. Requires WSL2 tippecanoe — see tippecanoe/README.md.

    $ErrorActionPreference = "Stop"

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $outDir = Join-Path $repoRoot "tool\osm_pipeline\out"
    $pbfPath = Join-Path $outDir "berlin-latest.osm.pbf"
    $geofabrikUrl = "https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf"

    # Berlin bbox: (minLng, minLat, maxLng, maxLat)
    $bbox = "13.0,52.3,13.8,52.7"

    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    if (-not (Test-Path $pbfPath)) {
        Write-Host "-> Downloading Berlin PBF from Geofabrik..."
        Invoke-WebRequest -Uri $geofabrikUrl -OutFile $pbfPath
    } else {
        Write-Host "-> Using cached Berlin PBF at $pbfPath"
    }

    $pbfSize = (Get-Item $pbfPath).Length / 1MB
    Write-Host "-> Berlin PBF size: $([math]::Round($pbfSize, 1)) MB"

    # Preflight: tippecanoe under WSL2
    try {
        $tippVer = & wsl.exe -- tippecanoe --version 2>&1
        Write-Host "-> tippecanoe available: $tippVer"
    } catch {
        Write-Error "tippecanoe not available under WSL. See tool/osm_pipeline/tippecanoe/README.md."
        exit 1
    }

    Write-Host "-> Running pipeline..."
    $start = Get-Date

    Push-Location $repoRoot
    try {
        dart run tool/osm_pipeline --pbf="$pbfPath" --bbox=$bbox
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
    Write-Host "-> Wall-clock: $elapsed s (target < 60 s per 04-RESEARCH §11)"

    if ($osmMB -gt 20) { Write-Warning "osm.sqlite > 20 MB (expected < 20 MB for Berlin)" }
    if ($pmtMB -gt 15) { Write-Warning "germany-base.pmtiles > 15 MB (expected < 15 MB for Berlin)" }

    Write-Host ""
    Write-Host "SMOKE PASS."
    ```
  </action>
  <verify>
    `tool/osm_pipeline/smoke.ps1` exists.
    On Windows dev box: `pwsh tool/osm_pipeline/smoke.ps1` (or `powershell -File ...`) runs and reaches the pipeline invocation. Actual pipeline success is checked by the human-verify task below.
  </verify>
</task>

<task type="checkpoint:human-verify">
  <name>Task 4: Run the Berlin smoke on the dev box</name>
  <gate>blocking</gate>
  <what-built>
    - Smoke script (`smoke.ps1` on Windows) that downloads Berlin PBF, runs the pipeline, produces osm.sqlite + germany-base.pmtiles.
    - WSL2 tippecanoe install guide at `tool/osm_pipeline/tippecanoe/README.md`.
  </what-built>
  <how-to-verify>
    1. If not yet installed, follow `tool/osm_pipeline/tippecanoe/README.md` to install WSL2 + tippecanoe.
    2. From repo root: `pwsh tool\osm_pipeline\smoke.ps1` (Windows) or `./tool/osm_pipeline/smoke.sh` (macOS/Linux/Git Bash).
    3. Expected output:
       - Downloads berlin-latest.osm.pbf (~60 MB) on first run; uses cache on subsequent.
       - Pipeline runs to completion; "SMOKE PASS." at the end.
       - `tool/osm_pipeline/out/osm.sqlite` exists (< 20 MB).
       - `tool/osm_pipeline/out/germany-base.pmtiles` exists (< 15 MB).
       - Wall-clock printed; target < 60 s.
    4. Open `out/osm.sqlite` in a sqlite viewer OR with `sqlite3 out/osm.sqlite "PRAGMA user_version; SELECT * FROM metadata;"`. Confirm the metadata table has 7 rows.
    5. Optional: temporarily point the app at `out/germany-base.pmtiles` (copy over `assets/tiles/dev_germany.pmtiles`) and run the app on a device — confirm Berlin renders correctly with the new 4-layer schema. This is a nice-to-have; if styles look wrong, that's the escalation trigger for 04-08 fixes.
    6. Record the wall-clock time + output file sizes in the plan's SUMMARY when signing off.
  </how-to-verify>
  <resume-signal>
    Reply "smoke pass — <wall-clock> s, osm.sqlite <X> MB, pmtiles <Y> MB" or describe any deviation. If the pipeline errors out, paste the error and the executor will iterate on the failing stage.
  </resume-signal>
</task>

## Verification

- `tool/osm_pipeline/smoke.sh` and `smoke.ps1` exist and are shipped.
- `tool/osm_pipeline/tippecanoe/README.md` documents the WSL2 install path in step-by-step form.
- Task 4 checkpoint returns a "smoke pass" signal.
- osm.sqlite for Berlin < 20 MB; germany-base.pmtiles for Berlin < 15 MB.
- Wall-clock < 60 s (soft target — 60–120 s tolerable if it's the first run and downloads are involved).

## Deviation Handling

- If Berlin smoke wall-clock > 5 minutes: something is O(n²) that shouldn't be. Suspect the segmented-intersection algorithm (04-05) — profile with `dart --observe`. Fix in a corrective mini-plan before running 04-10.
- If osm.sqlite for Berlin > 30 MB: the denormalized ways admin columns are heavier than 04-05's projection. Re-run 04-05's measurement probe on the actual Berlin PBF and revisit the schema choice in 04-06.
- If germany-base.pmtiles for Berlin > 20 MB: the vector data is denser than expected. Add tippecanoe `--maximum-tile-bytes=500000` or drop the `labels` layer at low zoom.
- If tippecanoe is genuinely unavailable and the user does NOT want to set up WSL2: this plan cannot complete. Escalate to user for a decision — the fallback is dockerized tippecanoe (documented at bottom of `tippecanoe/README.md`).
- Iterate up to 3 times per task on non-checkpoint tasks; checkpoint (Task 4) blocks until human confirms.
