---
phase: 07-coverage-rendering
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - .planning/REQUIREMENTS.md
  - .planning/ROADMAP.md
  - .planning/PROJECT.md
autonomous: true

must_haves:
  truths:
    - "REQUIREMENTS.md REN-01 default color is orange/amber (not warm green)"
    - "REQUIREMENTS.md REN-02 is explicitly marked DE-SCOPED from v1 (not deferred)"
    - "REQUIREMENTS.md REN-05 / Gate G2 records G2 = FAIL and the GeoJSON+data-driven-expression resolution"
    - "ROADMAP.md Phase 7 SC1 drops the Feldweg secondary-color clause and states orange default"
    - "PROJECT.md Key Decisions carries the Gate G2 resolution as a dated decision"
  artifacts:
    - path: ".planning/REQUIREMENTS.md"
      provides: "Reconciled REN-01/02/05 rows + status table"
      contains: "REN-05"
    - path: ".planning/ROADMAP.md"
      provides: "Reconciled Phase 7 success criteria"
      contains: "Phase 7"
    - path: ".planning/PROJECT.md"
      provides: "Gate G2 resolution decision entry"
      contains: "Gate G2"
  key_links: []
---

<objective>
Reconcile the locked CONTEXT deviations and the RESEARCH Gate-G2 verdict into
the project's planning docs so the requirement ledger reflects reality BEFORE
implementation lands. This is a docs-only plan: no code.

Purpose: The REN-01 (orange default), REN-02 (de-scoped), and REN-05/Gate-G2
(feature-state FAIL -> GeoJSON + data-driven paint expressions) decisions are
currently only in CONTEXT/RESEARCH. They must be written back to
REQUIREMENTS.md, ROADMAP.md, and PROJECT.md so the source-of-truth docs stop
saying "warm green", "dashed-blue Feldweg", and "setFeatureState".
Output: 3 edited planning docs.
</objective>

<execution_context>
@~/.claude/get-shit-done/workflows/execute-plan.md
@~/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/07-coverage-rendering/07-CONTEXT.md
@.planning/phases/07-coverage-rendering/07-RESEARCH.md
@.planning/REQUIREMENTS.md
@.planning/ROADMAP.md
@.planning/PROJECT.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Reconcile REN-01/02/03/05 in REQUIREMENTS.md</name>
  <files>.planning/REQUIREMENTS.md</files>
  <action>
Edit the requirement lines (currently ~137-142):

  - REN-01: change default from "warm green" to "orange/amber"; change wording
    from "using MapLibre `feature-state` API" to "via a runtime GeoJSON source
    with data-driven paint expressions (feature-state unavailable on mobile —
    see Gate G2)". Add "(default color deviation locked 2026-07-09; green
    remains one of 5 presets)".
  - REN-02: prefix with "DE-SCOPED v1 (2026-07-09):" and rewrite to state
    Feldweg/Fußweg receive NO Phase-7 coverage styling — they render as plain
    Phase-4 base pmtiles geometry only. No dashed-blue, no driven-state color.
    Keep the row (do not delete) so the ledger records the de-scope explicitly.
    Mark it as intentionally not-in-v1 rather than pending.
  - REN-03: keep, but note v1 uses whole-way reduced-opacity scaling (the
    documented fallback), per-segment/gradient deferred to v1.x.
  - REN-05: rewrite the Gate-G2 line to record the verdict: "Gate G2 RESOLVED
    2026-07-09 = FAIL. `setFeatureState` throws UnimplementedError on iOS+Android
    in maplibre_gl 0.26.2 (web-only). Resolution: single runtime GeoJSON source
    per brightness + data-driven paint expressions (`is_full`/`fraction` GeoJSON
    props evaluated GPU-side); the '5x5km sharded GeoJSON' literal wording is
    satisfied by this GeoJSON-source path — per-tile sharding is an optional
    Phase-8+ optimization, not v1-mandatory."

In the traceability status table (~316-323), update statuses: REN-02 -> "De-scoped (v1)";
leave REN-01/03/04/05/06 + COV-02/03 as Pending (they will flip to Complete at
phase close). Do NOT change any other requirement rows.
  </action>
  <verify>grep confirms REN-01 says orange/amber, REN-02 says DE-SCOPED, REN-05 says Gate G2 FAIL + GeoJSON expressions.</verify>
  <done>REQUIREMENTS.md reflects orange default, REN-02 de-scoped, and Gate G2 = FAIL/GeoJSON resolution.</done>
</task>

<task type="auto">
  <name>Task 2: Reconcile Phase 7 success criteria in ROADMAP.md</name>
  <files>.planning/ROADMAP.md</files>
  <action>
Edit the Phase 7 block (~198-208):
  - Goal line: drop "Kfz-vs-Feldweg" framing; state "Driven Kfz roads paint onto
    the map with full/partial coverage semantics; Gate G2 resolved."
  - SC1: rewrite to drop the Feldweg/Fußweg secondary-color clause entirely.
    New SC1: "Driven Kfz-ways render in the 'explored' color (default orange/amber;
    5 user-selectable presets incl. green). Per-way driven-state coloring applies
    to Kfz ways only; Feldweg/Fußweg render as plain base geometry (REN-02
    de-scoped 2026-07-09)."
  - SC4: update to reflect G2 = FAIL -> "Coverage renders via a runtime GeoJSON
    source + data-driven paint expressions (Gate G2 resolved: feature-state
    unavailable on mobile in maplibre_gl 0.26.2)."
  - Update the "Where" gate note (~39) if present to mark G2 resolved.
  - The **Plans:** line will be finalized by the orchestrator's roadmap-update
    step; leave a "TBD (7 plans, 4 waves)" placeholder if you touch it.
Do not alter other phases.
  </action>
  <verify>grep Phase 7 block shows orange default, no dashed-blue Feldweg clause, SC4 mentions GeoJSON expressions.</verify>
  <done>ROADMAP Phase 7 SC1 + SC4 reconciled with locked decisions.</done>
</task>

<task type="auto">
  <name>Task 3: Record Gate G2 resolution in PROJECT.md Key Decisions</name>
  <files>.planning/PROJECT.md</files>
  <action>
Add a dated entry under "## Key Decisions" (above "## Historical Decisions",
~147):

  ### 2026-07-09 — Phase 7 Gate G2 resolved: GeoJSON data-driven expressions (not feature-state)

  Summarize: setFeatureState throws UnimplementedError on iOS+Android in
  maplibre_gl 0.26.2 (web-only; upstream #889 targets 0.27.0). Coverage rendering
  therefore uses a single runtime GeoJSON source per brightness with data-driven
  paint expressions (`is_full` case + `fraction` opacity ramp evaluated GPU-side);
  `setLayerProperties` for live color-preset recolor; sources re-added in
  `onStyleLoaded` on every style swap. REN-01 default color changed to orange/amber;
  REN-02 (Feldweg dashed-blue) de-scoped from v1.

Keep it tight (a paragraph + bullet list matching the existing Key-Decisions
style). Do not restructure the file.
  </action>
  <verify>grep "Gate G2" PROJECT.md returns the new dated decision entry.</verify>
  <done>PROJECT.md Key Decisions has the 2026-07-09 Gate G2 resolution entry.</done>
</task>

</tasks>

<verification>
- All three docs edited; grep spot-checks pass (orange, de-scoped, Gate G2 FAIL).
- No code files touched; `flutter analyze` unaffected.
</verification>

<success_criteria>
REQUIREMENTS.md, ROADMAP.md, and PROJECT.md all reflect the locked REN-01
(orange), REN-02 (de-scoped), and REN-05/Gate-G2 (GeoJSON + expressions)
decisions. The requirement ledger no longer contradicts the implementation.
</success_criteria>

<output>
After completion, create `.planning/phases/07-coverage-rendering/07-02-SUMMARY.md`
</output>
