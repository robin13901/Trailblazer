---
phase: 01-scaffolding
plan: "07"
subsystem: docs
tags: [readme, architecture, docs, badges, phase-1-closeout]

# Dependency graph
requires:
  - phase: 01-scaffolding
    provides: All prior Phase 1 plans (01-06) — final decisions to document
provides:
  - Root README.md with badges, tech stack, quickstart, build/CI notes
  - docs/ARCHITECTURE.md summarizing feature-first layout + Phase 1 locked decisions
  - FND-06 traceability closed
affects: [phase-2-map, phase-3-gps, phase-4-osm, all-future-phases]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "README + docs/ARCHITECTURE.md as the single source of truth for repo entry"
    - "Codified anti-patterns table for future refactors"

key-files:
  created:
    - "docs/ARCHITECTURE.md"
  modified:
    - "README.md"

key-decisions:
  - "README uses robin13901/Trailblazer badge URLs on branch main (product name Trailblazer; Dart package remains auto_explore)"
  - "iOS-build badge included but user-facing note flags it as manual-trigger only"
  - "Codecov badge links to app.codecov.io/github/robin13901/trailblazer (matches STATE.md URL)"
  - "License stated as 'Private — not licensed for redistribution' (matches plan template)"
  - "Known-gap callout for custom_lint/riverpod_lint kept front-and-centre in both README and ARCHITECTURE"
  - "ARCHITECTURE.md 'Locked decisions' section mirrors STATE.md decisions verbatim to prevent drift"

patterns-established:
  - "Docs-first close-out plan for each phase — Phase 1 ends with README + ARCHITECTURE reflecting real state"
  - "Anti-patterns table (vs prior projects) — reusable format for future phase docs"

# Metrics
duration: 8min
completed: 2026-07-03
---

# Phase 1 Plan 07: README and Docs Summary

**Trailblazer README + docs/ARCHITECTURE.md landed — every Phase 1 locked decision is now findable in one grep, and the repo has real badges wired to the real workflows.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-07-03 (execution)
- **Completed:** 2026-07-03T09:19Z
- **Tasks:** 2 completed
- **Files modified:** 2 (1 replaced, 1 created)

## Accomplishments

- **README.md** replaces the default Flutter template with a Trailblazer-branded landing page: CI + iOS + Codecov + Flutter + Dart + very_good_analysis badges (all wired to `robin13901/Trailblazer` on `main`), tech-stack table, prerequisites, quickstart (`pub get` → `build_runner` → `drift_dev schema generate` → analyze → test → run), build commands, CI overview, and doc cross-links.
- **docs/ARCHITECTURE.md** codifies the feature-first layout (`lib/{main,app,core/*,features/*}`), layering rules, and every Phase 1 locked decision — toolchain, deps, errors, DB (FK cascades, business-key PKs, `SchemaVerifier` flow), routing/onboarding, native platform config, CI (codegen ordering + iOS manual-trigger + Android local-only), and an anti-patterns table.
- **FND-06 delivered** — the repo now has a human-readable entry point that reflects the real Phase 1 state (not the pre-execution plan template).

## Task Commits

1. **Task 7.1: Write README.md with badges + quickstart** — `cba2461` (docs)
2. **Task 7.2: Write docs/ARCHITECTURE.md** — `4191aeb` (docs)

**Plan metadata:** _to be filled after final commit_

## Files Created/Modified

- `README.md` — Full replacement. 6 shields.io badges, tech stack table, quickstart with mandatory codegen step, CI matrix, doc cross-links.
- `docs/ARCHITECTURE.md` — New. Layer tree, layering rules, "Locked decisions (Phase 1)" section (mirrors STATE.md), anti-patterns table, next-phase handoff notes, chore backlog.

## Decisions Made

- Kept the product name **Trailblazer** front-and-centre but explicitly noted the Dart package name is still `auto_explore` (legacy) — prevents future confusion when reading `pubspec.yaml` or `package:auto_explore/...` imports.
- Included the **iOS build badge** in the README (as the plan template suggested) but paired it with an explicit "manual only (`workflow_dispatch`)" note in the CI section — badge will show the last manually triggered run, not per-push status.
- **Codecov badge** links to `app.codecov.io/github/robin13901/trailblazer` (the modern app URL) to match the STATE.md reference, while the badge image itself still resolves from `codecov.io/gh/robin13901/Trailblazer/branch/main/graph/badge.svg`.
- Chose to write **ARCHITECTURE.md** as a decision-focused document (locked decisions + rationale + anti-patterns) rather than an aspirational design doc — reflects the actual codebase, not a wishlist. Future phases can add sections rather than rewriting.
- Kept the license line as "Private — not licensed for redistribution at this time" per the plan template. No new license file created.

## Deviations from Plan

The plan template was written pre-execution and contained several assumptions that no longer match the real Phase 1 codebase. Applied the "locked decisions override plan" rule from the launch prompt:

### Rule 1 — Corrected facts to match locked decisions

**1. GitHub repo slug**
- Plan template: `I551358/Auto-Explore-App` on branch `master`
- Reality (per `git remote get-url origin`): `robin13901/Trailblazer` on branch `main`
- **Fix:** Substituted the real owner/repo/branch in all badge URLs and clone references.

**2. Product name**
- Plan template: `# Auto-Explore` with tagline "(working title: *Trailblazer*)"
- Reality: PROJECT.md + STATE.md call the product **Trailblazer**; `auto_explore` is the legacy Dart package name only.
- **Fix:** README title is `# Trailblazer`; added a one-liner noting the Dart package name remains `auto_explore`.

**3. Dropped lints**
- Plan template: implicit assumption that `custom_lint` / `riverpod_lint` are active (badge line lists `riverpod_lint`).
- Reality: both dropped in Plan 01-01 (analyzer conflict).
- **Fix:** README and ARCHITECTURE both call this out as a **Known lint gap** with re-adoption criteria. Only `very_good_analysis` badge included.

**4. iOS artifact**
- Plan template: implies iOS CI produces a `.ipa`.
- Reality: unsigned builds produce `build/ios/archive/*.xcarchive` (per Plan 01-06 STATE.md entry).
- **Fix:** README CI table explicitly names the `.xcarchive` artifact.

**5. iOS trigger**
- Plan template: iOS build runs on push.
- Reality: `ios-build.yml` is manual (`workflow_dispatch`) — Plan 01-06 decision.
- **Fix:** README CI section flags "manual only"; badge still included but readers understand it lags.

**6. Android in CI**
- Plan template: silent on Android CI.
- Reality: Android debug builds run **locally** on the dev machine, not in CI.
- **Fix:** Called this out explicitly in both README ("run locally — Android is NOT built in CI") and ARCHITECTURE ("Android debug builds happen locally on the dev machine").

**7. Codegen-first workflow**
- Plan template: quickstart mentions codegen but doesn't explain why order matters.
- Reality: `.g.dart` + `test/generated_migrations/` are gitignored; analyzer/test will fail on a fresh checkout until codegen runs. Plan 01-06 encoded this ordering in CI.
- **Fix:** Added a "Why codegen runs first" callout in the README quickstart.

**8. Package import convention**
- Plan template: not mentioned.
- Reality: Plan 01-01 enforced `package:auto_explore/…` imports via `always_use_package_imports`.
- **Fix:** Added to ARCHITECTURE layering rules + anti-patterns table.

**9. Alphabetized deps**
- Plan template: not mentioned.
- Reality: Plan 01-01 enforced `sort_pub_dependencies`.
- **Fix:** Noted in ARCHITECTURE toolchain section.

**10. FK cascades and PKs**
- Plan template: mentions Drift but not cascade decisions.
- Reality: Plan 01-02 locked specific cascade policies (`trip_points` CASCADE, `driven_intervals` SET NULL, `bt_fingerprints` CASCADE) and business-key PKs on `coverage_cache` + `app_prefs`.
- **Fix:** Enumerated in ARCHITECTURE "App DB" section.

**11. `PlatformDispatcher.onError` return value**
- Plan template: not mentioned.
- Reality: returns `true` (dev-only, prevents OS crash) per Plan 01-04.
- **Fix:** Documented in ARCHITECTURE "Errors & logging" section.

**12. Onboarding gating location**
- Plan template: doesn't specify.
- Reality: Plan 01-03 chose to gate inside `SplashScreen` (microtask) rather than a top-level `GoRouter.redirect`.
- **Fix:** Documented rationale (keeps router synchronous).

**13. `permission_handler` not yet added**
- Plan template: implies permissions story is complete.
- Reality: Phase 1 only declares manifest entries; runtime prompts + `permission_handler` land in Phase 3.
- **Fix:** Called out in ARCHITECTURE "Native platform config" section.

**14. Foreground-service class placeholder**
- Plan template: not mentioned.
- Reality: AndroidManifest declares `.LocationRecordingService` as a placeholder; Phase 3 rebinds to the plugin's real class.
- **Fix:** Noted in ARCHITECTURE + Phase 3 handoff section.

**15. `NSBluetoothPeripheralUsageDescription` skipped**
- Plan template: not mentioned.
- Reality: Plan 01-05 skipped it (deprecated; app is central-only).
- **Fix:** Documented in ARCHITECTURE "Native platform config" section.

All 15 corrections stem from **Rule 1** (plan wording conflicts with locked decisions) — the launch prompt instructed to trust locked decisions in such cases. No architectural changes; no `flutter analyze` / `flutter test` impact (docs-only).

## Ralph Loop

Not applicable — pure docs changes. No Dart or CI files touched, so `flutter analyze` / `flutter test` were not re-run. Both were green after Plan 01-06 and remain unaffected.

## Verification

- `test -f README.md` ✓
- `! grep -q "<OWNER>\|<REPO>\|<BRANCH>" README.md` ✓ (no placeholders leaked)
- `grep -q "very_good_analysis" README.md` ✓
- `grep -q "codecov.io/gh" README.md` ✓
- `grep -q "workflows/ci.yml/badge.svg" README.md` ✓
- `test -f docs/ARCHITECTURE.md` ✓
- `grep -q "features/" docs/ARCHITECTURE.md` ✓
- `grep -q "DomainError" docs/ARCHITECTURE.md` ✓
- `grep -q "SchemaVerifier" docs/ARCHITECTURE.md` ✓

## Phase 1 status

With Plan 07 complete, **Phase 1 (Scaffolding) is now 7/7 plans done**. Ready for `/gsd:verify-work` phase-level verification. Phase 1 delivers:

- `01-01` Flutter project bootstrap (SDK 3.44.4, `very_good_analysis`, deps alphabetized)
- `01-02` Drift App DB v1 (7 tables, FK cascades, `SchemaVerifier`, migration helpers)
- `01-03` go_router shell (splash → onboarding-first-launch → home)
- `01-04` Error + logging infra (`DomainError`, `Result<T>`, dual error hooks)
- `01-05` Platform permissions + manifest (iOS 6 purpose strings + Android 10 permissions + FGS skeleton)
- `01-06` GitHub Actions CI (`ci.yml` + `ios-build.yml`; Codecov wired; run 28650295975 green in 1m 47s)
- `01-07` README + ARCHITECTURE docs (this plan)
