---
phase: 07
plan: 02
subsystem: planning-docs
tags: [requirements, roadmap, project, gate-g2, geojson, coverage-rendering, docs-only]

dependency-graph:
  requires:
    - "07-01 (coverage domain model established)"
    - "07-CONTEXT.md (locked deviations: orange default, REN-02 de-scoped)"
    - "07-RESEARCH.md (Gate G2 verdict: feature-state FAIL)"
  provides:
    - "REQUIREMENTS.md with reconciled REN-01/02/03/05 rows"
    - "ROADMAP.md with reconciled Phase 7 SC1/SC4 and Gate G2 resolved note"
    - "PROJECT.md Key Decisions with 2026-07-09 Gate G2 resolution entry"
  affects:
    - "07-03..07-07 (implementation plans can rely on docs as source of truth)"
    - "Future sessions: requirement ledger no longer contradicts the implementation"

tech-stack:
  added: []
  patterns: []

file-tracking:
  key-files:
    created: []
    modified:
      - ".planning/REQUIREMENTS.md"
      - ".planning/ROADMAP.md"
      - ".planning/PROJECT.md"

decisions:
  - "REN-01 default is orange/amber (not warm green); green is one of 5 presets"
  - "REN-02 is DE-SCOPED from v1 — Feldweg/Fußweg receive no Phase-7 coverage styling"
  - "Gate G2 = FAIL; GeoJSON data-driven expressions are the mandated rendering path"

metrics:
  duration: "~5 min"
  completed: "2026-07-10"
---

# Phase 7 Plan 02: Requirements Reconciliation Summary

**One-liner:** Wrote back orange/amber default, REN-02 de-scope, and Gate G2 FAIL+GeoJSON resolution from CONTEXT/RESEARCH into the three source-of-truth planning docs.

## What Was Done

This docs-only plan reconciled three locked decisions from `07-CONTEXT.md` and `07-RESEARCH.md` into `REQUIREMENTS.md`, `ROADMAP.md`, and `PROJECT.md` so the requirement ledger stops contradicting the implementation before code lands.

### Task 1 — REQUIREMENTS.md (commit b243e8b)

- **REN-01**: default changed from "warm green" to "orange/amber"; rendering mechanism changed from "MapLibre `feature-state` API" to "runtime GeoJSON source with data-driven paint expressions (feature-state unavailable on mobile — see Gate G2)"; deviation note added.
- **REN-02**: prefixed with `DE-SCOPED v1 (2026-07-09)`; row rewritten to state Feldweg/Fußweg receive no Phase-7 coverage styling (render as plain Phase-4 base pmtiles geometry only); row retained as a de-scope record (not deleted).
- **REN-03**: added note that v1 uses whole-way reduced-opacity scaling (documented fallback); per-segment/gradient deferred to v1.x.
- **REN-05**: rewritten to record the Gate G2 verdict — RESOLVED 2026-07-09 = FAIL; `setFeatureState` throws `UnimplementedError` on iOS+Android; single GeoJSON source + data-driven expressions is the resolution.
- Traceability table: REN-02 status changed from "Pending" to "De-scoped (v1) — 2026-07-09".
- Traceability intro: updated to reflect both gates now resolved (G1 PASS, G2 RESOLVED = FAIL).

### Task 2 — ROADMAP.md (commit 33fb9d1)

- Phase 7 **Goal**: dropped Kfz-vs-Feldweg framing; now states "Driven Kfz roads paint onto the map with full/partial coverage semantics; Gate G2 resolved."
- **SC1**: rewritten — orange/amber default, 5 presets incl. green, Kfz-only coloring, Feldweg/Fußweg plain base geometry (REN-02 de-scoped 2026-07-09). No dashed-blue clause.
- **SC4**: updated — "Coverage renders via a runtime GeoJSON source + data-driven paint expressions (Gate G2 resolved: feature-state unavailable on mobile in maplibre_gl 0.26.2)."
- **Gate G2 section**: heading updated to "RESOLVED 2026-07-09 = FAIL"; verdict bullet added with full resolution summary.

### Task 3 — PROJECT.md (commit 601b564)

Added dated entry under `## Key Decisions` (above `## Historical Decisions`):

> **2026-07-09 — Phase 7 Gate G2 resolved: GeoJSON data-driven expressions (not feature-state)**
>
> Summarizes: `setFeatureState` throws `UnimplementedError` on mobile in maplibre_gl 0.26.2 (web-only; upstream #889 targets 0.27.0). Resolution: single runtime GeoJSON source per brightness, `is_full`/`fraction` GeoJSON properties, GPU-evaluated data-driven paint expressions, `setLayerProperties` for live recolor, sources re-added on every `onStyleLoaded`. Consequences: REN-01 default → orange/amber; REN-02 de-scoped from v1.

## Deviations from Plan

None — plan executed exactly as written. All three edits matched the specified content precisely.

## No Code Touched

This is a docs-only plan. No Dart files were modified. `flutter analyze` is unaffected — no Ralph Loop iteration required.

## Commits

| Hash | Message |
|------|---------|
| b243e8b | docs(07-02): reconcile REN-01/02/03/05 in REQUIREMENTS.md |
| 33fb9d1 | docs(07-02): reconcile Phase 7 success criteria in ROADMAP.md |
| 601b564 | docs(07-02): record Gate G2 resolution in PROJECT.md Key Decisions |

## Next Phase Readiness

The three source-of-truth docs now agree with the CONTEXT/RESEARCH decisions. Plans 07-03 onwards can be written against REQUIREMENTS.md without finding contradictions. No blockers for 07-03 (DrivenWayGeometryResolver).
