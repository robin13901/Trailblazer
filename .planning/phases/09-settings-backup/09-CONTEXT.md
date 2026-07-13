# Phase 9: Settings + Backup - Context

**Gathered:** 2026-07-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver the Settings surface: a single grouped Settings screen that lets the user
back up and restore their App DB, control raw-GPS retention, inspect permission
status, toggle a diagnostics HUD, reach the coverage-color picker, and view an
About screen with app version + OSS licenses + OSM/MapTiler credits.

**Requirements in scope (as reconciled below):** SET-03, SET-04 (relocate),
SET-05, SET-06 (reuse+extend), SET-07, SET-08, SET-09.

**Requirements de-scoped from the original roadmap text:**
- **SET-01 (Vehicle management)** — DEAD. Vehicles + Bluetooth was cut 2026-07-13
  (schema v4). No vehicle screen exists or will be built.
- **SET-02 (OSM data status / "check for updates" / swap extract)** — DROPPED
  ENTIRELY. The bundled-`osm.sqlite` extract was abandoned in the Phase-4 rescope
  (2026-07-08); there is no extract to update. Map data is now MapTiler tiles
  (streamed, always current) + an on-demand Overpass road cache. No OSM-status
  screen. Map/road credits move to the About screen (SET-09).
- **SET-07 "encrypted"** — SUPERSEDED. Backup archive is plain (unencrypted) per
  the decision below. Single-user private app; App DB holds no credentials.

</domain>

<decisions>
## Implementation Decisions

### Backup & restore (SET-07 / SET-08)
- **No encryption.** Backup is a plain archive of the App DB. SET-07's "encrypted"
  wording is explicitly superseded. Rationale: single-user private app, no
  credentials in the DB, and a plain archive is portable + restorable on any
  device with no forgotten-passphrase failure mode.
- **Archive contents: App DB only.** Includes trips, GPS points
  (`trip_points`), `driven_way_intervals`, `coverage_cache`, `app_prefs`. The
  Overpass way cache is NOT included — it re-fetches on demand after restore.
- **Restore = full wipe-and-swap.** Restore replaces all current data with the
  backup (matches the SC "App DB swapped in place"). NOT a merge. Planner should
  take a pre-restore safety snapshot of the current DB before swapping, and
  validate the incoming archive before committing the swap.
- **Destination = OS file picker.** Export goes through the platform share/save
  sheet: iOS share sheet, Android SAF picker. User chooses iCloud Drive / Drive /
  Files / etc. Restore picks a file via the same OS picker.
- **OSM DB untouched** on both export and restore (there is no separate OSM DB
  anymore under the rescoped architecture — this is trivially satisfied).

### OSM data status (SET-02)
- **Dropped entirely.** No screen, no cache-management UI. Attribution/credits
  (MapTiler + OpenStreetMap contributors) render on the About screen.

### Settings structure & de-scopes
- **Single scrollable grouped Settings screen.** Grouped sections: Data & Backup,
  Coverage, Permissions, Diagnostics, About. Detail sub-screens open where needed.
- **SET-01 vehicles:** dead — no vehicle section.
- **SET-04 coverage color:** RELOCATE the existing 5-preset picker shipped in
  Phase 7 (Plan 07-05: `coveragePresetProvider` + settings picker). Do NOT
  rebuild — just ensure it's reachable from the Coverage section of the tree.
- **SET-06 diagnostics HUD:** REUSE + EXTEND the debug HUD from Phase 3.1
  (Plan 03-1-01: fix rate, last-fix, ingestor counters, permission grants). Add a
  Settings toggle to show/hide it, and extend it with matcher queue depth +
  cache-hit rate.

### Raw-GPS retention (SET-05)
- **Options: 0 / 30 days (default) / 365 days / forever.** (0 = delete raw points
  after matching.)
- **Purge-now on change.** Shortening the window purges the now-expired points
  immediately, behind a confirm dialog. The existing periodic retention sweep
  (Plan 05-01 TripsDao 30-day sweep) continues to enforce the window going
  forward. Setting persists in `app_prefs`.

### Permissions inspector (SET-03)
- **Read-only status list.** No deep-links / no "fix in settings" buttons for v1.
  Each row shows a colored state.
- **Permissions listed:** Location (Always / whenInUse / denied), Motion/Activity,
  Notifications, Battery optimization. **Bluetooth dropped** (feature cut).

### About (SET-09)
- App version, OSS licenses, and credits (OSM contributors + MapTiler
  attribution, absorbed from the dropped SET-02).

### Claude's Discretion
- Exact widget layout, section ordering, and typography of the grouped screen.
- Archive file format/extension and naming convention for the backup.
- Pre-restore safety-snapshot mechanism and archive-validation checks.
- How the show/hide HUD toggle is surfaced and where the HUD overlays.
- Confirm-dialog copy for the retention purge.

</decisions>

<specifics>
## Specific Ideas

- Reconciliation is the theme of this phase: three of the nine original SET
  requirements predate major architecture shifts (Vehicles cut, Phase-4 rescope,
  Phase-7 color picker already shipped). Planner should treat the decisions above
  as the source of truth over the ROADMAP.md SC wording where they conflict.
- Reuse over rebuild: SET-04 and SET-06 lean on existing Phase 7 / Phase 3.1 code.

</specifics>

<deferred>
## Deferred Ideas

- **Encrypted backups** — if the app ever goes multi-user or stores anything
  sensitive, revisit SET-07 encryption (user-passphrase or device-keystore).
- **Overpass road-cache management UI** (size/clear) — considered as a SET-02
  replacement, rejected for v1 as a footgun with little value. Could return if the
  cache grows unexpectedly large in real use.
- **Merge-on-restore** — a smarter restore that dedupes trips instead of wiping.
  Out of scope; full-replace is the v1 model.
- **Permissions deep-links** — "fix in system settings" per-row jump; v1 is
  read-only.
- **Reconsidering vehicles** — explicitly a separate future phase if ever revived,
  never in Phase 9.

</deferred>

---

*Phase: 09-settings-backup*
*Context gathered: 2026-07-13*
