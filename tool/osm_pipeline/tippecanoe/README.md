# tippecanoe on Windows via WSL2

The Trailblazer OSM pipeline shells out to `tippecanoe` for PMTiles authoring
(see `../README.md` §Pipeline shape, Stage D). `tippecanoe` has no first-party
Windows binary — install it under WSL2 and the pipeline invokes it via
`wsl.exe -- tippecanoe …` (path translation is handled automatically by
`lib/pmtiles/tippecanoe_runner.dart::wslifyPath`).

This document covers two WSL2 flavors:

- **Path A — Ubuntu-in-WSL2** (the standard `wsl --install` path, easiest for
  most Windows dev boxes).
- **Path B — Rancher Desktop's Alpine distro** (what this repo's primary dev
  box runs; Rancher ships an Alpine WSL distro alongside Docker).

Both paths end at the same verification: `wsl.exe -- tippecanoe --version`
returns `tippecanoe v2.30.0` or higher.

## Prerequisites

- Windows 10 build 19041+ or Windows 11
- Admin rights (needed to enable WSL feature; not needed inside Rancher's
  Alpine distro because it runs passwordless-root by default)
- ~5 GB free disk (Ubuntu image + build toolchain)
- Working internet from *inside* WSL — see [DNS fix](#dns-fix-if-wsl-cant-reach-the-internet)
  below if `apt` / `apk` hang or fail with `Temporary failure in name resolution`

---

## Path A — Ubuntu in WSL2 (recommended)

### Step 1: Enable WSL2 + install Ubuntu

Open PowerShell **as Administrator**:

```powershell
wsl --install
```

This enables the WSL feature and installs the default Ubuntu distro. Reboot
when prompted. On first launch of Ubuntu, create a username + password (you'll
use `sudo` for the build steps).

Verify from any PowerShell:

```powershell
wsl --status
wsl --list --verbose
```

Expect `Default Version: 2` and one distro (`Ubuntu`) with `VERSION 2`.

### Step 2: Build tippecanoe from source

Open the Ubuntu shell (`wsl` in PowerShell, or launch "Ubuntu" from Start).

```bash
sudo apt update
sudo apt install -y build-essential libsqlite3-dev zlib1g-dev git
git clone --depth 1 https://github.com/felt/tippecanoe.git
cd tippecanoe
make -j$(nproc)
sudo make install
```

Ubuntu's `apt install tippecanoe` package exists but tends to be several
versions behind. Building from source takes ~2 minutes and gives us
`tippecanoe ≥ 2.30` (required for pmtiles output).

### Step 3: Verify

Inside the WSL shell:

```bash
tippecanoe --version
```

Then from Windows PowerShell (the invocation the pipeline uses):

```powershell
wsl.exe -- tippecanoe --version
```

Both should print `tippecanoe v2.30.0` or higher.

---

## Path B — Rancher Desktop's Alpine distro

Rancher Desktop ships its own WSL2 distro (`rancher-desktop`), based on
Alpine Linux. If Rancher is already installed for Docker, you can install
tippecanoe there without pulling in a second Ubuntu distro.

The distro runs **as root by default** — no `sudo` required.

### Step 1: Enter the Rancher WSL distro

```powershell
wsl -d rancher-desktop
```

### Step 2 (only if needed): DNS fix

Rancher's `/etc/resolv.conf` sometimes points at an internal `192.168.127.1`
address that fails to resolve public hostnames. If `apk` or `git clone`
hangs, patch DNS:

```bash
# Inside the rancher-desktop shell:
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
```

(Rancher regenerates `/etc/resolv.conf` on each boot — you may need to
re-apply this after a reboot until you configure `wsl.conf` to preserve it.)

### Step 3: Build tippecanoe

```bash
apk add --no-cache build-base sqlite-dev zlib-dev git make g++ bash
git clone --depth 1 https://github.com/felt/tippecanoe.git /tmp/tippecanoe
cd /tmp/tippecanoe
make -j
make install
```

`tippecanoe` lands at `/usr/local/bin/tippecanoe`.

### Step 4: Verify

Inside the Alpine shell:

```bash
tippecanoe --version
```

From Windows PowerShell:

```powershell
wsl.exe -d rancher-desktop -- tippecanoe --version
```

Note: if Rancher is your *only* installed WSL distro, `wsl.exe -- tippecanoe
--version` (no `-d`) will hit it as the default and works too. The
pipeline's `TippecanoeRunner` uses the plain form; set `rancher-desktop` as
the default distro if you keep multiple installed:

```powershell
wsl --set-default rancher-desktop
```

---

## Step 4 (both paths): Run the Berlin smoke

From the repo root in PowerShell:

```powershell
pwsh tool\osm_pipeline\smoke.ps1
```

Or from bash (Git Bash / WSL as your shell):

```bash
./tool/osm_pipeline/smoke.sh
```

Expected: downloads `berlin-latest.osm.pbf` on first run (~60 MB), runs the
pipeline, prints `SMOKE PASS.` with wall-clock time and output sizes.

---

## DNS fix (if WSL can't reach the internet)

Symptom: `apt update` / `apk update` hangs, or `git clone` fails with
`Could not resolve host: github.com`.

Cause: WSL's `/etc/resolv.conf` was populated with an unreachable nameserver
(common on Rancher's distro, occasionally on Ubuntu after Windows network
config changes).

Fix (inside the WSL shell — replace `sudo` with nothing on Rancher):

```bash
sudo bash -c 'cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF'
```

To make it persist across WSL reboots, add to `/etc/wsl.conf`:

```ini
[network]
generateResolvConf = false
```

Then `wsl --shutdown` from PowerShell and reopen the distro.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `wsl.exe -- tippecanoe: command not found` | tippecanoe not installed in the *default* WSL distro. Repeat Step 2 inside `wsl.exe` (Path A), or set the distro that has it as default: `wsl --set-default <distro>`. |
| `The system cannot find the file specified` on `wsl.exe` | WSL isn't installed. Run `wsl --install` as Administrator (Path A Step 1). |
| `Temporary failure in name resolution` inside WSL | Apply the [DNS fix](#dns-fix-if-wsl-cant-reach-the-internet) above. |
| `Permission denied` on `/mnt/c/...` files | tippecanoe running in WSL sees Windows drives at `/mnt/c/`. The pipeline auto-translates paths via `tippecanoe_runner.dart::wslifyPath`. If custom paths break, ensure they're absolute. |
| Slow file I/O | Windows/WSL cross-filesystem I/O is ~10× slower than same-filesystem. Berlin smoke tolerates this (~1 min wall-clock); full-Germany runs benefit from moving the PBF into the WSL filesystem (`~/`) first. |
| tippecanoe OOMs on full Germany | Add `--maximum-tile-bytes=500000` (the pipeline already sets `--drop-densest-as-needed`). |
| The `--` in `wsl.exe -- tippecanoe --version` looks weird | It separates `wsl.exe`'s own flags from the command to run inside the distro. Without it, `--version` would be interpreted by `wsl.exe` itself. |

---

## Alternative: dockerized tippecanoe

If WSL2 is unavailable (older Windows, corporate lockdown), the fallback is
the community Docker image:

```powershell
docker pull felt/tippecanoe:latest
```

Then swap `TippecanoeRunner._resolveExecutable()` in
`lib/pmtiles/tippecanoe_runner.dart` to shell out via
`docker run --rm -v ${outDir}:/data felt/tippecanoe:latest tippecanoe ...`.

Not the default path — deferred to a follow-up if WSL2 proves problematic.

---

## Reference

- Upstream: https://github.com/felt/tippecanoe
- Pipeline caller: `../lib/pmtiles/tippecanoe_runner.dart`
- Path translator: `wslifyPath()` in the same file (turns `C:\...` into `/mnt/c/...`)
- Layer schema the pipeline emits: `../lib/pmtiles/layer_schema.dart`
