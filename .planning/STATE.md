# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-02)

**Core value:** When I open the map, I immediately see the roads I've already driven, painted onto the world — and that view keeps pulling me back to explore more.
**Current focus:** Phase 1 — Scaffolding

## Current Position

Phase: 1 of 11 (Scaffolding)
Plan: 1 of 7 in current phase
Status: In progress (Plan 01 complete, Plan 02 ready)
Last activity: 2026-07-03 — Completed 01-01 flutter-project-bootstrap; analyzer + format + tests all green on Flutter 3.44.4

Progress: [█░░░░░░░░░] ~1.3% (1/77 est. plans overall — Phase 1 sizing: 7 plans; other phases TBD)

## Performance Metrics

**Velocity:**
- Total plans completed: 1
- Average duration: ~18 min (excl. one-time SDK upgrade)
- Total execution time: 0.3 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-scaffolding | 1 | ~18 min | 18 min |

**Recent Trend:**
- Last 5 plans: 01-01 (18 min)
- Trend: baseline established

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Key locked-in decisions affecting current work:

- Roadmap: `flutter_background_geolocation` chosen; accept future Android release-license cost (~USD 400–1200) if App Store publication happens.
- Roadmap: OSM admin levels 2/4/6/8/9/10 (including Stadtteil + Ortsteil) in scope for v1.
- Roadmap: OSM extract delivered via first-launch Wi-Fi download (~200 MB) — no bundling.
- Roadmap: Two spike gates open — G1 (P2 Liquid Glass over MapLibre) and G2 (P7 `feature-state` availability).
- **Plan 01-01 (2026-07-03):** Dropped `custom_lint ^0.8.1` and `riverpod_lint ^3.1.4` from pubspec — irresolvable analyzer conflict with `drift_dev 2.34` (analyzer ^13 vs ^8). Re-introduce once upstream custom_lint releases analyzer 13-compatible build.
- **Plan 01-01 (2026-07-03):** Local Flutter toolchain upgraded 3.38.1 → 3.44.4 (stable channel) to satisfy pubspec constraint `>=3.44.0`.
- **Plan 01-01 (2026-07-03):** All imports use `package:auto_explore/…` prefix (very_good_analysis `always_use_package_imports`). Pubspec deps alphabetized (`sort_pub_dependencies`).

### Pending Todos

- **Chore (post-Phase 1):** Re-add `custom_lint` + `riverpod_lint` when a `custom_lint` release supports `analyzer ^13.0.0`. Also restore `analyzer.plugins: - custom_lint` in `analysis_options.yaml`.
- **Optional:** Confirm `flutter build apk --debug` on a Windows box that has `cmdline-tools` + Android SDK licenses accepted (CI in Plan 06 will do this).

### Blockers/Concerns

- **G1 (P2):** `BackdropFilter` behavior over MapLibre platform view on Impeller must be validated on real iOS + Android before full glass commitment. Fallback path documented.
- **G2 (P7):** `maplibre_gl` ^0.26.2 `setFeatureState` support unverified. Sharded-GeoJSON fallback stands by.
- **HMM accuracy (P5):** Requires ≥ 20-trip golden corpus recorded in real driving before matcher can pass CI regression.
- **Lint gap (P1):** `custom_lint` + `riverpod_lint` temporarily out (see decisions). Regular analyzer + `very_good_analysis` still enforce style + correctness; Riverpod-specific misuse detection is on hold.

## Session Continuity

Last session: 2026-07-03 08:01 UTC
Stopped at: Completed .planning/phases/01-scaffolding/01-flutter-project-bootstrap-PLAN.md
Resume file: None (ready for `/gsd:execute-phase` on Plan 02 or the next Wave 2 plan)
