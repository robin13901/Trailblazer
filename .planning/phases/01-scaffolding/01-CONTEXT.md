# Phase 1: Scaffolding - Context

**Gathered:** 2026-07-02
**Status:** Ready for planning

<domain>
## Phase Boundary

Build the production-quality project foundation: GitHub Actions CI, linting (very_good_analysis), App DB with full Drift schema + migration infrastructure, go_router routing, error/logging infrastructure, and permission plumbing — so all downstream phases can build on it without rework.

Creating or recording trips, rendering the map, or any user-facing features are out of scope for this phase.

</domain>

<decisions>
## Implementation Decisions

### CI pipeline behavior
- Trigger: pushes to `main` only — solo developer, no PRs or branches
- Failure mode: full run (lint + tests + builds all report failures in one pass, not fail-fast)
- Build matrix: iOS and Android builds run in parallel
- Coverage: uploaded to Codecov for tracking; no hard gate — target >80% but build doesn't fail below threshold
- Generated files stripped from coverage report before upload

### App DB setup & migrations
- Schema scope: full schema upfront — all tables from all phases defined in the v1 migration
- DAOs: schema only in Phase 1; DAOs are added per-phase when their tables get used
- Migration tests: Claude's discretion (SchemaVerifier, per-step isolation tests, or both)
- Schema file organization: Claude's discretion (single file vs domain-split)

### Error & logging infrastructure
- Crash reporting: none — dev logs only, no remote crash reporter
- Log verbosity: debug builds = verbose, release builds = warnings + errors only
- Log format: Claude's discretion (structured JSON vs plain text)
- Unhandled error catching: Claude's discretion (global Flutter error handler pattern or explicit-only)

### App startup & permission boot sequence
- First-launch flow: splash → first-launch onboarding → main screen (onboarding shown once only)
- Location permission timing: triggered on first map interaction, not during onboarding
- Onboarding navigation structure: Claude's discretion (separate route stack vs modal)
- Routing package: go_router

### Claude's Discretion
- Migration test strategy (SchemaVerifier only, per-step tests, or both)
- Drift schema file organization (single file vs domain-split)
- Log format (structured JSON vs plain text)
- Global Flutter error handler setup
- Onboarding navigation structure within go_router

</decisions>

<specifics>
## Specific Ideas

- Solo developer context: no branch protection, no PR reviews, no multi-contributor CI ceremony — keep CI config lean
- "No crash reporting" is intentional: diagnostics screen (Phase 10) will surface logs locally

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 01-scaffolding*
*Context gathered: 2026-07-02*
